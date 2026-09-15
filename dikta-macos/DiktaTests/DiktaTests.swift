/// DiktaTests — Unit tests for core logic.
///
/// Uses `@testable import Dikta` to test the real production types directly
/// (SPM can @testable-import an executable target; see MicMutingTests.swift
/// for another example). No hand-copied type mirrors here — if a production
/// type changes shape, these tests fail to compile or fail to pass, instead
/// of silently drifting from what ships.
///
/// Run via: cd dikta-macos && swift test

import XCTest
import CoreGraphics
@testable import Dikta

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
                       HotkeyConfig(modifiers: [.cmd, .ctrl], key: nil))
        // A missing "engine" key (every config saved before Apple Dictation
        // existed) must decode to Whisper, not fail to decode.
        XCTAssertEqual(config.engine, .whisper)
    }

    /// A config that explicitly persisted "appleDictation" (from a later
    /// engine switch) must round-trip back to that case, not silently reset.
    func test_decode_engine_appleDictation() throws {
        let json = """
        {
            "version": 3,
            "hotkeys": {"toggle": {"modifiers":["shift","ctrl"]},"push_to_talk":{"modifiers":["cmd","shift"]}},
            "output_mode": "general", "history": [], "whisper_model": "small", "llm_model": "gemma3",
            "engine": "appleDictation"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.engine, .appleDictation)
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

    /// The hand-copied AppConfig type this file used to define was missing `formatSelection`
    /// entirely (see docs/review-2026-09/mac-code-review.md). Decoding straight from the real
    /// production type closes that gap: this asserts `hotkeys.format_selection` round-trips.
    func test_decode_includesFormatSelectionHotkey() throws {
        let json = """
        {
            "version": 3,
            "hotkeys": {
                "toggle": {"modifiers": ["shift", "ctrl"]},
                "push_to_talk": {"modifiers": ["cmd", "shift"]},
                "format_selection": {"modifiers": ["cmd", "shift"], "key": "f"}
            },
            "output_mode": "general",
            "history": [],
            "whisper_model": "small",
            "llm_model": "gemma3"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.hotkeys.formatSelection,
                       HotkeyConfig(modifiers: [.cmd, .shift], key: "f"))
    }
}

// MARK: - UpdateChecker Version Comparison Tests

@MainActor
final class UpdateCheckerVersionTests: XCTestCase {

    func test_normalizeTag_stripsLowercaseV() {
        XCTAssertEqual(UpdateChecker.normalizeTag("v0.4.1"), "0.4.1")
    }

    func test_normalizeTag_stripsUppercaseV() {
        XCTAssertEqual(UpdateChecker.normalizeTag("V0.4.1"), "0.4.1")
    }

    func test_normalizeTag_noPrefix() {
        XCTAssertEqual(UpdateChecker.normalizeTag("0.4.1"), "0.4.1")
    }

    func test_isNewer_newerMinorVersion_returnsTrue() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.5.0", than: "0.4.0"))
    }

    func test_isNewer_newerPatchVersion_returnsTrue() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.4.2", than: "0.4.1"))
    }

    func test_isNewer_sameVersion_returnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.4.0", than: "0.4.0"))
    }

    func test_isNewer_olderVersion_returnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.3.0", than: "0.4.0"))
    }

    func test_isNewer_majorVersionBump_returnsTrue() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.0", than: "0.4.0"))
    }

    func test_isNewer_malformedRemote_returnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "not-a-version", than: "0.4.0"))
    }

    func test_isNewer_malformedLocal_returnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.4.1", than: "not-a-version"))
    }

    func test_isNewer_emptyRemote_returnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "", than: "0.4.0"))
    }

    func test_isNewer_emptyLocal_returnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.4.1", than: ""))
    }

    func test_isNewer_numericNotLexicographic() {
        // "0.10.0" > "0.9.0" numerically but "0.10.0" < "0.9.0" lexicographically
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.10.0", than: "0.9.0"))
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
