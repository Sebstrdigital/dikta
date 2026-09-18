import Foundation

/// Coarse progress reported by `DebriefPipeline.run` so the menu can show what
/// the app is busy with. Reported in this order; each stage fires at most once.
enum DebriefStage {
    case transcribing
    case summarizing
    case saving
}

/// Everything a completed debrief produced: the raw transcript, the structured
/// summary, the plain text that gets pasted, where it was all saved, and which
/// summarizer engine actually produced the result.
struct DebriefResult {
    let transcript: String
    let summary: DebriefSummary
    let renderedText: String
    let paths: DebriefSessionPaths
    let engineName: String
}

/// Runs the post-meeting debrief end to end: save audio, transcribe, summarize,
/// render, save. Deliberately holds no UI state — the caller owns status text,
/// pasting and error surfacing — so the whole flow is testable with a fake
/// engine, a fake summarizer and a `DebriefStore` pointed at a temp directory.
@MainActor
final class DebriefPipeline {
    private let engine: any TranscriptionEngine
    private let summarizer: DebriefSummarizer
    private let store: DebriefStore
    /// Reads the per-track WAVs a call session left on disk (`runTwoTrack`).
    private let audioLoader = AudioFileLoader()

    /// Seconds to wait for transcription before giving up. Much longer than the
    /// 60 s used for normal dictation: a debrief can be many minutes of audio.
    private let transcriptionTimeout: TimeInterval

    init(
        engine: any TranscriptionEngine,
        summarizer: DebriefSummarizer,
        store: DebriefStore,
        transcriptionTimeout: TimeInterval = 1800
    ) {
        self.engine = engine
        self.summarizer = summarizer
        self.store = store
        self.transcriptionTimeout = transcriptionTimeout
    }

    /// The language the summary is written and rendered in. Only Swedish and
    /// English are supported for the PoC; anything else falls back to English.
    static func renderLanguage(for code: String?) -> String {
        guard let code, code == "sv" || code == "en" else { return "en" }
        return code
    }

    /// - Parameters:
    ///   - samples: 16 kHz mono audio, either recorded or loaded from a file.
    ///   - originalFile: When the audio came from an imported file, that file is
    ///     copied into the session folder alongside the rendered `audio.wav`.
    ///   - onStage: Called on the main actor as each stage begins.
    func run(
        samples: [Float],
        language: String?,
        micSensitivity: MicSensitivity,
        originalFile: URL? = nil,
        onStage: @escaping @MainActor (DebriefStage) -> Void
    ) async throws -> DebriefResult {
        // Persist the audio first: if anything downstream fails, the recording
        // the user just made is still on disk and can be re-run via import.
        let paths = try store.createSession()
        try store.writeAudio(samples, to: paths)
        if let originalFile {
            try store.copyOriginalAudio(from: originalFile, to: paths)
        }

        onStage(.transcribing)

        let timeoutNanoseconds = UInt64(max(0, transcriptionTimeout) * 1_000_000_000)
        let transcript = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.engine.transcribe(samples, language: language, micSensitivity: micSensitivity)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw TranscriptionTimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }

        return try await finishTranscribedDebrief(
            transcript: transcript,
            paths: paths,
            language: language,
            onStage: onStage
        )
    }

    /// Everything after a transcript exists: save it, reject silence,
    /// summarize, render, save the summary. Shared verbatim by `run` (one
    /// mic track) and `runTwoTrack` (a merged Me/Them transcript) so there is
    /// exactly one summarize/save/report path.
    private func finishTranscribedDebrief(
        transcript: String,
        paths: DebriefSessionPaths,
        language: String?,
        onStage: @escaping @MainActor (DebriefStage) -> Void
    ) async throws -> DebriefResult {
        try store.writeTranscript(transcript, to: paths)

        // Whisper answers silence with a marker like `[BLANK_AUDIO]`, not an
        // empty string, so summarizing it would produce a confident summary of
        // nothing. Same rules the dictation path uses.
        guard !TranscriptSanitizer.isEffectivelyEmpty(transcript) else {
            throw DebriefSummarizerError.emptyTranscript
        }

        onStage(.summarizing)

        let renderLanguage = Self.renderLanguage(for: language)
        // Engines write "Not specified"/"N/A" where the schema asks for null;
        // normalize before rendering so that never reaches the pasted text.
        // validated() then checks the surviving due/owner values against the
        // transcript itself, catching the clearest fabrications (a bare year
        // or ISO date, a name-shaped owner that was never said) that
        // normalized() has no way to know about.
        let summary = try await summarizer
            .summarize(transcript: transcript, language: renderLanguage)
            .normalized()
            .validated(against: transcript)
        let renderedText = summary.renderPlainText(language: renderLanguage)

        onStage(.saving)

        try store.writeSummary(renderedText, to: paths)

        // A chained summarizer knows which of its engines actually answered;
        // a single engine can only be itself.
        let engineName = (summarizer as? ChainedDebriefSummarizer)?.lastUsedEngineName ?? summarizer.name

        return DebriefResult(
            transcript: transcript,
            summary: summary,
            renderedText: renderedText,
            paths: paths,
            engineName: engineName
        )
    }

    // MARK: - Call debrief (two tracks on disk)

    /// Runs a debrief over a call session that was captured as two WAV files
    /// on disk — `me.wav` (microphone) and `them.wav` (system audio) — rather
    /// than a single in-RAM sample buffer. Both tracks are transcribed with
    /// timestamps, merged into one speaker-labeled transcript, and then handed
    /// to exactly the same summarize/save path as `run`.
    ///
    /// A missing or empty track is allowed (nobody spoke on it, or the user
    /// never granted system audio permission): it simply contributes no
    /// segments, and the merged transcript carries only the other speaker.
    func runTwoTrack(
        paths: DebriefSessionPaths,
        language: String?,
        micSensitivity: MicSensitivity,
        onStage: @escaping @MainActor (DebriefStage) -> Void
    ) async throws -> DebriefResult {
        onStage(.transcribing)

        let transcript = try await mergedTranscript(
            paths: paths,
            language: language,
            micSensitivity: micSensitivity
        )

        return try await finishTranscribedDebrief(
            transcript: transcript,
            paths: paths,
            language: language,
            onStage: onStage
        )
    }

    /// Slice 1's transcription step for a call: read both whole tracks off
    /// disk, transcribe each one in full (sequentially — one Whisper model is
    /// loaded at a time), merge, render.
    ///
    /// Deliberately the single seam between capture and summarization: the
    /// live-chunking story replaces this method's body with the rolling
    /// chunked transcriber without touching `runTwoTrack` or anything after
    /// it.
    private func mergedTranscript(
        paths: DebriefSessionPaths,
        language: String?,
        micSensitivity: MicSensitivity
    ) async throws -> String {
        // One track in RAM at a time: each `loadTrack` result is consumed by
        // the `transcribeTrack` call in the same expression and released
        // before the next track is read, so peak memory is one track's
        // samples (~460 MB for a two-hour track at 16 kHz Float32), not both.
        let meSegments = try await transcribeTrack(
            loadTrack(.me, in: paths), language: language, micSensitivity: micSensitivity
        )
        let themSegments = try await transcribeTrack(
            loadTrack(.them, in: paths), language: language, micSensitivity: micSensitivity
        )

        return TwoTrackMerger.render(TwoTrackMerger.merge(me: meSegments, them: themSegments))
    }

    /// Loads one track's samples, or an empty array when the track is absent,
    /// empty or unreadable — a call with one silent side is a normal outcome,
    /// not a failure, so it is logged rather than thrown.
    private func loadTrack(_ track: DebriefTrack, in paths: DebriefSessionPaths) -> [Float] {
        guard store.hasTrack(track, in: paths) else {
            AppLogger.audio.info("DebriefPipeline: track \(track.rawValue) is missing or empty — no segments for that speaker")
            return []
        }
        do {
            return try audioLoader.load(url: paths.audioURL(for: track))
        } catch {
            AppLogger.audio.error("DebriefPipeline: failed to load track \(track.rawValue): \(error.localizedDescription) — treating it as empty")
            return []
        }
    }

    /// Transcribes one whole track, racing it against a timeout scaled to how
    /// much audio it actually is (see `trackTranscriptionTimeout`). Empty
    /// input short-circuits: no engine call, no segments.
    private func transcribeTrack(
        _ samples: [Float],
        language: String?,
        micSensitivity: MicSensitivity
    ) async throws -> [TranscriptSegment] {
        guard !samples.isEmpty else { return [] }

        let audioSeconds = Double(samples.count) / AudioFileLoader.targetSampleRate
        let timeout = Self.trackTranscriptionTimeout(base: transcriptionTimeout, audioSeconds: audioSeconds)
        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)

        return try await withThrowingTaskGroup(of: [TranscriptSegment].self) { group in
            group.addTask {
                try await self.engine.transcribeSegments(
                    samples,
                    language: language,
                    micSensitivity: micSensitivity,
                    promptText: nil
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw TranscriptionTimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Per-track transcription budget: the pipeline's configured timeout, or
    /// 1.5x the track's own duration when that is longer. A two-hour call is
    /// far past the flat 30-minute default, and transcription time scales
    /// with audio length, so the flat value alone would fail every long call.
    /// Pure, so the scaling is unit-tested directly.
    static func trackTranscriptionTimeout(base: TimeInterval, audioSeconds: TimeInterval) -> TimeInterval {
        max(base, audioSeconds * 1.5)
    }
}
