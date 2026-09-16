import Foundation

/// Available Whisper models.
///
/// `rawValue` is the persisted identifier in `AppConfig` (`"small"`/`"medium"`) and
/// must stay stable so saved configs keep decoding. `variant` is the fully qualified,
/// engine-qualified model id WhisperKit expects — it must match both the bundled
/// model's folder name (`WhisperModels/<variant>`) and the remote repo's variant
/// folder name, so the bundled and download code paths never disagree about which
/// model they mean.
enum WhisperModel: String, Codable, CaseIterable {
    case small = "small"
    case medium = "medium"

    /// Hugging Face repo hosting the CoreML model variants.
    var repo: String {
        "argmaxinc/whisperkit-coreml"
    }

    /// Engine-qualified variant identifier, e.g. "openai_whisper-small".
    var variant: String {
        switch self {
        case .small: return "openai_whisper-small"
        case .medium: return "openai_whisper-medium"
        }
    }

    var displayName: String {
        switch self {
        case .small: return "Small (Balanced)"
        case .medium: return "Medium (Accurate)"
        }
    }

    var description: String {
        switch self {
        case .small: return "~500MB, good balance"
        case .medium: return "~1.5GB, best accuracy"
        }
    }
}
