import XCTest
@testable import Dikta

/// Tests for `MenuBarViewModel.setEngine`'s behaviour when switching between
/// transcription engines, using an injected `engineFactory` so no real
/// WhisperKit model or Speech framework call is ever made.
///
/// Each test builds its own `ConfigService` pointed at a fresh temp file (never
/// `.shared`), so these tests never touch the developer's real, persisted
/// `~/Library/Application Support/Dikta/config.json`.
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

    func test_setEngine_success() async {
        let initialEngine = FakeTranscriptionEngine()
        let nextEngine = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: initialEngine, configService: configService) { _, _, _ in
            nextEngine
        }
        await waitUntil { viewModel.appState == .idle }

        guard let task = viewModel.setEngine(.appleDictation) else {
            return XCTFail("expected setEngine to start a switch")
        }
        await task.value

        XCTAssertEqual(configService.engine, .appleDictation)
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertEqual(nextEngine.loadCallCount, 1)
    }

    func test_setEngine_failureFallsBackToPreviousEngine() async {
        let initialEngine = FakeTranscriptionEngine()
        let failingEngine = FakeTranscriptionEngine()
        failingEngine.shouldFailLoad = true
        let viewModel = MenuBarViewModel(engine: initialEngine, configService: configService) { _, _, _ in
            failingEngine
        }
        await waitUntil { viewModel.appState == .idle }

        guard let task = viewModel.setEngine(.appleDictation) else {
            return XCTFail("expected setEngine to start a switch")
        }
        await task.value

        // The failed engine was never persisted; the previous (working) engine
        // stays configured. The previous engine instance is never touched by a
        // failed switch (unlike setWhisperModel, which must reload the same
        // shared instance back), so "falling back" to it needs no further step.
        XCTAssertEqual(configService.engine, .whisper)
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertEqual(failingEngine.loadCallCount, 1)
    }

    func test_setEngine_alreadyOnRequestedKind_returnsNilAndSkips() async {
        let initialEngine = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(engine: initialEngine, configService: configService) { _, _, _ in
            FakeTranscriptionEngine()
        }
        await waitUntil { viewModel.appState == .idle }

        // configService.engine defaults to .whisper; requesting .whisper again
        // should be a no-op, not a redundant reload.
        XCTAssertNil(viewModel.setEngine(.whisper))
    }
}
