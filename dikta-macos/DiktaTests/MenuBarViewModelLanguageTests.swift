import XCTest
@testable import Dikta

/// Tests for `MenuBarViewModel`'s language switching (`setLanguage`,
/// `cycleLanguage`, `toggleLanguage`), which must `prepare` the active engine
/// for the new language before persisting it — otherwise switching languages
/// while Apple Dictation is active leaves `transcribe` throwing
/// `.assetsNotInstalled` until the app restarts (the bug these tests guard
/// against). Uses `FakeTranscriptionEngine` so no real WhisperKit/Speech call
/// is ever made.
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

    /// Polls until `condition` is true or `timeout` elapses. Needed only to wait
    /// out `MenuBarViewModel.init`'s own fire-and-forget startup `Task`, which has
    /// no completion handle exposed to tests; each switch's own work is awaited
    /// directly via the `Task` it returns.
    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    func test_setLanguage_success_preparesEngineAndPersists() async {
        let engine = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: engine, configService: configService)
        await waitUntil { viewModel.appState == .idle }

        guard let task = viewModel.setLanguage(.swedish) else {
            return XCTFail("expected setLanguage to start a switch")
        }
        await task.value

        XCTAssertEqual(configService.language, .swedish)
        XCTAssertEqual(engine.preparedLanguages, [.swedish])
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertTrue(configService.isLanguageEnabled(.swedish))
    }

    /// The bug this fixes: previously, language setters wrote `configService.language`
    /// directly with no engine involvement, so `AppleDictationEngine.transcribe`
    /// (which refuses to auto-download assets mid-dictation) would throw
    /// `.assetsNotInstalled` for the new language until the app restarted. Now a
    /// failed `prepare` must keep the *old* language active instead.
    func test_setLanguage_prepareFailure_keepsPreviousLanguage() async {
        let engine = FakeTranscriptionEngine()
        engine.languagesThatFailPrepare = [Language.swedish.rawValue]
        let viewModel = MenuBarViewModel(engine: engine, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        let previousLanguage = configService.language

        guard let task = viewModel.setLanguage(.swedish) else {
            return XCTFail("expected setLanguage to start a switch")
        }
        await task.value

        XCTAssertEqual(configService.language, previousLanguage)
        XCTAssertEqual(engine.preparedLanguages, [.swedish])
        XCTAssertEqual(viewModel.appState, .idle)
    }

    func test_cycleLanguage_preparesNextEnabledLanguage() async {
        let engine = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: engine, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        let expectedNext = configService.language.next(in: configService.enabledLanguages)

        guard let task = viewModel.cycleLanguage() else {
            return XCTFail("expected cycleLanguage to start a switch")
        }
        await task.value

        XCTAssertEqual(configService.language, expectedNext)
        XCTAssertEqual(engine.preparedLanguages, [expectedNext])
    }

    func test_toggleLanguage_disablingActiveLanguage_success_cyclesAndDisables() async {
        let engine = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: engine, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        let activeLanguage = configService.language
        XCTAssertGreaterThan(configService.enabledLanguages.count, 1, "test needs >1 enabled language to toggle one off")

        guard let task = viewModel.toggleLanguage(activeLanguage) else {
            return XCTFail("expected toggleLanguage to start a switch")
        }
        await task.value

        XCTAssertFalse(configService.isLanguageEnabled(activeLanguage))
        XCTAssertNotEqual(configService.language, activeLanguage)
        XCTAssertEqual(engine.preparedLanguages.count, 1)
    }

    /// If preparing the engine for the language being cycled *to* fails, the
    /// language being toggled off must stay both active and enabled — a
    /// failed engine prepare must never leave the carousel with no active
    /// language.
    func test_toggleLanguage_disablingActiveLanguage_prepareFailure_staysActiveAndEnabled() async {
        let engine = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: engine, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        let activeLanguage = configService.language
        let nextLanguage = configService.enabledLanguages.first { $0 != activeLanguage }!
        engine.languagesThatFailPrepare = [nextLanguage.rawValue]

        guard let task = viewModel.toggleLanguage(activeLanguage) else {
            return XCTFail("expected toggleLanguage to start a switch")
        }
        await task.value

        XCTAssertTrue(configService.isLanguageEnabled(activeLanguage))
        XCTAssertEqual(configService.language, activeLanguage)
    }

    func test_toggleLanguage_disablingInactiveLanguage_noEnginePrepare() async {
        let engine = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: engine, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        let activeLanguage = configService.language
        let inactiveEnabled = configService.enabledLanguages.first { $0 != activeLanguage }!

        XCTAssertNil(viewModel.toggleLanguage(inactiveEnabled))

        XCTAssertFalse(configService.isLanguageEnabled(inactiveEnabled))
        XCTAssertEqual(configService.language, activeLanguage)
        XCTAssertTrue(engine.preparedLanguages.isEmpty)
    }
}
