import Foundation

/// Supported languages for dictation
enum Language: String, Codable, CaseIterable {
    case english = "en"
    case swedish = "sv"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .swedish: return "Svenska"
        }
    }

    /// Whisper language code
    var whisperCode: String {
        rawValue
    }
}
