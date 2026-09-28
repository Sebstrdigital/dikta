import Foundation

/// Which speech-to-text engine transcribes dictation: local Whisper (via
/// WhisperKit) or one of the Parakeet variants (via FluidAudio, see US-003).
///
/// `rawValue` is the persisted identifier in `AppConfig` and must stay stable
/// so saved configs keep decoding. `.whisper` is the default and the only
/// kind that existed before this feature, so a config saved without an
/// `engine` key — or with a raw value this build doesn't recognize yet —
/// falls back to it rather than failing to decode (see
/// `AppConfig.init(from:)`).
enum TranscriptionEngineKind: String, Codable, CaseIterable {
    case whisper
    case parakeetRedux = "parakeet-redux"
    case parakeetV3 = "parakeet-v3"
    case parakeetUltra = "parakeet-ultra"

    var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .parakeetRedux: return "Parakeet Redux"
        case .parakeetV3: return "Parakeet v3"
        case .parakeetUltra: return "Parakeet Ultra"
        }
    }

    /// Approximate on-disk size of the downloaded model, in megabytes. Used for
    /// the free-disk-space pre-check before a download starts (see
    /// `WhisperModel.approximateSizeMB` for the equivalent Whisper-side check).
    var approximateSizeMB: Int {
        switch self {
        case .whisper: return 650
        case .parakeetRedux: return 480
        case .parakeetV3: return 600
        case .parakeetUltra: return 1200
        }
    }

    /// True only for `.whisper`: the Whisper Model submenu (small/turbo/medium/
    /// KB-Whisper) picks among Whisper model sizes, which don't apply to the
    /// Parakeet variants — each of those is its own fixed model.
    var usesWhisperModelSubmenu: Bool {
        self == .whisper
    }
}
