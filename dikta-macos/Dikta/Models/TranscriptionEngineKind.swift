import Foundation

/// Legacy persisted STT selection. Runtime transcription is always Ultra, but
/// these raw values remain decodable so upgrading never invalidates or rewrites
/// an existing config merely because it contains an old engine preference.
enum TranscriptionEngineKind: String, Codable {
    case whisper
    case parakeetRedux = "parakeet-redux"
    case parakeetV3 = "parakeet-v3"
    case parakeetUltra = "parakeet-ultra"
}
