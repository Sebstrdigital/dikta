import XCTest
@testable import Dikta

/// Tests for `ConfigService.save()`'s atomic-write guarantee: `config.json` is
/// swapped in via a temp file + `FileManager.replaceItemAt` rename (see the
/// comment on `save()`), never partially overwritten in place.
///
/// Each test builds its own `ConfigService` pointed at a fresh temp file (never
/// `.shared`), so these tests never touch the developer's real, persisted
/// `~/Library/Application Support/Dikta/config.json`.
@MainActor
final class ConfigServiceAtomicWriteTests: XCTestCase {
    private var tempDir: URL!
    private var configFile: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        configFile = tempDir.appendingPathComponent("config.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        configFile = nil
        super.tearDown()
    }

    /// A save followed by loading a fresh `ConfigService` from the same file
    /// gets back the exact values that were saved.
    func test_save_thenReload_roundTripsValues() {
        let service = ConfigService(configFile: configFile)
        service.muteSounds = true
        service.whisperModel = "large-v3"
        service.customPrompt = "Round-trip prompt"

        let reloaded = ConfigService(configFile: configFile)
        XCTAssertEqual(reloaded.muteSounds, true)
        XCTAssertEqual(reloaded.whisperModel, "large-v3")
        XCTAssertEqual(reloaded.customPrompt, "Round-trip prompt")
    }

    /// An engine value written by a newer or removed build is inactive, but a
    /// routine settings/history save must preserve that exact raw JSON value
    /// along with legacy language data and unrelated user state.
    func test_unknownEngineSurvivesRoutineSettingsAndHistorySave() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var source = AppConfig.default
        source.language = .indonesian
        source.enabledLanguages = [.indonesian, .swedish]
        source.muteSounds = true
        source.customPrompt = "Keep this user prompt"
        source.history = [HistoryItem(text: "existing history", outputMode: .custom)]

        let encoded = try JSONEncoder().encode(source)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["engine"] = "future-ultra-successor"
        try JSONSerialization.data(withJSONObject: object).write(to: configFile)

        let service = ConfigService(configFile: configFile)
        XCTAssertEqual(service.engine, .whisper, "unknown values keep the legacy runtime fallback")
        service.muteNotifications = true
        service.addHistoryItem(text: "new history", mode: .general)

        let savedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: configFile)) as? [String: Any]
        )
        XCTAssertEqual(savedObject["engine"] as? String, "future-ultra-successor")

        let reloaded = ConfigService(configFile: configFile)
        XCTAssertEqual(reloaded.engine, .whisper)
        XCTAssertEqual(reloaded.language, .indonesian)
        XCTAssertEqual(reloaded.enabledLanguages, [.indonesian, .swedish])
        XCTAssertTrue(reloaded.muteSounds)
        XCTAssertTrue(reloaded.muteNotifications)
        XCTAssertEqual(reloaded.customPrompt, "Keep this user prompt")
        XCTAssertEqual(reloaded.history.map(\.text), ["new history", "existing history"])
        XCTAssertEqual(reloaded.history.map(\.outputMode), [.general, .custom])
    }

    /// A save that fails partway (here: the temp file can't be written) must
    /// leave the existing `config.json` exactly as it was — never truncated or
    /// empty — because the write lands on a sibling temp file first and only
    /// the atomic `replaceItemAt` rename ever touches `config.json` itself.
    func test_failedSave_leavesExistingConfigIntact() throws {
        let service = ConfigService(configFile: configFile)
        service.muteSounds = true // establishes a known-good config.json on disk

        let goodData = try Data(contentsOf: configFile)
        XCTAssertFalse(goodData.isEmpty)

        // Force the next save's temp-file write to fail by occupying its path
        // with a directory instead of a plain file.
        let tempFile = configFile.appendingPathExtension("tmp")
        try FileManager.default.createDirectory(at: tempFile, withIntermediateDirectories: true)

        service.muteSounds = false // triggers save(); the write to tempFile throws and is caught

        let dataAfterFailedSave = try Data(contentsOf: configFile)
        XCTAssertEqual(dataAfterFailedSave, goodData, "config.json must be untouched after a failed save")
        XCTAssertFalse(dataAfterFailedSave.isEmpty, "config.json must never be left empty after a failed save")

        // Reloading from disk must still see the last successfully saved value,
        // not the value the failed save attempted to write.
        let reloaded = ConfigService(configFile: configFile)
        XCTAssertEqual(reloaded.muteSounds, true)
    }
}
