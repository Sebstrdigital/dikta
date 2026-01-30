import Foundation

/// Full application configuration (matches Python config format)
struct AppConfig: Codable {
    var version: Int
    var hotkeys: HotkeyConfigs
    var activeMode: HotkeyMode
    var outputMode: OutputMode
    var history: [HistoryItem]
    var whisperModel: String
    var llmModel: String

    struct HotkeyConfigs: Codable {
        var toggle: HotkeyConfig
        var pushToTalk: HotkeyConfig

        enum CodingKeys: String, CodingKey {
            case toggle
            case pushToTalk = "push_to_talk"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case hotkeys
        case activeMode = "active_mode"
        case outputMode = "output_mode"
        case history
        case whisperModel = "whisper_model"
        case llmModel = "llm_model"
    }

    /// Default configuration
    static let `default` = AppConfig(
        version: 2,
        hotkeys: HotkeyConfigs(
            toggle: .defaultToggle,
            pushToTalk: .defaultPushToTalk
        ),
        activeMode: .toggle,
        outputMode: .general,
        history: [],
        whisperModel: "base.en",
        llmModel: "gemma3"
    )

    /// Maximum history items to keep
    static let historyLimit = 5
}
