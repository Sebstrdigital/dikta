import Foundation

/// Which speech-to-text backend is active.
///
/// `.whisper` (the long-standing default) is WhisperKit's on-device models,
/// selectable via `WhisperModel`. `.appleDictation` is Apple's Speech
/// framework `DictationTranscriber` (see `AppleDictationEngine`), available
/// only on macOS 26+; the menu hides it on older systems and
/// `TranscriptionEngineFactory` falls back to Whisper if a saved config
/// somehow requests it there anyway.
///
/// Persisted in `AppConfig.engine`. A missing key (configs saved before this
/// case existed) decodes to `.whisper`.
enum TranscriptionEngineKind: String, Codable, CaseIterable {
    case whisper
    case appleDictation

    var displayName: String {
        switch self {
        case .whisper: return "Whisper (on-device models)"
        case .appleDictation: return "Apple Dictation (macOS 26)"
        }
    }
}
