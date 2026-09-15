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
}
