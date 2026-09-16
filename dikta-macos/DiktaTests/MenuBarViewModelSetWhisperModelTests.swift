import XCTest
@testable import Dikta

/// Tests for `MenuBarViewModel.setWhisperModel`'s recovery behaviour when a live
/// model reload fails, using an injected `FakeTranscriptionEngine` so no real
/// WhisperKit model is loaded.
///
/// Each test builds its own `ConfigService` pointed at a fresh temp file (never
/// `.shared`), so these tests never touch the developer's real, persisted
/// `~/Library/Application Support/Dikta/config.json`.
@MainActor
final class MenuBarViewModelSetWhisperModelTests: XCTestCase {
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
    /// no completion handle exposed to tests; `setWhisperModel`'s own work is
    /// awaited directly via the `Task` it returns.
    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    func test_setWhisperModel_success() async {
        let fake = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }

        guard let task = viewModel.setWhisperModel(.medium) else {
            return XCTFail("expected setWhisperModel to start a reload")
        }
        await task.value

        XCTAssertEqual(configService.whisperModel, WhisperModel.medium.rawValue)
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertEqual(fake.reloadedModels, [.medium])
    }

    func test_setWhisperModel_failureWithSuccessfulFallback() async {
        let fake = FakeTranscriptionEngine()
        fake.modelsThatFail = [WhisperModel.medium.rawValue]
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }

        guard let task = viewModel.setWhisperModel(.medium) else {
            return XCTFail("expected setWhisperModel to start a reload")
        }
        await task.value

        // The failed model was never persisted; the previous (working) model stays.
        XCTAssertEqual(configService.whisperModel, WhisperModel.small.rawValue)
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertEqual(fake.reloadedModels, [.medium, .small])
    }

    func test_setWhisperModel_failureWithFailedFallback() async {
        let fake = FakeTranscriptionEngine()
        fake.modelsThatFail = [WhisperModel.medium.rawValue, WhisperModel.small.rawValue]
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }

        guard let task = viewModel.setWhisperModel(.medium) else {
            return XCTFail("expected setWhisperModel to start a reload")
        }
        await task.value

        XCTAssertEqual(configService.whisperModel, WhisperModel.small.rawValue)
        XCTAssertNotEqual(viewModel.appState, .idle)
        XCTAssertEqual(fake.reloadedModels, [.medium, .small])
    }

    /// When the target AND the fallback both fail, `.small` (bundled in
    /// release builds, so it can't fail the way a download-dependent model
    /// can) is tried as a last resort. If even that fails, nothing is
    /// actually loaded — `loadedModel` must not lie about it.
    func test_setWhisperModel_tripleFailure_leavesNoModelLoaded() async {
        let fake = FakeTranscriptionEngine()
        fake.modelsThatFail = [WhisperModel.medium.rawValue, WhisperModel.turbo.rawValue, WhisperModel.small.rawValue]
        configService.whisperModel = WhisperModel.turbo.rawValue
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        XCTAssertEqual(viewModel.loadedModel, .turbo)

        guard let task = viewModel.setWhisperModel(.medium) else {
            return XCTFail("expected setWhisperModel to start a reload")
        }
        await task.value

        XCTAssertNil(viewModel.loadedModel, "nothing actually loaded — must not claim otherwise")
        XCTAssertNotEqual(viewModel.appState, .idle)
        XCTAssertEqual(fake.reloadedModels, [.medium, .turbo, .small])
    }

    /// Same triple-attempt sequence, but the last-resort `.small` succeeds:
    /// the app recovers instead of being stuck with no model loaded.
    func test_setWhisperModel_doubleFailure_lastResortSmallSucceeds() async {
        let fake = FakeTranscriptionEngine()
        fake.modelsThatFail = [WhisperModel.medium.rawValue, WhisperModel.turbo.rawValue]
        configService.whisperModel = WhisperModel.turbo.rawValue
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }

        guard let task = viewModel.setWhisperModel(.medium) else {
            return XCTFail("expected setWhisperModel to start a reload")
        }
        await task.value

        XCTAssertEqual(viewModel.loadedModel, .small, "last-resort fallback must load")
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertEqual(fake.reloadedModels, [.medium, .turbo, .small])
    }

    /// Picking a model in the menu while Svenska is active must persist the
    /// preference (so it's checked in the menu, and takes effect once the
    /// language changes away from Svenska) but must NOT reload the engine —
    /// KB-Whisper stays loaded regardless of what the user picks here.
    func test_setWhisperModel_whileSwedishActive_persistsWithoutReloading() async {
        let fake = FakeTranscriptionEngine()
        configService.language = .swedish
        let viewModel = MenuBarViewModel(engine: fake, configService: configService)
        await waitUntil { viewModel.appState == .idle }
        XCTAssertEqual(viewModel.loadedModel, .kbWhisperSmall)

        let task = viewModel.setWhisperModel(.medium)

        XCTAssertNil(task, "no reload should be started while Svenska is active")
        XCTAssertEqual(configService.whisperModel, WhisperModel.medium.rawValue)
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertEqual(viewModel.loadedModel, .kbWhisperSmall, "KB-Whisper must stay loaded")
        XCTAssertTrue(fake.reloadedModels.isEmpty, "picking a preference must not trigger a reload")
    }
}

// MARK: - MenuBarViewModel.effectiveModel Tests

/// Tests for the pure `effectiveModel` function that decides which Whisper
/// model should be active for a given language: KB-Whisper Small for Svenska
/// regardless of preference, the user's preference for every other language.
final class MenuBarViewModelEffectiveModelTests: XCTestCase {

    func test_swedish_alwaysReturnsKbWhisperSmall_regardlessOfPreference() {
        for preference in WhisperModel.allCases {
            XCTAssertEqual(
                MenuBarViewModel.effectiveModel(for: .swedish, preference: preference),
                .kbWhisperSmall,
                "Svenska must use KB-Whisper Small even when the preference is \(preference)"
            )
        }
    }

    func test_nonSwedishLanguages_returnPreferenceUnchanged() {
        for language in Language.allCases where language != .swedish {
            for preference in WhisperModel.allCases.filter(\.isUserSelectable) {
                XCTAssertEqual(
                    MenuBarViewModel.effectiveModel(for: language, preference: preference),
                    preference,
                    "\(language) should use the preference (\(preference)) unchanged"
                )
            }
        }
    }

    /// A hand-edited config can set `whisper_model: "kb-whisper-small"` directly
    /// (it's a valid raw value — see `WhisperModelTests.test_rawValue_kbWhisperSmall_roundTrips`)
    /// even though it's never offered as a menu choice. For any non-Swedish
    /// language, that "preference" must be coerced to `.small` rather than
    /// smuggling KB-Whisper into a language it was never validated for.
    func test_nonSwedishLanguages_kbWhisperSmallPreference_coercesToSmall() {
        for language in Language.allCases where language != .swedish {
            XCTAssertEqual(
                MenuBarViewModel.effectiveModel(for: language, preference: .kbWhisperSmall),
                .small,
                "\(language) must not use KB-Whisper Small as a smuggled-in preference"
            )
        }
    }
}
