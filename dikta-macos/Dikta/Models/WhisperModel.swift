import Foundation

/// Available Whisper models.
///
/// `rawValue` is the persisted identifier in `AppConfig` (`"small"`/`"medium"`/`"turbo"`)
/// and must stay stable so saved configs keep decoding. `variant` is the fully qualified,
/// engine-qualified model id WhisperKit expects — it must match both the bundled
/// model's folder name (`WhisperModels/<variant>`) and the remote repo's variant
/// folder name, so the bundled and download code paths never disagree about which
/// model they mean.
///
/// `medium` is kept only so previously saved configs keep decoding — new installs
/// default to `small` (bundled) and `turbo` is the recommended download. Use
/// `sortOrder` when presenting models in a UI list so `medium` doesn't crowd out
/// the two recommended options.
enum WhisperModel: String, Codable, CaseIterable {
    case small = "small"
    case turbo = "turbo"
    case medium = "medium"

    /// Hugging Face repo hosting the CoreML model variants.
    var repo: String {
        "argmaxinc/whisperkit-coreml"
    }

    /// Engine-qualified variant identifier, e.g. "openai_whisper-small".
    var variant: String {
        switch self {
        case .small: return "openai_whisper-small"
        case .turbo: return "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .medium: return "openai_whisper-medium"
        }
    }

    var displayName: String {
        switch self {
        case .small: return "Small (Balanced)"
        case .turbo: return "Large v3 Turbo (Recommended)"
        case .medium: return "Medium (Legacy)"
        }
    }

    var description: String {
        switch self {
        case .small: return "~500MB, good balance"
        case .turbo: return "~650MB, multilingual, best overall"
        case .medium: return "~1.5GB, best accuracy"
        }
    }

    /// Approximate on-disk size of the downloaded model, in megabytes. Used for
    /// the free-disk-space pre-check before a download starts (see
    /// `Transcriber.hasEnoughDiskSpace`).
    var approximateSizeMB: Int {
        switch self {
        case .small: return 490
        case .turbo: return 650
        case .medium: return 1530
        }
    }

    /// Marks the model recommended in UI lists (e.g. a star or "Recommended" badge).
    var isRecommended: Bool {
        self == .turbo
    }

    /// Display order for UI lists: small, turbo, medium — keeps the legacy
    /// `medium` case from crowding out the two recommended options, without
    /// disturbing `CaseIterable`'s declaration order (which controls Codable
    /// compatibility, not display order).
    var sortOrder: Int {
        switch self {
        case .small: return 0
        case .turbo: return 1
        case .medium: return 2
        }
    }
}
