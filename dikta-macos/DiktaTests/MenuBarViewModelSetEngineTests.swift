import XCTest
@testable import Dikta

/// Tests for `MenuBarViewModel.setEngine`'s runtime engine switching — the
/// same safety net `setWhisperModel` uses for model switching, but for the
/// whole `TranscriptionEngine` instance — plus the knock-on effects a
/// non-Whisper engine has on `setWhisperModel` and language changes (see
/// `TranscriptionEngineKind.usesWhisperModelSubmenu`). Uses an injected
/// `FakeTranscriptionEngine` per engine kind so no real WhisperKit or
/// FluidAudio model is ever loaded.
///
/// Each test builds its own `ConfigService` pointed at a fresh temp file
/// (never `.shared`), so these tests never touch the developer's real,
/// persisted `~/Library/Application Support/Dikta/config.json`.
@MainActor
final class MenuBarViewModelSetEngineTests: XCTestCase {
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
    /// no completion handle exposed to tests; `setEngine`'s own work is awaited
    /// directly via the `Task` it returns.
    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    /// The single place this file builds a `MenuBarViewModel`.
    ///
    /// `engineFactory` is what `setEngine` uses to build the replacement
    /// engine when switching kind — pass one whenever a test calls
    /// `setEngine`. Tests that never call it can omit it; `MenuBarViewModel`
    /// falls through to a factory that asserts if it's ever actually invoked
    /// under XCTest, the same safety net `engine:`-only tests elsewhere rely on.
    ///
    /// The audio seams are always faked, matching the other `MenuBarViewModel`
    /// suites — a real `AudioFeedback`/`AudioRecorder` would touch CoreAudio or
    /// prompt for microphone access.
    private func makeViewModel(
        engine: any TranscriptionEngine,
        engineFactory: ((TranscriptionEngineKind, WhisperModel) -> any TranscriptionEngine)? = nil
    ) -> MenuBarViewModel {
        MenuBarViewModel(
            engine: engine,
            engineFactory: engineFactory,
            configService: configService,
            muterRegistry: FakeMuterRegistry(),
            audioRecorder: FakeAudioRecorder(),
            audioFeedback: FakeAudioFeedback()
        )
    }

    // MARK: - Diagnostic context tag

    /// The START/RESULT diagnostic lines carry which engine, model and
    /// language handled a take, so a long-session quality report can be
    /// checked against the log instead of guessed at. The tag must follow the
    /// engine switch: after moving to Parakeet, `model=-` (no Whisper model).
    func test_diagnosticEngineContext_reflectsEngineModelAndLanguage() async {
        let whisperEngine = FakeTranscriptionEngine()
        let parakeetEngine = FakeTranscriptionEngine()
        let viewModel = makeViewModel(engine: whisperEngine) { kind, _ in
            kind == .whisper ? whisperEngine : parakeetEngine
        }
        await waitUntil { viewModel.appState == .idle }

        let before = viewModel.diagnosticEngineContext()
        XCTAssertTrue(before.hasPrefix("engine=whisper model="), before)
        XCTAssertTrue(before.contains(" lang=\(configService.language.rawValue)"), before)
        XCTAssertFalse(before.contains("model=-"), "Whisper must report its loaded model: \(before)")

        guard let task = viewModel.setEngine(.parakeetRedux) else {
            return XCTFail("expected setEngine to start a switch")
        }
        await task.value

        let after = viewModel.diagnosticEngineContext()
        XCTAssertTrue(after.hasPrefix("engine=parakeet-redux model=- "), after)

        let mem = viewModel.diagnosticMemoryTag()
        XCTAssertTrue(mem.hasPrefix("mem=") && mem.hasSuffix("MB"), mem)
    }

    // MARK: - setEngine: success

    func test_setEngine_success_persistsAndSwapsEngine() async {
        let whisperEngine = FakeTranscriptionEngine()
        let parakeetEngine = FakeTranscriptionEngine()
        let viewModel = makeViewModel(engine: whisperEngine) { kind, _ in
            kind == .whisper ? whisperEngine : parakeetEngine
        }
        await waitUntil { viewModel.appState == .idle }
        XCTAssertEqual(configService.engine, .whisper)

        guard let task = viewModel.setEngine(.parakeetV3) else {
            return XCTFail("expected setEngine to start a switch")
        }
        await task.value

        XCTAssertEqual(configService.engine, .parakeetV3, "the new kind must be persisted once loaded")
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertTrue(parakeetEngine.isReady, "the new engine must have been loaded")
        XCTAssertNil(viewModel.loadedModel, "Parakeet has no Whisper model — loadedModel must not claim one")
    }

    func test_setEngine_alreadyActiveKind_isNoOp() async {
        let whisperEngine = FakeTranscriptionEngine()
        let viewModel = makeViewModel(engine: whisperEngine)
        await waitUntil { viewModel.appState == .idle }

        let task = viewModel.setEngine(.whisper)

        XCTAssertNil(task, "already on this kind — nothing to switch")
        XCTAssertEqual(viewModel.appState, .idle)
    }

    // MARK: - setEngine: failure falls back, persists nothing

    /// If the target engine fails to load, `setEngine` must restore the engine
    /// that was already loaded and working — and must never persist the failed
    /// kind, mirroring `setWhisperModel`'s "the failed model was never
    /// persisted" rule.
    func test_setEngine_failure_restoresPreviousEngineAndDoesNotPersist() async {
        let whisperEngine = FakeTranscriptionEngine()
        let parakeetEngine = FakeTranscriptionEngine()
        parakeetEngine.shouldFailLoad = true
        let viewModel = makeViewModel(engine: whisperEngine) { kind, _ in
            kind == .whisper ? whisperEngine : parakeetEngine
        }
        await waitUntil { viewModel.appState == .idle }
        XCTAssertEqual(viewModel.loadedModel, .small, "default preference is small")

        guard let task = viewModel.setEngine(.parakeetV3) else {
            return XCTFail("expected setEngine to start a switch")
        }
        await task.value

        XCTAssertEqual(configService.engine, .whisper, "the failed kind must never be persisted")
        XCTAssertEqual(viewModel.appState, .idle, "must recover — the previous engine was already loaded, so no re-load is needed")
        XCTAssertEqual(viewModel.loadedModel, .small, "loadedModel must reflect the restored (whisper) engine, unchanged by the failed attempt")
        XCTAssertFalse(parakeetEngine.isReady)
    }

    // MARK: - setEngine: the Swedish rule

    /// Switching from Parakeet back to Whisper while Svenska is active must
    /// load KB-Whisper Small — the effective model for Svenska — not the raw
    /// `whisperModel` preference, exactly as if Svenska had just been selected
    /// (see `MenuBarViewModel.effectiveModel(for:)`).
    func test_setEngine_parakeetToWhisper_whileSwedishActive_loadsKbWhisperSmall() async {
        let parakeetEngine = FakeTranscriptionEngine()
        let whisperEngine = FakeTranscriptionEngine()
        configService.language = .swedish
        configService.whisperModel = WhisperModel.turbo.rawValue
        configService.engine = .parakeetV3
        let viewModel = makeViewModel(engine: parakeetEngine) { kind, _ in
            kind == .whisper ? whisperEngine : parakeetEngine
        }
        await waitUntil { viewModel.appState == .idle }

        guard let task = viewModel.setEngine(.whisper) else {
            return XCTFail("expected setEngine to start a switch")
        }
        await task.value

        XCTAssertEqual(configService.engine, .whisper)
        XCTAssertEqual(viewModel.loadedModel, .kbWhisperSmall, "Svenska must load KB-Whisper Small, not the raw turbo preference")
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertEqual(configService.whisperModel, WhisperModel.turbo.rawValue, "the raw preference itself is untouched")
    }

    // MARK: - A non-Whisper engine changes what setWhisperModel/language changes do

    /// While a Parakeet engine is active, `setWhisperModel` has no engine to
    /// reload — it must only remember the preference for whenever Whisper
    /// becomes the active engine again (see
    /// `TranscriptionEngineKind.usesWhisperModelSubmenu`).
    func test_setWhisperModel_whileParakeetActive_persistsWithoutReloading() async {
        let parakeetEngine = FakeTranscriptionEngine()
        configService.engine = .parakeetV3
        let viewModel = makeViewModel(engine: parakeetEngine)
        await waitUntil { viewModel.appState == .idle }

        let task = viewModel.setWhisperModel(.medium)

        XCTAssertNil(task, "no reload should be started while a Parakeet engine is active")
        XCTAssertEqual(configService.whisperModel, WhisperModel.medium.rawValue)
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertTrue(parakeetEngine.reloadedModels.isEmpty, "picking a Whisper Model preference must not reload the active Parakeet engine")
    }

    /// While a Parakeet engine is active, a language change has no Whisper
    /// model to reload to — it must not touch the engine at all.
    func test_languageChange_whileParakeetActive_doesNotReload() async {
        let parakeetEngine = FakeTranscriptionEngine()
        configService.engine = .parakeetV3
        let viewModel = makeViewModel(engine: parakeetEngine)
        await waitUntil { viewModel.appState == .idle }

        viewModel.setLanguage(.swedish)
        try? await Task.sleep(nanoseconds: 300_000_000) // give any spurious reload a chance to start

        XCTAssertEqual(configService.language, .swedish)
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertTrue(parakeetEngine.reloadedModels.isEmpty, "a language change must not reload a Parakeet engine")
    }
}
