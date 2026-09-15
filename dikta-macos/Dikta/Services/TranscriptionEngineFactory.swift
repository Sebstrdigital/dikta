import Foundation

/// Builds the `TranscriptionEngine` for a given `TranscriptionEngineKind`.
///
/// A stateless namespace rather than a class: `MenuBarViewModel` stores the
/// `make` function itself (as a closure) so tests can inject a fake factory
/// without touching this type.
enum TranscriptionEngineFactory {
    /// - Parameters:
    ///   - kind: Which backend to build.
    ///   - model: Whisper model to use when `kind == .whisper`. Ignored for `.appleDictation`.
    ///   - configService: Passed through to `AppleDictationEngine`, which reads
    ///     the currently configured `Language` from it directly rather than
    ///     taking a separate init parameter.
    @MainActor
    static func make(kind: TranscriptionEngineKind, model: WhisperModel, configService: ConfigService) -> any TranscriptionEngine {
        switch kind {
        case .whisper:
            return Transcriber(model: model)
        case .appleDictation:
            guard #available(macOS 26.0, *) else {
                // The menu hides this option pre-macOS 26, so this only fires
                // for a config saved on a newer Mac and opened on an older
                // one. Fall back to Whisper rather than returning an engine
                // that could never become ready.
                AppLogger.transcription.error("Apple Dictation selected but unavailable on this macOS version; falling back to Whisper")
                return Transcriber(model: model)
            }
            return AppleDictationEngine(configService: configService)
        }
    }
}
