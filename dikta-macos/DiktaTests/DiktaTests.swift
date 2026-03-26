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

enum Language: String, Codable {
    case english = "en", swedish = "sv", indonesian = "id"
    case spanish = "es", french = "fr", german = "de", portuguese = "pt"
    case italian = "it", dutch = "nl", finnish = "fi", norwegian = "no", danish = "da"
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
             muteNotifications = "mute_notifications"
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
