/// DiktaTests — Unit tests for core logic.
///
/// These tests are self-contained: they replicate just enough type definitions
/// to test the pure algorithms, since the main Dikta target is an executable
/// (not a library) and cannot be @testable-imported via Swift Package Manager.
/// The test logic mirrors exactly what is in the production code; if you change
/// a production algorithm, update the corresponding test type here too.
///
/// Run via: cd dikta-macos && swift test

import XCTest
import CoreGraphics

// MARK: - Inlined production types (mirrors production code)

enum ModifierKey: String, Codable, CaseIterable {
    case shift, ctrl, cmd, alt, fn

    var cgEventFlag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .ctrl:  return .maskControl
        case .cmd:   return .maskCommand
        case .alt:   return .maskAlternate
        case .fn:    return .maskSecondaryFn
        }
    }
}

struct HotkeyConfig: Codable, Equatable {
    var modifiers: [ModifierKey]
    var key: String?

    /// Strict modifier matching: all required modifiers must be pressed, no extras allowed.
    func matchesModifiers(_ flags: CGEventFlags) -> Bool {
        for modifier in ModifierKey.allCases {
            let isRequired = modifiers.contains(modifier)
            let isPressed  = flags.contains(modifier.cgEventFlag)
            if isRequired != isPressed { return false }
        }
        return true
    }
}

enum Language: String, Codable, CaseIterable {
    case english = "en", swedish = "sv", indonesian = "id"
    case spanish = "es", french = "fr", german = "de", portuguese = "pt"
    case italian = "it", dutch = "nl", finnish = "fi", norwegian = "no", danish = "da"

    var displayName: String {
        switch self {
        case .english:    return "English"
        case .swedish:    return "Svenska"
        case .indonesian: return "Bahasa Indonesia"
        case .spanish:    return "Español"
        case .french:     return "Français"
        case .german:     return "Deutsch"
        case .portuguese: return "Português"
        case .italian:    return "Italiano"
        case .dutch:      return "Nederlands"
        case .finnish:    return "Suomi"
        case .norwegian:  return "Norsk"
        case .danish:     return "Dansk"
        }
    }

    var whisperCode: String { rawValue }

    func next(in enabledLanguages: [Language]) -> Language {
        guard !enabledLanguages.isEmpty else { return self }
        guard let currentIndex = enabledLanguages.firstIndex(of: self) else {
            return enabledLanguages[0]
        }
        return enabledLanguages[(currentIndex + 1) % enabledLanguages.count]
    }
}
enum MicSensitivity: String, Codable { case normal, headset }
enum OutputMode: String, Codable {
    case raw, general, custom
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "code_prompt": self = .custom
        default: self = OutputMode(rawValue: raw) ?? .general
        }
    }
}

struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let text: String
    let outputMode: OutputMode
}

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

        static let defaultTextToSpeech  = HotkeyConfig(modifiers: [.cmd, .alt], key: nil)
        static let defaultLanguageToggle = HotkeyConfig(modifiers: [.cmd, .ctrl], key: nil)

        enum CodingKeys: String, CodingKey {
            case toggle, pushToTalk = "push_to_talk",
                 textToSpeech = "text_to_speech", languageToggle = "language_toggle"
        }
        init(toggle: HotkeyConfig, pushToTalk: HotkeyConfig,
             textToSpeech: HotkeyConfig = .init(modifiers: [.cmd, .alt], key: nil),
             languageToggle: HotkeyConfig = .init(modifiers: [.cmd, .ctrl], key: nil)) {
            self.toggle = toggle; self.pushToTalk = pushToTalk
            self.textToSpeech = textToSpeech; self.languageToggle = languageToggle
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            toggle       = try c.decode(HotkeyConfig.self, forKey: .toggle)
            pushToTalk   = try c.decode(HotkeyConfig.self, forKey: .pushToTalk)
            textToSpeech = try c.decodeIfPresent(HotkeyConfig.self, forKey: .textToSpeech)
                           ?? Self.defaultTextToSpeech
            languageToggle = try c.decodeIfPresent(HotkeyConfig.self, forKey: .languageToggle)
                             ?? Self.defaultLanguageToggle
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, hotkeys, outputMode = "output_mode", history,
             whisperModel = "whisper_model", llmModel = "llm_model",
             language, customPrompt = "custom_prompt",
             micSensitivity = "mic_sensitivity", muteSounds = "mute_sounds",
             muteNotifications = "mute_notifications",
             diagnosticLogging = "diagnostic_logging",
             enabledLanguages = "enabled_languages"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try c.decode(Int.self, forKey: .version)
        version = max(saved, 3)
        hotkeys = try c.decode(HotkeyConfigs.self, forKey: .hotkeys)
        outputMode = try c.decode(OutputMode.self, forKey: .outputMode)
        history = try c.decode([HistoryItem].self, forKey: .history)
        let raw = try c.decode(String.self, forKey: .whisperModel)
        whisperModel = (raw == "base" || raw == "base.en") ? "small" : raw
        llmModel = try c.decode(String.self, forKey: .llmModel)
        language = try c.decodeIfPresent(Language.self, forKey: .language) ?? .english
        customPrompt = try c.decodeIfPresent(String.self, forKey: .customPrompt) ?? ""
        if let raw = try c.decodeIfPresent(String.self, forKey: .micSensitivity) {
            switch raw {
            case "headset", "far": micSensitivity = .headset
            default: micSensitivity = .normal
            }
        } else {
            micSensitivity = .normal
        }
        muteSounds = try c.decodeIfPresent(Bool.self, forKey: .muteSounds) ?? false
        muteNotifications = try c.decodeIfPresent(Bool.self, forKey: .muteNotifications) ?? false
        diagnosticLogging = try c.decodeIfPresent(Bool.self, forKey: .diagnosticLogging) ?? false
        enabledLanguages = try c.decodeIfPresent([Language].self, forKey: .enabledLanguages) ?? [.english, .swedish, .indonesian]
    }
}

// UpdateChecker version logic (mirrors production UpdateChecker.isNewer / normalizeTag)
enum VersionChecker {
    static func normalizeTag(_ tag: String) -> String {
        tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }
    static func isNewer(remote: String, than local: String) -> Bool {
        let validPattern = #"^\d+(\.\d+)*$"#
        guard remote.range(of: validPattern, options: .regularExpression) != nil,
              local.range(of: validPattern, options: .regularExpression) != nil else { return false }
        return remote.compare(local, options: .numeric) == .orderedDescending
    }
}

// MARK: - HotkeyConfig.matchesModifiers Tests

final class HotkeyConfigMatchesModifiersTests: XCTestCase {

    func test_exactMatch_shiftCtrl() {
        let config = HotkeyConfig(modifiers: [.shift, .ctrl], key: nil)
        var flags = CGEventFlags()
        flags.insert(.maskShift)
        flags.insert(.maskControl)
        XCTAssertTrue(config.matchesModifiers(flags))
    }

    func test_exactMatch_cmdShift() {
        let config = HotkeyConfig(modifiers: [.cmd, .shift], key: nil)
        var flags = CGEventFlags()
        flags.insert(.maskCommand)
        flags.insert(.maskShift)
        XCTAssertTrue(config.matchesModifiers(flags))
    }

    func test_exactMatch_singleModifier() {
        let config = HotkeyConfig(modifiers: [.alt], key: nil)
        var flags = CGEventFlags()
        flags.insert(.maskAlternate)
        XCTAssertTrue(config.matchesModifiers(flags))
    }

    func test_partialMatch_missingRequired() {
        let config = HotkeyConfig(modifiers: [.shift, .ctrl], key: nil)
        var flags = CGEventFlags()
        flags.insert(.maskShift)
        // Ctrl not pressed — should fail strict match
        XCTAssertFalse(config.matchesModifiers(flags))
    }

    func test_partialMatch_extraModifier() {
        let config = HotkeyConfig(modifiers: [.shift], key: nil)
        var flags = CGEventFlags()
        flags.insert(.maskShift)
        flags.insert(.maskCommand)  // extra, not in config
        XCTAssertFalse(config.matchesModifiers(flags))
    }

    func test_partialMatch_subsetPressed() {
        let config = HotkeyConfig(modifiers: [.cmd, .shift, .alt], key: nil)
        var flags = CGEventFlags()
        flags.insert(.maskCommand)
        flags.insert(.maskShift)
        // Alt missing
        XCTAssertFalse(config.matchesModifiers(flags))
    }

    func test_noMatch_wrongModifiers() {
        let config = HotkeyConfig(modifiers: [.shift, .ctrl], key: nil)
        var flags = CGEventFlags()
        flags.insert(.maskCommand)
        flags.insert(.maskAlternate)
        XCTAssertFalse(config.matchesModifiers(flags))
    }

    func test_emptyConfig_noModifiersPressed_matches() {
        let config = HotkeyConfig(modifiers: [], key: nil)
        XCTAssertTrue(config.matchesModifiers(CGEventFlags()))
    }

    func test_emptyConfig_withModifiersPressed_noMatch() {
        let config = HotkeyConfig(modifiers: [], key: nil)
        var flags = CGEventFlags()
        flags.insert(.maskShift)
        XCTAssertFalse(config.matchesModifiers(flags))
    }
}

// MARK: - AppConfig Backward-Compatible Decoding Tests

final class AppConfigDecodingTests: XCTestCase {

    func test_decode_fullCurrentConfig() throws {
        let json = """
        {
            "version": 3,
            "hotkeys": {
                "toggle": {"modifiers": ["shift", "ctrl"]},
                "push_to_talk": {"modifiers": ["cmd", "shift"]},
                "text_to_speech": {"modifiers": ["cmd", "alt"]},
                "language_toggle": {"modifiers": ["cmd", "ctrl"]}
            },
            "output_mode": "general",
            "history": [],
            "whisper_model": "small",
            "llm_model": "gemma3",
            "language": "en",
            "custom_prompt": "Test prompt",
            "mic_sensitivity": "normal",
            "mute_sounds": false,
            "mute_notifications": false
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.version, 3)
        XCTAssertEqual(config.whisperModel, "small")
        XCTAssertEqual(config.language, .english)
        XCTAssertEqual(config.micSensitivity, .normal)
    }

    func test_decode_missingOptionalFields_usesDefaults() throws {
        let json = """
        {
            "version": 2,
            "hotkeys": {
                "toggle": {"modifiers": ["shift", "ctrl"]},
                "push_to_talk": {"modifiers": ["cmd", "shift"]}
            },
            "output_mode": "general",
            "history": [],
            "whisper_model": "small",
            "llm_model": "gemma3"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.language, .english)
        XCTAssertEqual(config.micSensitivity, .normal)
        XCTAssertFalse(config.muteSounds)
        XCTAssertFalse(config.muteNotifications)
        XCTAssertGreaterThanOrEqual(config.version, 3)
        XCTAssertEqual(config.hotkeys.languageToggle,
                       HotkeyConfig.init(modifiers: [.cmd, .ctrl], key: nil))
    }

    func test_decode_migratesBaseWhisperModel() throws {
        let json = """
        {
            "version": 2,
            "hotkeys": {"toggle": {"modifiers":["shift","ctrl"]},"push_to_talk":{"modifiers":["cmd","shift"]}},
            "output_mode": "general", "history": [], "whisper_model": "base", "llm_model": "gemma3"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.whisperModel, "small")
    }

    func test_decode_migratesBaseEnWhisperModel() throws {
        let json = """
        {
            "version": 2,
            "hotkeys": {"toggle": {"modifiers":["shift","ctrl"]},"push_to_talk":{"modifiers":["cmd","shift"]}},
            "output_mode": "general", "history": [], "whisper_model": "base.en", "llm_model": "gemma3"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.whisperModel, "small")
    }

    func test_decode_backwardCompatOutputMode_codePrompt() throws {
        let json = """
        {
            "version": 3,
            "hotkeys": {"toggle": {"modifiers":["shift","ctrl"]},"push_to_talk":{"modifiers":["cmd","shift"]}},
            "output_mode": "code_prompt", "history": [], "whisper_model": "small", "llm_model": "gemma3"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.outputMode, .custom)
    }
}

// MARK: - UpdateChecker Version Comparison Tests

final class UpdateCheckerVersionTests: XCTestCase {

    func test_normalizeTag_stripsLowercaseV() {
        XCTAssertEqual(VersionChecker.normalizeTag("v0.4.1"), "0.4.1")
    }

    func test_normalizeTag_stripsUppercaseV() {
        XCTAssertEqual(VersionChecker.normalizeTag("V0.4.1"), "0.4.1")
    }

    func test_normalizeTag_noPrefix() {
        XCTAssertEqual(VersionChecker.normalizeTag("0.4.1"), "0.4.1")
    }

    func test_isNewer_newerMinorVersion_returnsTrue() {
        XCTAssertTrue(VersionChecker.isNewer(remote: "0.5.0", than: "0.4.0"))
    }

    func test_isNewer_newerPatchVersion_returnsTrue() {
        XCTAssertTrue(VersionChecker.isNewer(remote: "0.4.2", than: "0.4.1"))
    }

    func test_isNewer_sameVersion_returnsFalse() {
        XCTAssertFalse(VersionChecker.isNewer(remote: "0.4.0", than: "0.4.0"))
    }

    func test_isNewer_olderVersion_returnsFalse() {
        XCTAssertFalse(VersionChecker.isNewer(remote: "0.3.0", than: "0.4.0"))
    }

    func test_isNewer_majorVersionBump_returnsTrue() {
        XCTAssertTrue(VersionChecker.isNewer(remote: "1.0.0", than: "0.4.0"))
    }

    func test_isNewer_malformedRemote_returnsFalse() {
        XCTAssertFalse(VersionChecker.isNewer(remote: "not-a-version", than: "0.4.0"))
    }

    func test_isNewer_malformedLocal_returnsFalse() {
        XCTAssertFalse(VersionChecker.isNewer(remote: "0.4.1", than: "not-a-version"))
    }

    func test_isNewer_emptyRemote_returnsFalse() {
        XCTAssertFalse(VersionChecker.isNewer(remote: "", than: "0.4.0"))
    }

    func test_isNewer_emptyLocal_returnsFalse() {
        XCTAssertFalse(VersionChecker.isNewer(remote: "0.4.1", than: ""))
    }

    func test_isNewer_numericNotLexicographic() {
        // "0.10.0" > "0.9.0" numerically but "0.10.0" < "0.9.0" lexicographically
        XCTAssertTrue(VersionChecker.isNewer(remote: "0.10.0", than: "0.9.0"))
    }
}

// MARK: - Language whisperCode and displayName Tests

final class LanguageMetadataTests: XCTestCase {

    func test_allCases_count_is12() {
        XCTAssertEqual(Language.allCases.count, 12)
    }

    func test_whisperCode_english() {
        XCTAssertEqual(Language.english.whisperCode, "en")
    }

    func test_whisperCode_swedish() {
        XCTAssertEqual(Language.swedish.whisperCode, "sv")
    }

    func test_whisperCode_indonesian() {
        XCTAssertEqual(Language.indonesian.whisperCode, "id")
    }

    func test_whisperCode_spanish() {
        XCTAssertEqual(Language.spanish.whisperCode, "es")
    }

    func test_whisperCode_french() {
        XCTAssertEqual(Language.french.whisperCode, "fr")
    }

    func test_whisperCode_german() {
        XCTAssertEqual(Language.german.whisperCode, "de")
    }

    func test_whisperCode_portuguese() {
        XCTAssertEqual(Language.portuguese.whisperCode, "pt")
    }

    func test_whisperCode_italian() {
        XCTAssertEqual(Language.italian.whisperCode, "it")
    }

    func test_whisperCode_dutch() {
        XCTAssertEqual(Language.dutch.whisperCode, "nl")
    }

    func test_whisperCode_finnish() {
        XCTAssertEqual(Language.finnish.whisperCode, "fi")
    }

    func test_whisperCode_norwegian() {
        XCTAssertEqual(Language.norwegian.whisperCode, "no")
    }

    func test_whisperCode_danish() {
        XCTAssertEqual(Language.danish.whisperCode, "da")
    }

    func test_displayName_english() {
        XCTAssertEqual(Language.english.displayName, "English")
    }

    func test_displayName_swedish() {
        XCTAssertEqual(Language.swedish.displayName, "Svenska")
    }

    func test_displayName_indonesian() {
        XCTAssertEqual(Language.indonesian.displayName, "Bahasa Indonesia")
    }

    func test_displayName_spanish() {
        XCTAssertEqual(Language.spanish.displayName, "Español")
    }

    func test_displayName_french() {
        XCTAssertEqual(Language.french.displayName, "Français")
    }

    func test_displayName_german() {
        XCTAssertEqual(Language.german.displayName, "Deutsch")
    }

    func test_displayName_portuguese() {
        XCTAssertEqual(Language.portuguese.displayName, "Português")
    }

    func test_displayName_italian() {
        XCTAssertEqual(Language.italian.displayName, "Italiano")
    }

    func test_displayName_dutch() {
        XCTAssertEqual(Language.dutch.displayName, "Nederlands")
    }

    func test_displayName_finnish() {
        XCTAssertEqual(Language.finnish.displayName, "Suomi")
    }

    func test_displayName_norwegian() {
        XCTAssertEqual(Language.norwegian.displayName, "Norsk")
    }

    func test_displayName_danish() {
        XCTAssertEqual(Language.danish.displayName, "Dansk")
    }

    func test_allCases_haveNonEmptyWhisperCodes() {
        for lang in Language.allCases {
            XCTAssertFalse(lang.whisperCode.isEmpty, "\(lang) has empty whisperCode")
        }
    }

    func test_allCases_haveNonEmptyDisplayNames() {
        for lang in Language.allCases {
            XCTAssertFalse(lang.displayName.isEmpty, "\(lang) has empty displayName")
        }
    }
}

// MARK: - Language Carousel (next in enabledLanguages) Tests

final class LanguageCarouselTests: XCTestCase {

    func test_next_cyclesForwardInEnabledSubset() {
        let enabled: [Language] = [.english, .swedish, .french]
        XCTAssertEqual(Language.english.next(in: enabled), .swedish)
        XCTAssertEqual(Language.swedish.next(in: enabled), .french)
    }

    func test_next_wrapsAroundAtEnd() {
        let enabled: [Language] = [.english, .swedish, .french]
        XCTAssertEqual(Language.french.next(in: enabled), .english)
    }

    func test_next_skipsDisabledLanguages() {
        // german is not in enabled — skipped by construction of the enabled list
        let enabled: [Language] = [.english, .french, .spanish]
        XCTAssertEqual(Language.english.next(in: enabled), .french)
        XCTAssertEqual(Language.french.next(in: enabled), .spanish)
        XCTAssertEqual(Language.spanish.next(in: enabled), .english)
    }

    func test_next_currentNotInEnabled_returnsFirstEnabled() {
        let enabled: [Language] = [.french, .german]
        // english is not in the enabled set
        XCTAssertEqual(Language.english.next(in: enabled), .french)
    }

    func test_next_emptyEnabled_returnsSelf() {
        XCTAssertEqual(Language.english.next(in: []), .english)
        XCTAssertEqual(Language.swedish.next(in: []), .swedish)
    }

    func test_next_singleEnabled_alwaysReturnsThatLanguage() {
        let enabled: [Language] = [.norwegian]
        XCTAssertEqual(Language.norwegian.next(in: enabled), .norwegian)
    }

    func test_next_singleEnabled_currentNotInSet_returnsOnlyEnabled() {
        let enabled: [Language] = [.norwegian]
        XCTAssertEqual(Language.english.next(in: enabled), .norwegian)
    }

    func test_next_fullCycleReturnsToStart() {
        let enabled: [Language] = [.english, .swedish, .indonesian, .spanish]
        var lang = Language.english
        for _ in 0..<4 {
            lang = lang.next(in: enabled)
        }
        // After 4 steps in a 4-element cycle, should be back at english
        XCTAssertEqual(lang, .english)
    }

    func test_next_allLanguagesEnabled_cyclesAll12() {
        let enabled = Language.allCases
        var lang = enabled[0]
        for i in 1..<enabled.count {
            lang = lang.next(in: enabled)
            XCTAssertEqual(lang, enabled[i])
        }
        // One more step wraps to start
        lang = lang.next(in: enabled)
        XCTAssertEqual(lang, enabled[0])
    }
}

// MARK: - AppConfig enabledLanguages Backward-Compatible Decoding Tests

final class AppConfigEnabledLanguagesDecodingTests: XCTestCase {

    private let minimalJSON = """
    {
        "version": 3,
        "hotkeys": {
            "toggle": {"modifiers": ["shift", "ctrl"]},
            "push_to_talk": {"modifiers": ["cmd", "shift"]}
        },
        "output_mode": "general",
        "history": [],
        "whisper_model": "small",
        "llm_model": "gemma3"
    }
    """.data(using: .utf8)!

    func test_decode_missingEnabledLanguages_usesDefault() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: minimalJSON)
        XCTAssertEqual(config.enabledLanguages, [.english, .swedish, .indonesian])
    }

    func test_decode_withEnabledLanguages_usesProvided() throws {
        let json = """
        {
            "version": 3,
            "hotkeys": {
                "toggle": {"modifiers": ["shift", "ctrl"]},
                "push_to_talk": {"modifiers": ["cmd", "shift"]}
            },
            "output_mode": "general",
            "history": [],
            "whisper_model": "small",
            "llm_model": "gemma3",
            "enabled_languages": ["en", "de", "fr", "es"]
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.enabledLanguages, [.english, .german, .french, .spanish])
    }

    func test_decode_emptyEnabledLanguages_storesEmpty() throws {
        let json = """
        {
            "version": 3,
            "hotkeys": {
                "toggle": {"modifiers": ["shift", "ctrl"]},
                "push_to_talk": {"modifiers": ["cmd", "shift"]}
            },
            "output_mode": "general",
            "history": [],
            "whisper_model": "small",
            "llm_model": "gemma3",
            "enabled_languages": []
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.enabledLanguages, [])
    }

    func test_decode_allLanguagesEnabled_decodes12() throws {
        let codes = Language.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        let json = """
        {
            "version": 3,
            "hotkeys": {
                "toggle": {"modifiers": ["shift", "ctrl"]},
                "push_to_talk": {"modifiers": ["cmd", "shift"]}
            },
            "output_mode": "general",
            "history": [],
            "whisper_model": "small",
            "llm_model": "gemma3",
            "enabled_languages": [\(codes)]
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.enabledLanguages.count, 12)
    }

    func test_decode_missingDiagnosticLogging_defaultsFalse() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: minimalJSON)
        XCTAssertFalse(config.diagnosticLogging)
    }
}
