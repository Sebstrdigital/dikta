import XCTest
@testable import Dikta

/// Tests for `MenuBarViewModel.toggleLanguage`'s carousel bookkeeping: which
/// language stays active when one is disabled. Uses `FakeTranscriptionEngine`
/// so no real WhisperKit call is ever made.
///
/// Each test builds its own `ConfigService` pointed at a fresh temp file
/// (never `.shared`), so these tests never touch the developer's real,
/// persisted `~/Library/Application Support/Dikta/config.json`.
@MainActor
final class MenuBarViewModelLanguageTests: XCTestCase {
    private var configService: ConfigService!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        configService = ConfigService(configFile: tempDir.appendingPathComponent("config.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        configService = nil
        tempDir = nil
        super.tearDown()
    }

    func test_toggleLanguage_disablingActiveLanguage_cyclesToNextEnabled() {
        let engine = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: engine, configService: configService)
        let activeLanguage = configService.language
        XCTAssertGreaterThan(configService.enabledLanguages.count, 1, "test needs >1 enabled language to toggle one off")

        viewModel.toggleLanguage(activeLanguage)

        XCTAssertFalse(configService.isLanguageEnabled(activeLanguage))
        XCTAssertNotEqual(configService.language, activeLanguage)
    }

    func test_toggleLanguage_disablingInactiveLanguage_leavesActiveLanguageUnchanged() {
        let engine = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: engine, configService: configService)
        let activeLanguage = configService.language
        let inactiveEnabled = configService.enabledLanguages.first { $0 != activeLanguage }!

        viewModel.toggleLanguage(inactiveEnabled)

        XCTAssertFalse(configService.isLanguageEnabled(inactiveEnabled))
        XCTAssertEqual(configService.language, activeLanguage)
    }
}
