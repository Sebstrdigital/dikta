import Foundation

// MARK: - Types


/// Tunables for the slicer. Defaults match decision 8 and the "Chunk
/// boundary rule" in `tasks/decisions-call-debrief.md`.
struct ChunkingConfig {
    /// Nominal chunk length. A cut is considered once every track has this
    /// much unconsumed audio.
    var targetChunkSeconds: TimeInterval = 300
    /// Half-width of the window around the target mark searched for silence.
    var silenceSearchSeconds: TimeInterval = 30
    /// Shortest silent run that may be used as a cut point.
    var minSilenceSeconds: TimeInterval = 0.4
    /// RMS at or below this counts as silence (max across all tracks).
    var silenceRMS: Float = 0.01
    /// Extra audio handed to the engine on each side of a hard cut.
    var overlapSeconds: TimeInterval = 3
    /// Feed the previous chunk's tail to the engine as a decoding prompt.
    /// Off by default: WhisperKit re-applies `promptTokens` to *every* 30 s
    /// window inside one call, which invites repetition on long chunks.
    var promptContinuation: Bool = false
    /// Words of the previous chunk's tail used when `promptContinuation`.
    var promptTailWords: Int = 30
    /// A track that falls this far behind the leading track is treated as
    /// dead: the leader sets the cut pace and the laggard is zero-padded up to
    /// the cut index instead of stalling the session.
    var staleTrackSeconds: TimeInterval = 10
}

/// Bookkeeping for one closed chunk.
struct ChunkInfo {
    /// 0-based position in the session.
    let index: Int
    /// Nominal start, session-absolute seconds (inclusive).
    let startSeconds: TimeInterval
    /// Nominal end, session-absolute seconds (exclusive).
    var endSeconds: TimeInterval
    /// True when the engine was handed overlap ears beyond the nominal
    /// range, i.e. this was a hard cut and midpoint dedupe applied.
    let overlapped: Bool
    /// True when the cut point came from a detected silent run.
    let cutAtSilence: Bool
    /// Wall time of this chunk's `transcribeSegments` call, per track.
    var transcribeWallSeconds: [DebriefTrack: TimeInterval] = [:]
    /// Per-track transcription failure. One track failing never removes the
    /// other track's words; `finish()` only throws when *nothing* succeeded.
    var errors: [DebriefTrack: String] = [:]
    /// Silence inserted into a track because it lagged (or stopped) while the
    /// leading track kept producing. Non-zero means that track's audio for
    /// this chunk is incomplete.
    var paddedSeconds: [DebriefTrack: TimeInterval] = [:]
}

/// Delivered to `onChunkTranscribed` once a chunk's jobs are done.
struct ChunkResult {
    let info: ChunkInfo
    /// Already offset to session-absolute seconds and deduped.
    let segments: [DebriefTrack: [TranscriptSegment]]
}

/// Result of `finish()`.
struct ChunkedTranscript {
    /// One entry per configured track, sorted by `start`.
    let segments: [DebriefTrack: [TranscriptSegment]]
    /// Chunks in the order they were closed.
    let chunks: [ChunkInfo]
}

enum ChunkedTranscriptionError: Error, LocalizedError {
    /// Every chunk in the session failed to transcribe.
    case allChunksFailed(String)

    var errorDescription: String? {
        switch self {
        case .allChunksFailed(let detail):
            return "Transcription failed for every chunk: \(detail)"
        }
    }
}

/// Slices a live recording (one or two tracks) into ~5-minute chunks and
/// transcribes each chunk in the background while the recording continues.
///
/// Pipeline
/// --------
/// 1. `append(_:track:)` is called from the capture callbacks (mic recorder /
///    system-audio tap) with 16 kHz mono samples. It only hands the buffer to
///    an internal serial queue and returns; it never waits on transcription.
/// 2. On the serial queue the samples accumulate per track. As soon as *every*
///    track has `targetChunkSeconds` of unconsumed audio the cut point is
///    chosen (see below). The cut is a single absolute sample index shared by
///    all tracks, so both tracks are always sliced at the same instant.
/// 3. Closing a chunk hands one transcription job per track to a serial FIFO
///    chain of `Task`s. Jobs never run concurrently with each other, so the
///    rolling summarizer downstream sees chunks in order; they do run
///    concurrently with further `append` calls.
/// 4. `finish()` closes the final partial chunk, awaits the whole job chain and
///    returns per-track segments in session-absolute seconds, sorted by start.
///
/// Cut rule
/// --------
/// Search `[target − silenceSearch, target + silenceSearch]` (clamped to the
/// audio that has actually arrived) for the longest run of 20 ms windows whose
/// max RMS *across all tracks* stays ≤ `silenceRMS` for at least
/// `minSilenceSeconds`. Cut at that run's centre and pass exactly the nominal
/// range to the engine — no overlap, nothing to dedupe. If no such run exists,
/// hard-cut at the target mark and pass `overlapSeconds` of extra audio on each
/// side so the engine never starts or ends mid-word.
///
/// Dedupe rule
/// -----------
/// A chunk owns exactly the segments whose **midpoint** falls inside its
/// nominal half-open range `[start, end)`; for an overlapped chunk everything
/// else the engine produced (from the overlap ears) is dropped. Nominal ranges
/// tile the session without gaps, so every segment has exactly one owner: no
/// words are lost and none are duplicated. Silence-aligned chunks are handed
/// exactly their nominal range, so nothing is dropped from them at all.
///
/// Alignment contract
/// -------------------
/// Sample index *is* time: absolute sample `n` on one track is the same instant
/// as sample `n` on the other. The session performs no wall-clock alignment, so
/// callers must start all producers within roughly 100 ms of each other — start
/// the system-audio tap first, because its permission gate can block, then the
/// mic. Clock drift between the two devices (~0.4 s over a 2 h call at 50 ppm)
/// is accepted for v1. A track that stops, or falls more than
/// `staleTrackSeconds` behind the leading track, is treated as dead: cuts keep
/// happening at the leader's pace and the laggard is zero-padded with silence
/// up to the cut index (reported in `ChunkInfo.paddedSeconds`, logged once per
/// track). Samples that arrive for a padded track afterwards land after the
/// pad, so a track that comes back to life is offset by the padded amount.
///
/// Failure isolation
/// -----------------
/// A transcription failure is recorded per track in `ChunkInfo.errors` and the
/// session carries on. A track that fails every chunk never costs the other
/// track its words; `finish()` throws only when no (track, chunk) job at all
/// succeeded.
///
/// Concurrency choice: a `final class` with an internal serial `DispatchQueue`,
/// not an `actor`. `SystemAudioTapRecorder.onSamples` and `AudioRecorder`
/// deliver buffers through a *synchronous*, non-async callback on their own
/// serial delivery queue. An actor would force call sites to wrap each buffer
/// in `Task { await … }`, and unstructured tasks carry no ordering guarantee —
/// audio buffers could be appended out of order. A synchronous `append` that
/// does `queue.async` returns just as fast and preserves arrival order.
final class ChunkedTranscriptionSession: @unchecked Sendable {

    // MARK: - Constants

    /// The engines in this app are fed 16 kHz mono; so is this session.
    private static let sampleRate: Double = 16_000
    /// RMS window used by the silence search.
    private static let rmsWindowSeconds: TimeInterval = 0.02
    /// A trailing remnant shorter than this is not worth its own chunk.
    private static let minFinalChunkSeconds: TimeInterval = 0.5

    // MARK: - Configuration

    private let engine: any TranscriptionEngine
    private let tracks: [DebriefTrack]
    private let language: String?
    private let micSensitivity: MicSensitivity
    private let config: ChunkingConfig

    /// Fired on a background thread after every chunk's jobs complete, in chunk
    /// order. Set it before the first `append`. A later story feeds the rolling
    /// summarizer from here.
    ///
    /// The callback runs *inside* the chunk job that `finish()` awaits, so
    /// calling `finish()` (or setting this property) from within it deadlocks.
    var onChunkTranscribed: ((ChunkResult) -> Void)? {
        get { queue.sync { _onChunkTranscribed } }
        set { queue.sync { _onChunkTranscribed = newValue } }
    }

    // MARK: - Queue-confined state

    private let queue = DispatchQueue(label: "com.duadigital.dikta.chunkedtranscription", qos: .userInitiated)

    private var _onChunkTranscribed: ((ChunkResult) -> Void)?
    /// Unconsumed audio per track. `buffers[t][0]` is absolute sample
    /// `bufferStartSample` for every track.
    private var buffers: [DebriefTrack: [Float]] = [:]
    /// Absolute index of the first retained sample (shared by all tracks).
    private var bufferStartSample = 0
    /// Total samples appended per track since the session started.
    private var appendedCount: [DebriefTrack: Int] = [:]
    /// Absolute index where the currently open chunk nominally starts.
    private var chunkStartSample = 0
    private var chunkInfos: [ChunkInfo] = []
    private var collected: [DebriefTrack: [TranscriptSegment]] = [:]
    /// Tracks already reported as lagging, so the warning is logged once each.
    private var paddedTracks: Set<DebriefTrack> = []
    /// Tail text of the previous chunk per track, for prompt continuation.
    private var promptTails: [DebriefTrack: String] = [:]
    /// Serial FIFO chain: each chunk's job awaits the previous chunk's job.
    private var jobChain: Task<Void, Never>?
    private var finished = false

    // MARK: - Init

    /// - Parameters:
    ///   - engine: backend used for every chunk; calls are serialized.
    ///   - tracks: the tracks captured in this session, e.g. `[.me]` or
    ///     `[.me, .them]`. Duplicates are ignored.
    ///   - language: language hint forwarded to the engine.
    ///   - micSensitivity: sensitivity preset forwarded to the engine.
    ///   - config: slicer tunables.
    init(
        engine: any TranscriptionEngine,
        tracks: [DebriefTrack],
        language: String?,
        micSensitivity: MicSensitivity,
        config: ChunkingConfig = ChunkingConfig()
    ) {
        self.engine = engine
        // Deterministic order, deduplicated: jobs run per track in this order.
        var seen = Set<DebriefTrack>()
        self.tracks = tracks.filter { seen.insert($0).inserted }
        self.language = language
        self.micSensitivity = micSensitivity
        self.config = config

        for track in self.tracks {
            buffers[track] = []
            appendedCount[track] = 0
            collected[track] = []
        }
    }

    // MARK: - Ingest

    /// Hand 16 kHz mono samples for one track to the session.
    ///
    /// Safe to call from a realtime-ish audio delivery queue: it dispatches and
    /// returns, and never blocks on transcription. Buffers are consumed in
    /// call order per track.
    func append(_ samples: [Float], track: DebriefTrack) {
        guard !samples.isEmpty else { return }
        queue.async { self.ingest(samples, track: track) }
    }

    private func ingest(_ samples: [Float], track: DebriefTrack) {
        guard !finished, buffers[track] != nil else { return }
        buffers[track]?.append(contentsOf: samples)
        appendedCount[track, default: 0] += samples.count
        // One append can carry more than a chunk's worth of audio.
        while closeNextChunkIfReady() {}
    }

    // MARK: - Cut decision

    /// - Returns: true when a chunk was closed, so the caller can look again.
    private func closeNextChunkIfReady() -> Bool {
        let targetSamples = samples(from: config.targetChunkSeconds)
        guard targetSamples > 0 else { return false }

        // The leading track decides when a cut is *possible*; a cut actually
        // happens once every track has caught up, or once the laggards are far
        // enough behind to count as dead (see `staleTrackSeconds`). Without the
        // second clause one silent or stopped track stalls the whole session.
        let leadingAvailable = max(0, leadingAppendedCount() - chunkStartSample)
        guard leadingAvailable >= targetSamples else { return false }

        let commonAvailable = max(0, trailingAppendedCount() - chunkStartSample)
        let allTracksReady = commonAvailable >= targetSamples
        let lagSamples = leadingAppendedCount() - trailingAppendedCount()
        // A lag beyond `staleTrackSeconds` wins over `allTracksReady`: a track
        // that stopped while still holding a chunk's worth of unconsumed audio
        // would otherwise pin the cut point and stall the session for good.
        let staleTrackPresent = lagSamples > samples(from: config.staleTrackSeconds)
        guard allTracksReady || staleTrackPresent else { return false }

        // A track that is merely a buffer or two behind must never be padded,
        // so in the healthy case the cut is bounded by what *every* track has.
        let boundAvailable = staleTrackPresent ? leadingAvailable : commonAvailable
        let padLaggingTracks = staleTrackPresent

        let targetMark = chunkStartSample + targetSamples
        let searchSamples = samples(from: config.silenceSearchSeconds)
        let searchLow = max(chunkStartSample + 1, targetMark - searchSamples)
        let searchHigh = min(targetMark + searchSamples, chunkStartSample + boundAvailable)

        if let silenceCut = longestSilenceCut(in: searchLow..<searchHigh) {
            closeChunk(at: silenceCut, cutAtSilence: true, overlapped: false, padLaggingTracks: padLaggingTracks)
            return true
        }

        // A hard cut needs its right-hand overlap ear to exist already,
        // otherwise the engine would still end mid-word. Waiting also widens
        // the silence search on the next append, which is the preferred cut.
        let overlapSamples = samples(from: config.overlapSeconds)
        guard boundAvailable >= targetSamples + overlapSamples else { return false }

        closeChunk(at: targetMark, cutAtSilence: false, overlapped: overlapSamples > 0, padLaggingTracks: padLaggingTracks)
        return true
    }

    /// Absolute sample index reached by the track that is furthest ahead.
    private func leadingAppendedCount() -> Int {
        tracks.map { appendedCount[$0] ?? 0 }.max() ?? 0
    }

    /// Absolute sample index reached by the track that is furthest behind.
    private func trailingAppendedCount() -> Int {
        tracks.map { appendedCount[$0] ?? 0 }.min() ?? 0
    }

    /// Centre of the longest run of ≥ `minSilenceSeconds` where the max RMS
    /// across all tracks stays ≤ `silenceRMS`, or nil when there is none.
    private func longestSilenceCut(in range: Range<Int>) -> Int? {
        let windowSamples = samples(from: Self.rmsWindowSeconds)
        let minRunSamples = samples(from: config.minSilenceSeconds)
        guard windowSamples > 0, minRunSamples > 0, range.count >= windowSamples else { return nil }

        var bestStart = 0
        var bestLength = 0
        var runStart: Int?
        var position = range.lowerBound

        while position + windowSamples <= range.upperBound {
            if maxRMS(at: position, count: windowSamples) <= config.silenceRMS {
                if runStart == nil { runStart = position }
            } else if let start = runStart {
                let length = position - start
                if length > bestLength { bestStart = start; bestLength = length }
                runStart = nil
            }
            position += windowSamples
        }
        if let start = runStart {
            let length = position - start
            if length > bestLength { bestStart = start; bestLength = length }
        }

        guard bestLength >= minRunSamples else { return nil }
        // `searchLow` is already > `chunkStartSample`, so the centre of any run
        // found inside the range necessarily advances the session.
        return bestStart + bestLength / 2
    }

    /// Max RMS across all tracks for the window starting at absolute index
    /// `absoluteStart`.
    private func maxRMS(at absoluteStart: Int, count: Int) -> Float {
        var maximum: Float = 0
        let offset = absoluteStart - bufferStartSample
        for track in tracks {
            guard let buffer = buffers[track], offset >= 0, offset + count <= buffer.count else { continue }
            var sumOfSquares: Float = 0
            for index in offset..<(offset + count) {
                let value = buffer[index]
                sumOfSquares += value * value
            }
            let rms = (sumOfSquares / Float(count)).squareRoot()
            if rms > maximum { maximum = rms }
        }
        return maximum
    }

    // MARK: - Chunk closing

    private func closeChunk(at cutSample: Int, cutAtSilence: Bool, overlapped: Bool, padLaggingTracks: Bool) {
        let nominalStart = chunkStartSample
        let nominalEnd = cutSample
        guard nominalEnd > nominalStart else { return }

        let overlapSamples = overlapped ? samples(from: config.overlapSeconds) : 0
        let engineLow = max(bufferStartSample, nominalStart - overlapSamples)
        var engineHigh = min(bufferStartSample + minimumBufferedCount(), nominalEnd + overlapSamples)

        var paddedSeconds: [DebriefTrack: TimeInterval] = [:]
        if padLaggingTracks {
            // Sample index is time, so a track that stopped (or never started)
            // is filled with silence rather than having its timeline shifted.
            // Samples that arrive for it later land *after* the pad.
            engineHigh = min(bufferStartSample + maximumBufferedCount(), nominalEnd + overlapSamples)
            for track in tracks {
                let reached = appendedCount[track] ?? 0
                guard reached < engineHigh else { continue }
                let padCount = engineHigh - reached
                buffers[track]?.append(contentsOf: [Float](repeating: 0, count: padCount))
                appendedCount[track] = engineHigh
                paddedSeconds[track] = seconds(from: padCount)
                // A short tail pad at hangup is normal (producers stop a buffer
                // apart); only a stale-sized pad means the track actually died.
                let staleSized = padCount >= samples(from: config.staleTrackSeconds)
                if staleSized, paddedTracks.insert(track).inserted {
                    AppLogger.audio.warning("Debrief track \(track.rawValue, privacy: .public) fell behind the leading track; padding with silence and treating it as dead.")
                } else if !staleSized {
                    AppLogger.audio.debug("Debrief track \(track.rawValue, privacy: .public) padded \(padCount) samples to align chunk end.")
                }
            }
        }

        var chunkSamples: [DebriefTrack: [Float]] = [:]
        for track in tracks {
            guard let buffer = buffers[track] else { continue }
            let low = max(0, engineLow - bufferStartSample)
            let high = min(buffer.count, engineHigh - bufferStartSample)
            chunkSamples[track] = low < high ? Array(buffer[low..<high]) : []
        }

        let info = ChunkInfo(
            index: chunkInfos.count,
            startSeconds: seconds(from: nominalStart),
            endSeconds: seconds(from: nominalEnd),
            overlapped: overlapped,
            cutAtSilence: cutAtSilence,
            paddedSeconds: paddedSeconds
        )
        chunkInfos.append(info)
        chunkStartSample = nominalEnd

        // Release consumed audio, keeping only the next chunk's possible
        // left-hand overlap ear. Retained RAM stays at ~one chunk + one ear
        // per track, independent of session length.
        let keepFrom = max(bufferStartSample, nominalEnd - samples(from: config.overlapSeconds))
        let dropCount = min(keepFrom - bufferStartSample, minimumBufferedCount())
        if dropCount > 0 {
            for track in tracks {
                buffers[track]?.removeFirst(dropCount)
            }
            bufferStartSample += dropCount
        }

        enqueueJob(info: info, samples: chunkSamples, engineStartSeconds: seconds(from: engineLow))
    }

    /// Buffered sample count common to every track (relative to `bufferStartSample`).
    private func minimumBufferedCount() -> Int {
        guard !tracks.isEmpty else { return 0 }
        return tracks.map { buffers[$0]?.count ?? 0 }.min() ?? 0
    }

    /// Buffered sample count of the track furthest ahead.
    private func maximumBufferedCount() -> Int {
        tracks.map { buffers[$0]?.count ?? 0 }.max() ?? 0
    }

    // MARK: - Job chain

    private func enqueueJob(info: ChunkInfo, samples: [DebriefTrack: [Float]], engineStartSeconds: TimeInterval) {
        let previous = jobChain
        jobChain = Task { [self] in
            _ = await previous?.value
            await runChunk(info: info, samples: samples, engineStartSeconds: engineStartSeconds)
        }
    }

    private func runChunk(info: ChunkInfo, samples: [DebriefTrack: [Float]], engineStartSeconds: TimeInterval) async {
        var info = info
        var segmentsByTrack: [DebriefTrack: [TranscriptSegment]] = [:]

        for track in tracks {
            let prompt: String? = queue.sync {
                config.promptContinuation ? promptTails[track] : nil
            }
            let started = Date()
            do {
                let raw = try await engine.transcribeSegments(
                    samples[track] ?? [],
                    language: language,
                    micSensitivity: micSensitivity,
                    promptText: (prompt?.isEmpty == false) ? prompt : nil
                )
                info.transcribeWallSeconds[track] = Date().timeIntervalSince(started)

                // Engine timestamps are relative to the samples passed; shift
                // them to session-absolute seconds.
                let absolute = raw.map {
                    TranscriptSegment(
                        start: $0.start + engineStartSeconds,
                        end: $0.end + engineStartSeconds,
                        text: $0.text
                    )
                }
                // Midpoint ownership. Only overlapped chunks can produce
                // segments outside their nominal range.
                let owned = info.overlapped ? absolute.filter { segment in
                    let midpoint = (segment.start + segment.end) / 2
                    return midpoint >= info.startSeconds && midpoint < info.endSeconds
                } : absolute
                segmentsByTrack[track] = owned
            } catch {
                // One track failing must not cost the other track its words.
                info.transcribeWallSeconds[track] = Date().timeIntervalSince(started)
                segmentsByTrack[track] = []
                info.errors[track] = error.localizedDescription
            }
        }

        let jobInfo = info
        let (stored, callback) = queue.sync { () -> (ChunkInfo, ((ChunkResult) -> Void)?) in
            for track in tracks {
                let owned = segmentsByTrack[track] ?? []
                collected[track, default: []].append(contentsOf: owned)
                if config.promptContinuation, jobInfo.errors[track] == nil {
                    promptTails[track] = Self.tail(of: owned, words: config.promptTailWords)
                }
            }
            // Merge only the fields this job owns. `endSeconds` must not be
            // written back: `finish()` may already have folded a sub-half-second
            // remnant into this chunk while the job was running.
            guard jobInfo.index < chunkInfos.count else { return (jobInfo, _onChunkTranscribed) }
            chunkInfos[jobInfo.index].transcribeWallSeconds = jobInfo.transcribeWallSeconds
            chunkInfos[jobInfo.index].errors = jobInfo.errors
            return (chunkInfos[jobInfo.index], _onChunkTranscribed)
        }
        // Fired off the ingest queue so a slow consumer cannot stall capture.
        callback?(ChunkResult(info: stored, segments: segmentsByTrack))
    }

    private static func tail(of segments: [TranscriptSegment], words: Int) -> String {
        guard words > 0 else { return "" }
        let joined = segments.map(\.text).joined(separator: " ")
        let parts = joined.split(whereSeparator: { $0 == " " || $0.isNewline })
        guard !parts.isEmpty else { return "" }
        return parts.suffix(words).joined(separator: " ")
    }

    // MARK: - Finish

    /// Close the final partial chunk, wait for every queued job and return the
    /// full transcript. Throws only when *every* chunk failed.
    func finish() async throws -> ChunkedTranscript {
        let chain: Task<Void, Never>? = queue.sync {
            guard !finished else { return jobChain }
            finished = true
            closeFinalChunk()
            return jobChain
        }
        await chain?.value

        let (segments, chunks) = queue.sync { () -> ([DebriefTrack: [TranscriptSegment]], [ChunkInfo]) in
            var sorted: [DebriefTrack: [TranscriptSegment]] = [:]
            for track in tracks {
                // enumerated() keeps arrival order for equal start times.
                sorted[track] = (collected[track] ?? [])
                    .enumerated()
                    .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
                    .map(\.element)
            }
            return (sorted, chunkInfos)
        }

        // Throw only when not a single (track, chunk) job succeeded. A track
        // that failed every chunk while the other track worked still returns
        // the good track's transcript; its failures live in `ChunkInfo.errors`.
        let anySuccess = chunks.contains { chunk in tracks.contains { chunk.errors[$0] == nil } }
        if !chunks.isEmpty, !anySuccess {
            let detail = chunks.flatMap { chunk in
                chunk.errors.map { "chunk \(chunk.index) \($0.key.rawValue): \($0.value)" }
            }.joined(separator: " | ")
            throw ChunkedTranscriptionError.allChunksFailed(detail)
        }
        return ChunkedTranscript(segments: segments, chunks: chunks)
    }

    private func closeFinalChunk() {
        // The final chunk runs to the end of the LONGEST track, so nothing a
        // track recorded is ever dropped; shorter tracks are zero-padded up to
        // that length. The remnant rule below is measured on the longest track.
        let end = leadingAppendedCount()
        let remaining = end - chunkStartSample
        guard remaining > 0 else { return }

        if remaining >= samples(from: Self.minFinalChunkSeconds) {
            closeChunk(at: end, cutAtSilence: false, overlapped: false, padLaggingTracks: true)
        } else if let last = chunkInfos.indices.last {
            // Under half a second: the engine emits nothing from audio this
            // short, so it is folded into the previous chunk's nominal range
            // (leaving no gap in the timeline) rather than transcribed. Up to
            // 0.5 s of trailing audio is therefore folded, not transcribed.
            chunkInfos[last].endSeconds = seconds(from: end)
            chunkStartSample = end
        } else {
            // Only audio in the session and shorter than half a second: drop.
            chunkStartSample = end
        }
    }

    // MARK: - Units

    private func samples(from seconds: TimeInterval) -> Int {
        max(0, Int((seconds * Self.sampleRate).rounded()))
    }

    private func seconds(from sampleIndex: Int) -> TimeInterval {
        TimeInterval(sampleIndex) / Self.sampleRate
    }
}
