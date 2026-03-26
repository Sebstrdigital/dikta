import Foundation

/// Full application configuration (matches Python config format)
struct AppConfig: Codable {
    var version: Int
    var hotkeys: HotkeyConfigs
    var outputMode: OutputMode
    var history: [HistoryItem]
    var whisperModel: String
    var llmModel: String
    var language: Language
    var customPrompt: String
    var micSensitivity: MicSensitivity
    var muteSounds: Bool
    var muteNotifications: Bool
    var diagnosticLogging: Bool
    var enabledLanguages: [Language]

    struct HotkeyConfigs: Codable {
        var toggle: HotkeyConfig
        var pushToTalk: HotkeyConfig
        var textToSpeech: HotkeyConfig
        var languageToggle: HotkeyConfig

        enum CodingKeys: String, CodingKey {
            case toggle
            case pushToTalk = "push_to_talk"
            case textToSpeech = "text_to_speech"
            case languageToggle = "language_toggle"
        }

        init(toggle: HotkeyConfig, pushToTalk: HotkeyConfig, textToSpeech: HotkeyConfig = .defaultTextToSpeech, languageToggle: HotkeyConfig = .defaultLanguageToggle) {
            self.toggle = toggle
            self.pushToTalk = pushToTalk
            self.textToSpeech = textToSpeech
            self.languageToggle = languageToggle
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            toggle = try container.decode(HotkeyConfig.self, forKey: .toggle)
            pushToTalk = try container.decode(HotkeyConfig.self, forKey: .pushToTalk)
            textToSpeech = try container.decodeIfPresent(HotkeyConfig.self, forKey: .textToSpeech) ?? .defaultTextToSpeech
            languageToggle = try container.decodeIfPresent(HotkeyConfig.self, forKey: .languageToggle) ?? .defaultLanguageToggle
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case hotkeys
        case outputMode = "output_mode"
        case history
        case whisperModel = "whisper_model"
        case llmModel = "llm_model"
        case language
        case customPrompt = "custom_prompt"
        case micSensitivity = "mic_sensitivity"
        case muteSounds = "mute_sounds"
        case muteNotifications = "mute_notifications"
        case diagnosticLogging = "diagnostic_logging"
        case enabledLanguages = "enabled_languages"
    }

    static let defaultCustomPrompt = "Clean up this dictation. Fix grammar, punctuation, and remove filler words. Output only the cleaned text."

    /// Default configuration
    static let `default` = AppConfig(
        version: 3,
        hotkeys: HotkeyConfigs(
            toggle: .defaultToggle,
            pushToTalk: .defaultPushToTalk,
            textToSpeech: .defaultTextToSpeech
        ),
        outputMode: .general,
        history: [],
        whisperModel: "small",
        llmModel: "gemma3",
        language: .english,
        customPrompt: defaultCustomPrompt,
        micSensitivity: .normal,
        muteSounds: false,
        muteNotifications: false,
        diagnosticLogging: false,
        enabledLanguages: [.english, .swedish, .indonesian]
    )

    /// Maximum history items to keep
    static let historyLimit = 5

    /// Memberwise initializer
    init(version: Int, hotkeys: HotkeyConfigs, outputMode: OutputMode, history: [HistoryItem], whisperModel: String, llmModel: String, language: Language, customPrompt: String = defaultCustomPrompt, micSensitivity: MicSensitivity = .normal, muteSounds: Bool = false, muteNotifications: Bool = false, diagnosticLogging: Bool = false, enabledLanguages: [Language] = [.english, .swedish, .indonesian]) {
        self.version = version
        self.hotkeys = hotkeys
        self.outputMode = outputMode
        self.history = history
        self.whisperModel = whisperModel
        self.llmModel = llmModel
        self.language = language
        self.customPrompt = customPrompt
        self.micSensitivity = micSensitivity
        self.muteSounds = muteSounds
        self.muteNotifications = muteNotifications
        self.diagnosticLogging = diagnosticLogging
        self.enabledLanguages = enabledLanguages
    }

    /// Handle missing fields from old configs (v2 configs with active_mode are handled gracefully —
    /// unknown JSON keys are ignored by Codable since the CodingKey case was removed)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let savedVersion = try container.decode(Int.self, forKey: .version)
        // Migrate old configs to current version
        version = max(savedVersion, 3)
        hotkeys = try container.decode(HotkeyConfigs.self, forKey: .hotkeys)
        outputMode = try container.decode(OutputMode.self, forKey: .outputMode)
        history = try container.decode([HistoryItem].self, forKey: .history)
        let rawWhisperModel = try container.decode(String.self, forKey: .whisperModel)
        // Migrate removed base model to small
        if rawWhisperModel == "base" || rawWhisperModel == "base.en" {
            whisperModel = "small"
        } else {
            whisperModel = rawWhisperModel
        }
        llmModel = try container.decode(String.self, forKey: .llmModel)
        language = try container.decodeIfPresent(Language.self, forKey: .language) ?? .english
        customPrompt = try container.decodeIfPresent(String.self, forKey: .customPrompt) ?? Self.defaultCustomPrompt
        // Migrate old "mic_distance" values: "close" → "normal", "far" → "headset"
        if let raw = try container.decodeIfPresent(String.self, forKey: .micSensitivity) {
            switch raw {
            case "headset", "far": micSensitivity = .headset
            default: micSensitivity = .normal
            }
        } else {
            micSensitivity = .normal
        }
        muteSounds = try container.decodeIfPresent(Bool.self, forKey: .muteSounds) ?? false
        muteNotifications = try container.decodeIfPresent(Bool.self, forKey: .muteNotifications) ?? false
        diagnosticLogging = try container.decodeIfPresent(Bool.self, forKey: .diagnosticLogging) ?? false
        enabledLanguages = try container.decodeIfPresent([Language].self, forKey: .enabledLanguages) ?? [.english, .swedish, .indonesian]
    }
}
