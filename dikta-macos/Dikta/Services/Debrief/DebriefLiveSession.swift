import Foundation

/// One debrief that is transcribed *while* it is still being recorded, and
/// summarized incrementally as each chunk lands.
///
/// This is the single API every debrief now goes through — a call (two
/// tracks), a mic-only debrief (one track), and an imported file (one track,
/// appended in one go). Decision 11 in `tasks/decisions-call-debrief.md`: one
/// chunked pipeline for mic/file/call, and anything under one chunk behaves
/// exactly as it did before chunking existed.
///
/// Flow
/// ----
/// 1. `DebriefPipeline.startLiveSession` builds the session: a
///    `ChunkedTranscriptionSession` over the configured tracks, plus a
///    `RollingDebriefSummarizer` built from the same `DebriefEngineKind` and
///    Ollama model the single-pass factory uses.
/// 2. The producers call `append(_:track:)` as audio arrives. It never blocks:
///    the chunker hands the buffer to its own serial queue and returns.
/// 3. Every ~5 minutes the chunker closes a chunk, transcribes it in the
///    background and calls back here. The chunk's per-track segments are
///    merged (`TwoTrackMerger` for two tracks, plain concatenation for one),
///    rendered, and handed to the rolling summarizer.
/// 4. `finish(onStage:)` closes the last chunk, waits for the outstanding
///    work, and produces the summary — so a one-hour call's summary is ready
///    roughly one chunk's worth of work after the user hits stop, not one
///    hour's.
///
/// Single-chunk bypass
/// -------------------
/// A recording short enough to be one chunk must behave *exactly* as it did
/// before this class existed: one `DebriefSummarizer.summarize` call over the
/// whole transcript, same stages, same engine-name reporting. So the first
/// chunk's transcript is **held back** rather than ingested on arrival — it is
/// only fed to the rolling summarizer once a second chunk proves the recording
/// is long. A short debrief therefore never touches the rolling summarizer at
/// all (and never spends an LLM call on it).
///
/// Ordering
/// --------
/// `RollingDebriefSummarizer` serializes in the order calls *reach* the actor,
/// and unstructured `Task`s carry no ordering guarantee between them — so the
/// ingest calls are chained here (`ingestChain`) rather than fired off
/// independently. A delta is only meaningful against the state it was computed
/// from, so chunk N must reach the actor before chunk N+1.
///
/// Concurrency: a `final class` with an `NSLock`, not an actor, for the same
/// reason `ChunkedTranscriptionSession` is — `append` is called from audio
/// delivery callbacks that are synchronous and non-async.
final class DebriefLiveSession: @unchecked Sendable {

    /// Floor on how long `finish()` will wait for transcription still in
    /// flight. The pipeline's own timeout is a whole-recording budget; by the
    /// time `finish()` runs, every chunk but the last has already been
    /// transcribed *during* the recording, so what is left is small — but it
    /// must never be smaller than the time one chunk needs.
    static let minimumFinishTimeout: TimeInterval = 120

    // MARK: - Immutable configuration

    private let pipeline: DebriefPipeline
    private let chunker: ChunkedTranscriptionSession
    private let rolling: RollingDebriefSummarizer
    /// Name of the delta engine backing `rolling`, for result reporting.
    private let deltaEngineName: String
    private let paths: DebriefSessionPaths
    private let tracks: [DebriefTrack]
    private let language: String?
    /// How long `finish()` may wait for the remaining transcription work.
    private let finishTimeout: TimeInterval

    /// Non-nil once `finish()` has been entered — the "stop" instant the
    /// headline metric is measured from.
    private let lock = NSLock()

    // MARK: - Lock-guarded state

    /// Every segment seen through `onChunkTranscribed`, per track. Used as the
    /// transcript source only when `chunker.finish()` times out; otherwise the
    /// chunker's own (sorted) result wins.
    private var observedSegments: [DebriefTrack: [TranscriptSegment]] = [:]
    private var observedChunkCount = 0
    /// Chunk 0, held back until a chunk 1 proves this is not a short
    /// recording. See "Single-chunk bypass".
    private var heldFirstChunk: (index: Int, transcript: String)?
    /// Tail of the serial ingest chain.
    private var ingestChain: Task<Void, Never>?
    /// Non-fatal problems, surfaced on `DebriefResult.issues` and logged.
    private var issues: [String] = []
    /// Set when `finish()`'s transcription budget expires. A chunk whose job
    /// lands after that must not join the transcript: the summary is built
    /// from what was ready at the cutoff, and a late arrival would otherwise
    /// slip in while `finish()` is still draining the ingest chain.
    private var transcriptionClosed = false

    // MARK: - Init

    /// Built by `DebriefPipeline.startLiveSession`; not intended to be
    /// constructed directly outside tests.
    init(
        pipeline: DebriefPipeline,
        engine: any TranscriptionEngine,
        deltaSummarizer: DeltaSummarizing,
        similarity: EmbeddingSimilarity,
        paths: DebriefSessionPaths,
        tracks: [DebriefTrack],
        language: String?,
        micSensitivity: MicSensitivity,
        chunking: ChunkingConfig,
        transcriptionTimeout: TimeInterval,
        finishTimeoutFloor: TimeInterval = DebriefLiveSession.minimumFinishTimeout
    ) {
        self.pipeline = pipeline
        self.paths = paths
        self.deltaEngineName = deltaSummarizer.name
        var seen = Set<DebriefTrack>()
        let uniqueTracks = tracks.filter { seen.insert($0).inserted }
        self.tracks = uniqueTracks.isEmpty ? [.me] : uniqueTracks
        self.language = language
        self.finishTimeout = max(transcriptionTimeout, finishTimeoutFloor)
        self.chunker = ChunkedTranscriptionSession(
            engine: engine,
            tracks: self.tracks,
            language: language,
            micSensitivity: micSensitivity,
            config: chunking
        )
        self.rolling = RollingDebriefSummarizer(
            summarizer: deltaSummarizer,
            similarityProvider: similarity,
            language: DebriefPipeline.renderLanguage(for: language)
        )

        // Set before the first append, as `onChunkTranscribed` requires.
        chunker.onChunkTranscribed = { [weak self] result in
            self?.handleChunk(result)
        }
    }

    // MARK: - Ingest

    /// Hand 16 kHz mono samples for one track to the session. Non-blocking:
    /// safe to call from an audio delivery queue.
    func append(_ samples: [Float], track: DebriefTrack) {
        chunker.append(samples, track: track)
    }

    // MARK: - Chunk callback

    /// Called on a background thread, in chunk order, once a chunk's
    /// transcription jobs are done. Never calls `finish()` — that would
    /// deadlock the chunker's job chain.
    private func handleChunk(_ result: ChunkResult) {
        let transcript = Self.renderChunk(result.segments, tracks: tracks)
        logChunk(result)

        lock.lock()
        guard !transcriptionClosed else {
            issues.append("chunk \(result.info.index) finished after the transcription budget expired — not included")
            lock.unlock()
            return
        }
        for track in tracks {
            observedSegments[track, default: []].append(contentsOf: result.segments[track] ?? [])
        }
        observedChunkCount += 1
        for (track, message) in result.info.errors {
            issues.append("chunk \(result.info.index) \(track.rawValue): \(message)")
        }

        if observedChunkCount == 1 {
            // Hold chunk 0 back: this may still turn out to be a short
            // recording, which must go down the single-pass path untouched.
            heldFirstChunk = (index: result.info.index, transcript: transcript)
            lock.unlock()
            return
        }

        // A second chunk exists, so this recording is rolling-summarized.
        // Flush the held first chunk ahead of this one, preserving order.
        let held = heldFirstChunk
        heldFirstChunk = nil
        if let held {
            enqueueIngestLocked(transcript: held.transcript, index: held.index)
        }
        enqueueIngestLocked(transcript: transcript, index: result.info.index)
        lock.unlock()
    }

    /// Extends the serial ingest chain. Caller holds `lock`.
    private func enqueueIngestLocked(transcript: String, index: Int) {
        let previous = ingestChain
        ingestChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.rolling.ingest(chunkTranscript: transcript, index: index)
            } catch {
                // Never fatal: one chunk that the delta engine choked on must
                // not cost the user the rest of the meeting.
                self.record("chunk \(index) rolling ingest failed: \(error.localizedDescription)")
                AppLogger.general.error("DebriefLiveSession: rolling ingest for chunk \(index) failed: \(error.localizedDescription)")
            }
        }
    }

    private func record(_ issue: String) {
        lock.lock()
        issues.append(issue)
        lock.unlock()
    }

    // MARK: - Finish

    /// Closes the recording and produces the debrief.
    ///
    /// `.transcribing` is *not* reported here — the caller has already entered
    /// that stage by the time audio is arriving. `.summarizing` and `.saving`
    /// come from the shared tail, exactly as on the single-pass path.
    func finish(onStage: @escaping @MainActor (DebriefStage) -> Void) async throws -> DebriefResult {
        let stoppedAt = Date()

        // 1. Close the final chunk and wait for the transcription still in
        //    flight, bounded. On timeout we summarize what did complete.
        var chunked: ChunkedTranscript?
        let outcome = await Self.withDeadline(seconds: finishTimeout) { [chunker] in
            await Result { try await chunker.finish() }
        }
        switch outcome {
        case .some(.success(let transcript)):
            chunked = transcript
        case .some(.failure(let error)):
            // `allChunksFailed` and anything else the chunker raises is a real
            // transcription failure, reported exactly as before.
            throw error
        case .none:
            lock.lock()
            transcriptionClosed = true
            lock.unlock()
            record("transcription timed out after \(Int(finishTimeout))s — summarizing the chunks that completed")
            AppLogger.transcription.error("DebriefLiveSession: finish timed out after \(Int(self.finishTimeout))s; summarizing completed chunks only")
        }

        // 2. Let the ingest chain catch up on whatever the rolling summarizer
        //    has not folded in yet, within the remaining budget.
        let remaining = max(1, finishTimeout - Date().timeIntervalSince(stoppedAt))
        let chain = lock.withLock { ingestChain }
        if let chain {
            _ = await Self.withDeadline(seconds: remaining) { await chain.value }
        }

        // 3. Build the full transcript. The chunker's own result is
        //    authoritative (sorted, complete); the segments observed through
        //    the callback are the fallback when it timed out.
        let (observed, chunkCount, heldFirst, collectedIssues) = lock.withLock {
            (observedSegments, observedChunkCount, heldFirstChunk, issues)
        }
        let segments = chunked?.segments ?? observed
        let transcript = Self.renderFull(segments, tracks: tracks)
        let chunks = chunked?.chunks.count ?? chunkCount

        // 4. One chunk (or none) → the single-pass summarizer over the whole
        //    transcript, byte-identical to the pre-chunking behaviour. The
        //    held-back first chunk was never ingested, so the rolling
        //    summarizer has not been touched.
        if chunks <= 1 || heldFirst != nil {
            logFinish(stoppedAt: stoppedAt, chunks: chunks, rolling: false)
            return try await pipeline.finishTranscribedDebrief(
                transcript: transcript,
                paths: paths,
                language: language,
                issues: collectedIssues,
                onStage: onStage
            )
        }

        logFinish(stoppedAt: stoppedAt, chunks: chunks, rolling: true)
        let rolling = self.rolling
        return try await pipeline.finishTranscribedDebrief(
            transcript: transcript,
            paths: paths,
            language: language,
            issues: collectedIssues,
            summarize: { [deltaEngineName] _, _ in
                let summary = try await rolling.finish()
                let events = await rolling.events
                return (summary, "\(deltaEngineName) (rolling)", events)
            },
            onStage: onStage
        )
    }

    // MARK: - Rendering

    /// One chunk's per-track segments as plain text: a Me/Them-labeled
    /// transcript for a two-track session, and a plain concatenation of the
    /// segment texts for a single-track one — a mic debrief has exactly one
    /// speaker, so labeling it would only give the summarizer a speaker rule
    /// it must not apply.
    static func renderChunk(_ segments: [DebriefTrack: [TranscriptSegment]], tracks: [DebriefTrack]) -> String {
        guard tracks.count > 1 else {
            let track = tracks.first ?? .me
            return (segments[track] ?? [])
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return TwoTrackMerger.render(
            TwoTrackMerger.merge(me: segments[.me] ?? [], them: segments[.them] ?? [])
        )
    }

    /// The whole session's transcript. Same rules as `renderChunk`; the
    /// two-track case re-merges across chunk boundaries so a Me paragraph that
    /// straddles a cut is not split by the cut.
    static func renderFull(_ segments: [DebriefTrack: [TranscriptSegment]], tracks: [DebriefTrack]) -> String {
        renderChunk(segments, tracks: tracks)
    }

    // MARK: - Diagnostics

    /// One `DEBRIEF_LIVE` line per chunk: how much audio it covered, what each
    /// track's transcription cost in wall time, any silence padding, and any
    /// per-track failure.
    private func logChunk(_ result: ChunkResult) {
        let info = result.info
        let seconds = String(format: "%.1f", info.endSeconds - info.startSeconds)
        let wall = tracks.map { track in
            "\(track.rawValue)=\(String(format: "%.1f", info.transcribeWallSeconds[track] ?? 0))s"
        }.joined(separator: ",")
        let padded = info.paddedSeconds.isEmpty ? "none" : info.paddedSeconds
            .map { "\($0.key.rawValue)=\(String(format: "%.1f", $0.value))s" }
            .sorted()
            .joined(separator: ",")
        let errors = info.errors.isEmpty ? "none" : info.errors
            .map { "\($0.key.rawValue)=\($0.value)" }
            .sorted()
            .joined(separator: ",")
        DiagnosticLogger.shared.log(
            "DEBRIEF_LIVE | chunk=\(info.index) | audio=\(seconds)s | wall=\(wall)"
            + " | silenceCut=\(info.cutAtSilence) | padded=\(padded) | errors=\(errors)"
        )
    }

    /// The feature's headline metric: seconds from the user pressing stop to
    /// the summary existing.
    private func logFinish(stoppedAt: Date, chunks: Int, rolling: Bool) {
        DiagnosticLogger.shared.log(
            "DEBRIEF_LIVE | finish | chunks=\(chunks) | path=\(rolling ? "rolling" : "single-pass")"
            + " | stopToSummary=\(String(format: "%.1f", Date().timeIntervalSince(stoppedAt)))s"
        )
    }

    // MARK: - Deadline helper

    /// Resumes exactly once, with whichever of the two racers got there
    /// first. A `finish` that lands before `install` is remembered and handed
    /// to the continuation as it arrives, so an already-expired deadline can
    /// never strand the caller.
    private final class DeadlineGate<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var finished = false
        private var winner: T??

        func install(_ continuation: CheckedContinuation<T?, Never>) {
            lock.lock()
            if let winner {
                lock.unlock()
                continuation.resume(returning: winner)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ value: T?) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            winner = .some(value)
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    /// Awaits `body`, giving up and returning `nil` after `seconds`.
    ///
    /// Deliberately NOT a task group. A group awaits every child before it
    /// returns, and cancelling the loser does not help here:
    /// `ChunkedTranscriptionSession.finish()` awaits an *unstructured* job
    /// chain that never observes cancellation, so a group would sit on the
    /// slow engine call for as long as it takes — precisely the stall this
    /// deadline exists to prevent. The abandoned work is left running instead;
    /// it holds nothing but this session and is released when it completes,
    /// and `transcriptionClosed` stops a late chunk joining the transcript.
    static func withDeadline<T: Sendable>(
        seconds: TimeInterval,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        let gate = DeadlineGate<T>()
        let sleeper = Task {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            gate.finish(nil)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            gate.install(continuation)
            Task {
                let value = await body()
                // Cancelled before the gate is resolved: on the fast path the
                // sleeper would otherwise hold a timer for the whole budget
                // (up to 30 minutes) for a result nobody will read.
                sleeper.cancel()
                gate.finish(value)
            }
        }
    }
}

private extension Result where Failure == Error {
    /// `Result(catching:)` for an async throwing body.
    init(_ body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
