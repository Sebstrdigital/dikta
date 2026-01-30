import Foundation

/// Available Whisper models
enum WhisperModel: String, Codable, CaseIterable {
    case base = "base"
    case small = "small"
    case medium = "medium"

    var displayName: String {
        switch self {
        case .base: return "Base (Fast)"
        case .small: return "Small (Balanced)"
        case .medium: return "Medium (Accurate)"
        }
    }

    var description: String {
        switch self {
        case .base: return "~150MB, fastest, basic accuracy"
        case .small: return "~500MB, good balance"
        case .medium: return "~1.5GB, best accuracy"
        }
    }
}
