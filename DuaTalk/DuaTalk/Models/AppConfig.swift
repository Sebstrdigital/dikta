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
    var language: Language

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
        case language
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
        whisperModel: "base",  // Use multilingual model for language support
        llmModel: "gemma3",
        language: .english
    )

    /// Maximum history items to keep
    static let historyLimit = 5

    /// Memberwise initializer
    init(version: Int, hotkeys: HotkeyConfigs, activeMode: HotkeyMode, outputMode: OutputMode, history: [HistoryItem], whisperModel: String, llmModel: String, language: Language) {
        self.version = version
        self.hotkeys = hotkeys
        self.activeMode = activeMode
        self.outputMode = outputMode
        self.history = history
        self.whisperModel = whisperModel
        self.llmModel = llmModel
        self.language = language
    }

    /// Handle missing language field from old configs
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        hotkeys = try container.decode(HotkeyConfigs.self, forKey: .hotkeys)
        activeMode = try container.decode(HotkeyMode.self, forKey: .activeMode)
        outputMode = try container.decode(OutputMode.self, forKey: .outputMode)
        history = try container.decode([HistoryItem].self, forKey: .history)
        whisperModel = try container.decode(String.self, forKey: .whisperModel)
        llmModel = try container.decode(String.self, forKey: .llmModel)
        language = try container.decodeIfPresent(Language.self, forKey: .language) ?? .english
    }
}
