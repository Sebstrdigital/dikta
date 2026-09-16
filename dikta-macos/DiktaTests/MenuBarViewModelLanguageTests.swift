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

    // MARK: - Startup: effective model for the configured language

    /// Polls until `condition` is true or `timeout` elapses. Waits out
    /// `MenuBarViewModel.init`'s fire-and-forget startup `Task` and the
    /// fire-and-forget reload `Task`s started by language changes, neither of
    /// which expose a completion handle to tests.
    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    /// A plain injected `engine:` never proves anything about *which* model
    /// startup chose — `FakeTranscriptionEngine.load()` ignores whatever
    /// model it's nominally "for", so asserting `viewModel.loadedModel` alone
    /// would just be re-checking a value `init` assigned directly. Using
    /// `engineFactory:` instead lets the test observe the actual model
    /// `init` computed and would hand to `Transcriber(model:)` in production.
    func test_startup_swedishActiveLanguage_loadsKbWhisperSmall() async {
        let fake = FakeTranscriptionEngine()
        configService.language = .swedish
        var constructedWithModel: WhisperModel?
        let viewModel = MenuBarViewModel(
            engineFactory: { model in
                constructedWithModel = model
                return fake
            },
            configService: configService
        )

        await waitUntil { viewModel.appState == .idle }

        XCTAssertEqual(constructedWithModel, .kbWhisperSmall, "the engine must be constructed with the effective model for Svenska")
        XCTAssertEqual(viewModel.loadedModel, .kbWhisperSmall)
        // The startup model comes from construction (Transcriber(model:) for
        // the real engine); no reload is needed to reach it.
        XCTAssertTrue(fake.reloadedModels.isEmpty)
    }

    func test_startup_englishActiveLanguage_loadsPreference() async {
        let fake = FakeTranscriptionEngine()
        configService.whisperModel = WhisperModel.turbo.rawValue
        configService.language = .english
        var constructedWithModel: WhisperModel?
        let viewModel = MenuBarViewModel(
            engineFactory: { model in
                constructedWithModel = model
                return fake
            },
            configService: configService
        )

        await waitUntil { viewModel.appState == .idle }

        XCTAssertEqual(constructedWithModel, .turbo, "the engine must be constructed with the user's preference for English")
        XCTAssertEqual(viewModel.loadedModel, .turbo)
        XCTAssertTrue(fake.reloadedModels.isEmpty)
    }

    // MARK: - Language change reloads the effective model

    func test_setLanguage_englishToSwedish_reloadsToKbWhisperSmall() async {
        let fake = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        XCTAssertEqual(viewModel.loadedModel, .small, "default preference is small")

        viewModel.setLanguage(.swedish)
        await waitUntil { viewModel.appState == .idle }

        XCTAssertEqual(viewModel.loadedModel, .kbWhisperSmall)
        XCTAssertEqual(fake.reloadedModels, [.kbWhisperSmall])
        // The preference itself must be untouched by a language-driven reload.
        XCTAssertEqual(configService.whisperModel, WhisperModel.small.rawValue)
    }

    func test_setLanguage_swedishToEnglish_reloadsToPreference() async {
        let fake = FakeTranscriptionEngine()
        configService.whisperModel = WhisperModel.turbo.rawValue
        configService.language = .swedish
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        XCTAssertEqual(viewModel.loadedModel, .kbWhisperSmall)

        viewModel.setLanguage(.english)
        await waitUntil { viewModel.appState == .idle }

        XCTAssertEqual(viewModel.loadedModel, .turbo)
        XCTAssertEqual(fake.reloadedModels, [.turbo])
        XCTAssertEqual(configService.whisperModel, WhisperModel.turbo.rawValue)
    }

    func test_setLanguage_swedishReselected_doesNotReload() async {
        let fake = FakeTranscriptionEngine()
        configService.language = .swedish
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        XCTAssertEqual(viewModel.loadedModel, .kbWhisperSmall)

        viewModel.setLanguage(.swedish)
        try? await Task.sleep(nanoseconds: 300_000_000) // give any spurious reload a chance to start

        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertTrue(fake.reloadedModels.isEmpty, "re-selecting the same language must not reload")
    }

    /// If KB-Whisper fails to load when switching to Svenska (no network, disk
    /// guard), the app must fall back to the previously loaded model and must
    /// not retry automatically — only an explicit next language change tries
    /// again.
    func test_setLanguage_englishToSwedish_kbWhisperSmallFailure_fallsBackToPreviousModel() async {
        let fake = FakeTranscriptionEngine()
        fake.modelsThatFail = [WhisperModel.kbWhisperSmall.rawValue]
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        XCTAssertEqual(viewModel.loadedModel, .small)

        viewModel.setLanguage(.swedish)
        await waitUntil { viewModel.appState == .idle }

        XCTAssertEqual(viewModel.loadedModel, .small, "must fall back to the previously loaded model")
        XCTAssertEqual(fake.reloadedModels, [.kbWhisperSmall, .small])
        // Preference is never touched by the language-driven path, success or failure.
        XCTAssertEqual(configService.whisperModel, WhisperModel.small.rawValue)

        // No retry loop: waiting longer must not produce another attempt.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fake.reloadedModels, [.kbWhisperSmall, .small])
    }

    // MARK: - Deferred reload while recording/processing

    /// A language change during `.recording` must apply the language
    /// immediately (matching existing, pre-KB-Whisper behaviour — language
    /// changes were never blocked on `appState`) but must NOT touch the
    /// engine while it's in use; the reload runs only once `appState`
    /// returns to `.idle` on its own (e.g. when recording finishes).
    func test_setLanguage_duringRecording_defersReloadUntilIdle() async {
        let fake = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }

        viewModel.appState = .recording
        viewModel.setLanguage(.swedish)

        // Language applies immediately; the engine must not be touched yet.
        XCTAssertEqual(configService.language, .swedish)
        XCTAssertEqual(viewModel.loadedModel, .small, "must not reload while recording")
        XCTAssertTrue(fake.reloadedModels.isEmpty, "must not reload while recording")

        viewModel.appState = .idle
        await waitUntil { !fake.reloadedModels.isEmpty }

        XCTAssertEqual(fake.reloadedModels, [.kbWhisperSmall])
        XCTAssertEqual(viewModel.loadedModel, .kbWhisperSmall)
    }

    /// Same as above, but for `.processing` — the other state a live
    /// recording session passes through before returning to `.idle`.
    func test_setLanguage_duringProcessing_defersReloadUntilIdle() async {
        let fake = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }

        viewModel.appState = .processing
        viewModel.setLanguage(.swedish)

        XCTAssertEqual(configService.language, .swedish)
        XCTAssertTrue(fake.reloadedModels.isEmpty, "must not reload while processing")

        viewModel.appState = .idle
        await waitUntil { !fake.reloadedModels.isEmpty }

        XCTAssertEqual(fake.reloadedModels, [.kbWhisperSmall])
        XCTAssertEqual(viewModel.loadedModel, .kbWhisperSmall)
    }

    /// If the language is switched back before the app returns to idle, the
    /// deferred reload must be re-evaluated against the CURRENT language, not
    /// blindly fire for whatever language triggered the deferral — since the
    /// effective model once again matches what's loaded, no reload should
    /// happen at all.
    func test_setLanguage_switchedBackBeforeIdle_noReloadOnIdle() async {
        let fake = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }

        viewModel.appState = .recording
        viewModel.setLanguage(.swedish) // deferred: would need kbWhisperSmall
        viewModel.setLanguage(.english) // deferred: back to the already-loaded preference

        viewModel.appState = .idle
        // Give any (incorrect) reload a chance to start.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(configService.language, .english)
        XCTAssertEqual(viewModel.loadedModel, .small)
        XCTAssertTrue(fake.reloadedModels.isEmpty, "effective model already matches what's loaded — no reload needed")
    }

    // MARK: - toggleLanguage / cycleLanguage also reload the effective model

    /// `toggleLanguage` disabling the active language cycles to the next
    /// enabled one — if that's Svenska, the same reload-to-kb machinery used
    /// by `setLanguage` must run.
    func test_toggleLanguage_disablingActiveLanguage_cyclingToSwedish_reloadsToKbWhisperSmall() async {
        let fake = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        // Default enabled languages: [english, swedish, indonesian]; default active: english.
        XCTAssertEqual(configService.language, .english)

        viewModel.toggleLanguage(.english)
        await waitUntil { viewModel.appState == .idle }

        XCTAssertEqual(configService.language, .swedish, "test assumes swedish is next after english")
        XCTAssertEqual(fake.reloadedModels, [.kbWhisperSmall])
        XCTAssertEqual(viewModel.loadedModel, .kbWhisperSmall)
    }

    /// The reverse: disabling Svenska while it's active cycles away from it,
    /// and the engine reloads back to the preference.
    func test_toggleLanguage_disablingActiveSwedish_cyclingAway_reloadsToPreference() async {
        let fake = FakeTranscriptionEngine()
        configService.whisperModel = WhisperModel.turbo.rawValue
        configService.language = .swedish
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        XCTAssertEqual(viewModel.loadedModel, .kbWhisperSmall)

        viewModel.toggleLanguage(.swedish)
        await waitUntil { viewModel.appState == .idle }

        XCTAssertNotEqual(configService.language, .swedish)
        XCTAssertEqual(fake.reloadedModels, [.turbo])
        XCTAssertEqual(viewModel.loadedModel, .turbo)
    }

    /// `cycleLanguage` (the language hotkey) goes through `setLanguage` too —
    /// confirm the reload fires for it specifically, not just for direct
    /// `setLanguage` calls.
    func test_cycleLanguage_englishToSwedish_reloadsToKbWhisperSmall() async {
        let fake = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        XCTAssertEqual(configService.language, .english)

        viewModel.cycleLanguage()
        await waitUntil { viewModel.appState == .idle }

        XCTAssertEqual(configService.language, .swedish, "test assumes swedish is next after english")
        XCTAssertEqual(fake.reloadedModels, [.kbWhisperSmall])
        XCTAssertEqual(viewModel.loadedModel, .kbWhisperSmall)
    }
}
