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
}
