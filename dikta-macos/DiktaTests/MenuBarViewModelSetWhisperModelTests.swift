import XCTest
@testable import Dikta

/// Tests for `MenuBarViewModel.setWhisperModel`'s recovery behaviour when a live
/// model reload fails, using an injected `FakeTranscriptionEngine` so no real
/// WhisperKit model is loaded.
///
/// `ConfigService.shared` is a real singleton that persists to
/// `~/Library/Application Support/Dikta/config.json`, so these tests snapshot and
/// restore `whisperModel` around each test to avoid leaving the developer's real
/// saved config mutated.
@MainActor
final class MenuBarViewModelSetWhisperModelTests: XCTestCase {
    private var savedWhisperModel: String!

    override func setUp() {
        super.setUp()
        savedWhisperModel = ConfigService.shared.whisperModel
    }

    override func tearDown() {
        ConfigService.shared.whisperModel = savedWhisperModel
        super.tearDown()
    }

    /// Polls until `condition` is true or `timeout` elapses. Needed because both
    /// `MenuBarViewModel.init` and `setWhisperModel` do their work in a
    /// fire-and-forget `Task`.
    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    func test_setWhisperModel_success() async {
        ConfigService.shared.whisperModel = WhisperModel.small.rawValue
        let fake = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: fake)
        await waitUntil { viewModel.appState == .idle }

        viewModel.setWhisperModel(.medium)
        await waitUntil { viewModel.appState == .idle }

        XCTAssertEqual(ConfigService.shared.whisperModel, WhisperModel.medium.rawValue)
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertEqual(fake.reloadedModels, [.medium])
    }

    func test_setWhisperModel_failureWithSuccessfulFallback() async {
        ConfigService.shared.whisperModel = WhisperModel.small.rawValue
        let fake = FakeTranscriptionEngine()
        fake.modelsThatFail = [WhisperModel.medium.rawValue]
        let viewModel = MenuBarViewModel(engine: fake)
        await waitUntil { viewModel.appState == .idle }

        viewModel.setWhisperModel(.medium)
        await waitUntil { fake.reloadedModels.count == 2 }
        await waitUntil { viewModel.appState == .idle }

        // The failed model was never persisted; the previous (working) model stays.
        XCTAssertEqual(ConfigService.shared.whisperModel, WhisperModel.small.rawValue)
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertEqual(fake.reloadedModels, [.medium, .small])
    }

    func test_setWhisperModel_failureWithFailedFallback() async {
        ConfigService.shared.whisperModel = WhisperModel.small.rawValue
        let fake = FakeTranscriptionEngine()
        fake.modelsThatFail = [WhisperModel.medium.rawValue, WhisperModel.small.rawValue]
        let viewModel = MenuBarViewModel(engine: fake)
        await waitUntil { viewModel.appState == .idle }

        viewModel.setWhisperModel(.medium)
        // Both the new model and the fallback failed: wait for both attempts
        // rather than for .idle, since the view model must never reach .idle here.
        await waitUntil { fake.reloadedModels.count == 2 }

        XCTAssertEqual(ConfigService.shared.whisperModel, WhisperModel.small.rawValue)
        XCTAssertNotEqual(viewModel.appState, .idle)
        XCTAssertEqual(fake.reloadedModels, [.medium, .small])
    }
}
