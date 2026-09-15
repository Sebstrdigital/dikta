import XCTest
import AVFoundation
@testable import Dikta

/// `AppleDictationEngine.bcp47(for:)` is a pure function (no Speech framework
/// calls), so it's exercised directly without any asset install or Speech
/// permission dependency. See spec §4 for the mapping table.
@available(macOS 26.0, *)
final class AppleDictationEngineLocaleMappingTests: XCTestCase {
    func test_bcp47_mapsEveryLanguage() {
        XCTAssertEqual(AppleDictationEngine.bcp47(for: .english), "en-US")
        XCTAssertEqual(AppleDictationEngine.bcp47(for: .swedish), "sv-SE")
        XCTAssertEqual(AppleDictationEngine.bcp47(for: .indonesian), "id-ID")
        XCTAssertEqual(AppleDictationEngine.bcp47(for: .spanish), "es-ES")
        XCTAssertEqual(AppleDictationEngine.bcp47(for: .french), "fr-FR")
        XCTAssertEqual(AppleDictationEngine.bcp47(for: .german), "de-DE")
        XCTAssertEqual(AppleDictationEngine.bcp47(for: .portuguese), "pt-BR")
        XCTAssertEqual(AppleDictationEngine.bcp47(for: .italian), "it-IT")
        XCTAssertEqual(AppleDictationEngine.bcp47(for: .dutch), "nl-NL")
        XCTAssertEqual(AppleDictationEngine.bcp47(for: .finnish), "fi-FI")
        XCTAssertEqual(AppleDictationEngine.bcp47(for: .norwegian), "nb-NO")
        XCTAssertEqual(AppleDictationEngine.bcp47(for: .danish), "da-DK")
    }

    /// Every `Language` case must have a mapping. `bcp47`'s switch is
    /// exhaustive (no `default:`), so a future `Language` case added without
    /// a corresponding mapping fails to *build*, not just to pass this test —
    /// this test exists to document that guarantee, not to establish it.
    func test_bcp47_coversAllLanguageCases() {
        for language in Language.allCases {
            _ = AppleDictationEngine.bcp47(for: language)
        }
    }
}

/// Real end-to-end smoke test against the actual Speech framework: installs
/// (if needed) Swedish dictation assets and transcribes a `say`-generated
/// sample. Skipped by default — it downloads/uses real on-device assets and
/// requires Speech permission — run explicitly with:
///
///   DIKTA_APPLE_SMOKE=1 swift test --filter AppleDictationSmokeTests
@available(macOS 26.0, *)
final class AppleDictationSmokeTests: XCTestCase {
    @MainActor
    func test_transcribe_swedishSample() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DIKTA_APPLE_SMOKE"] == "1",
            "Set DIKTA_APPLE_SMOKE=1 to run this (uses real Speech framework assets/permission)."
        )

        let sentence = "Jag testar Apple Dictation för Dikta idag."
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let wavURL = workDir.appendingPathComponent("sv.wav")

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Alva", "-o", wavURL.path, "--data-format=LEI16@16000", sentence]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "`say` failed to generate the sample wav")

        // Mirrors bench/probes/apple-streamprobe.swift's file -> [Float] extraction.
        let file = try AVAudioFile(forReading: wavURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return XCTFail("could not allocate read buffer")
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            return XCTFail("sample wav's processing format wasn't planar float32")
        }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))

        let configDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configService = ConfigService(configFile: configDir.appendingPathComponent("config.json"))
        defer { try? FileManager.default.removeItem(at: configDir) }
        configService.language = .swedish

        let engine = AppleDictationEngine(configService: configService)
        await engine.load()
        XCTAssertTrue(engine.isReady, "load() failed: \(engine.errorMessage ?? "unknown error")")

        let text = try await engine.transcribe(samples, language: Language.swedish.rawValue, micSensitivity: .normal)
        // Intentionally printed (not just asserted) so `swift test` output
        // captures the verbatim transcript for manual review.
        print("APPLE_DICTATION_SMOKE_RESULT: \(text)")
        XCTAssertFalse(text.isEmpty)
    }
}
