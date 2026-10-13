import XCTest
@testable import Dikta

final class TextLanguageInferenceTests: XCTestCase {
    func test_infersEveryLanguageWithExistingEmbeddingEligibility() {
        let cases: [(String, Language)] = [
            ("This is a clear English paragraph with several ordinary words and a complete sentence about planning work tomorrow.", .english),
            ("Este es un párrafo claro en español con varias palabras comunes y una oración completa sobre el trabajo de mañana.", .spanish),
            ("Ceci est un paragraphe français clair avec plusieurs mots ordinaires et une phrase complète sur le travail de demain.", .french),
            ("Dies ist ein klarer deutscher Absatz mit mehreren gewöhnlichen Wörtern und einem vollständigen Satz über die morgige Arbeit.", .german),
            ("Este é um parágrafo claro em português com várias palavras comuns e uma frase completa sobre o trabalho de amanhã.", .portuguese),
            ("Questo è un chiaro paragrafo italiano con diverse parole comuni e una frase completa sul lavoro di domani.", .italian),
            ("Dit is een duidelijke Nederlandse alinea met verschillende gewone woorden en een volledige zin over het werk van morgen.", .dutch)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(TextLanguageInference.infer(from: text), expected)
        }
    }

    func test_infersSwedishForDebrief() {
        let text = "Det här är ett tydligt svenskt stycke med flera vanliga ord och en fullständig mening om morgondagens arbete."
        XCTAssertEqual(TextLanguageInference.infer(from: text), .swedish)
        XCTAssertEqual(TextLanguageInference.debriefCode(for: text), "sv")
    }

    func test_shortAndAmbiguousTextIsUncertain() {
        XCTAssertNil(TextLanguageInference.infer(from: "Hej där"))
        XCTAssertNil(TextLanguageInference.infer(from: "Plan Atlas meeting tomorrow"))
    }

    func test_mixedEnglishSwedishTextIsUncertainAndDebriefFallsBackToEnglish() {
        let text = "This meeting starts in English and we discuss the plan tomorrow. Det här mötet fortsätter på svenska och vi diskuterar planen i morgon."
        XCTAssertNil(TextLanguageInference.infer(from: text))
        XCTAssertEqual(TextLanguageInference.debriefCode(for: text), "en")
    }

    func test_unsupportedConfidentLanguageUsesConservativeFallback() {
        let text = "Ini adalah paragraf bahasa Indonesia yang jelas dengan beberapa kata umum tentang pekerjaan besok."
        XCTAssertNil(TextLanguageInference.infer(from: text))
        XCTAssertEqual(TextLanguageInference.debriefCode(for: text), "en")
    }
}

@MainActor
final class TestHostIsolationTests: XCTestCase {
    func test_sharedConfigAndRealSessionsAreSchemeIsolated() throws {
        let isolated = URL(fileURLWithPath: "/tmp/dikta-team-polish-validation", isDirectory: true)
        let config = isolated.appendingPathComponent("config/config.json")
        let sessions = isolated.appendingPathComponent("empty-real-sessions")
        XCTAssertEqual(ConfigService.shared.storageURLForTesting.standardizedFileURL, config)
        XCTAssertEqual(ProcessInfo.processInfo.environment["DIKTA_CONFIG_FILE"], config.path)
        XCTAssertEqual(ProcessInfo.processInfo.environment["DIKTA_REAL_SESSIONS_DIR"], sessions.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sessions.path), [])
    }
}

final class HotkeyModeAvailabilityTests: XCTestCase {
    func test_onlySurvivingModesAreConfigurableAndFormerFormatShortcutIsNotReserved() throws {
        let legacy = "\"language_toggle\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(HotkeyMode.self, from: legacy), .languageToggle)
        XCTAssertEqual(Set(HotkeyMode.userConfigurableCases), [.toggle, .pushToTalk, .textToSpeech])
        XCTAssertFalse(HotkeyMode.userConfigurableCases.contains(.languageToggle))
        XCTAssertFalse(HotkeyMode.userConfigurableCases.map(\.rawValue).contains("format_selection"))
    }
}
