import XCTest
@testable import Dikta

@MainActor
final class MenuBarViewModelReadAloudTests: XCTestCase {
    private var directory: URL!
    private var tts: FakeTextToSpeechService!
    private var selection: FakeTextSelectionService!
    private var feedback: FakeAudioFeedback!
    private var notifications: [String] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tts = FakeTextToSpeechService()
        selection = FakeTextSelectionService()
        feedback = FakeAudioFeedback()
        notifications = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Controlled lifecycle did not reach its expected gate")
    }

    private func makeViewModel() async -> MenuBarViewModel {
        let vm = MenuBarViewModel(
            engine: FakeTranscriptionEngine(),
            configService: ConfigService(configFile: directory.appendingPathComponent("config.json")),
            clipboardManager: FakeClipboardManager(),
            muterRegistry: FakeMuterRegistry(),
            systemAudioCaptureFactory: { FakeSystemAudioCapture() },
            audioRecorder: FakeAudioRecorder(),
            audioFeedback: feedback,
            ttsService: tts,
            textSelectionService: selection,
            readAloudNotification: { [weak self] title, _ in self?.notifications.append(title) }
        )
        await waitUntil { vm.appState == .idle }
        return vm
    }

    private func begin(_ vm: MenuBarViewModel, count: Int = 1) async -> Task<Void, Never> {
        let task = Task { await vm.speakSelectedText() }
        await waitUntil { self.tts.texts.count == count }
        return task
    }

    private func assertCues(_ starts: Int, _ stops: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(feedback.readAloudStartCount, starts, file: file, line: line)
        XCTAssertEqual(feedback.readAloudStopCount, stops, file: file, line: line)
        XCTAssertEqual(feedback.beepOnCount, 0, file: file, line: line)
        XCTAssertEqual(feedback.beepOffCount, 0, file: file, line: line)
    }

    func testAcceptedRequestHasOneDedicatedStartBeforeSynthesisAndOneNaturalStop() async {
        tts.automaticCompletion = false
        let vm = await makeViewModel()
        let task = await begin(vm)
        XCTAssertEqual(vm.appState, .speaking)
        assertCues(1, 0)
        tts.finish(0)
        await task.value
        assertCues(1, 1)
        XCTAssertEqual(vm.appState, .idle)
        XCTAssertTrue(notifications.isEmpty)
    }

    func testExplicitStopDuringGenerationAndRepeatedStopEmitOnlyOneStop() async {
        tts.automaticCompletion = false
        let vm = await makeViewModel()
        let task = await begin(vm)
        vm.stopSpeaking()
        vm.stopSpeaking()
        assertCues(1, 1)
        XCTAssertEqual(tts.stopCount, 1)
        XCTAssertEqual(vm.appState, .idle)
        tts.finish(0)
        await task.value
        assertCues(1, 1)
        XCTAssertTrue(notifications.isEmpty)
    }

    func testOldSuccessCannotClearNewStatePendingGuardOrCues() async {
        tts.automaticCompletion = false
        let vm = await makeViewModel()
        let old = await begin(vm)
        vm.stopSpeaking()
        let newer = await begin(vm, count: 2)
        tts.finish(0)
        await old.value
        XCTAssertEqual(vm.appState, .speaking)
        assertCues(2, 1)
        await vm.speakSelectedText()
        XCTAssertEqual(tts.texts.count, 2)
        tts.finish(1)
        await newer.value
        assertCues(2, 2)
        tts.automaticCompletion = true
        await vm.speakSelectedText() // A completed request must release its guard.
        XCTAssertEqual(tts.texts.count, 3)
        assertCues(3, 3)
    }

    func testOldFailureCannotNotifyOrResetNewRequest() async {
        tts.automaticCompletion = false
        let vm = await makeViewModel()
        let old = await begin(vm)
        vm.stopSpeaking()
        let newer = await begin(vm, count: 2)
        tts.finish(0, error: TextToSpeechService.TTSError.playbackFailed)
        await old.value
        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(vm.appState, .speaking)
        assertCues(2, 1)
        tts.finish(1)
        await newer.value
    }

    func testOldCancellationCannotResetNewRequestOrEmitCues() async {
        tts.automaticCompletion = false
        let vm = await makeViewModel()
        let old = await begin(vm)
        vm.stopSpeaking()
        let newer = await begin(vm, count: 2)
        tts.finish(0, error: CancellationError())
        await old.value
        XCTAssertEqual(vm.appState, .speaking)
        assertCues(2, 1)
        XCTAssertTrue(notifications.isEmpty)
        tts.finish(1)
        await newer.value
    }

    func testStoppedCompletionCannotResetRecordingState() async {
        tts.automaticCompletion = false
        let vm = await makeViewModel()
        let task = await begin(vm)
        vm.stopSpeaking()
        vm.appState = .recording
        tts.finish(0)
        await task.value
        XCTAssertEqual(vm.appState, .recording)
        assertCues(1, 1)
    }

    func testAcceptedFailureHasNoStopCueAndReportsError() async {
        tts.failure = TextToSpeechService.TTSError.playbackFailed
        let vm = await makeViewModel()
        await vm.speakSelectedText()
        assertCues(1, 0)
        XCTAssertEqual(notifications, ["TTS Error"])
        XCTAssertEqual(vm.appState, .idle)
    }

    func testIntentionalCancellationHasNoErrorOrCompletionCue() async {
        tts.failure = CancellationError()
        let vm = await makeViewModel()
        await vm.speakSelectedText()
        assertCues(1, 0)
        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(vm.appState, .idle)
    }

    func testCallerCancellationHasNoStopOrErrorNotification() async {
        tts.automaticCompletion = false
        let vm = await makeViewModel()
        let task = await begin(vm)
        task.cancel()
        tts.finish(0, error: CancellationError())
        await task.value
        assertCues(1, 0)
        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(vm.appState, .idle)
    }

    func testNoAndEmptyTextRejectWithoutCues() async {
        let vm = await makeViewModel()
        selection.selectedText = nil
        await vm.speakSelectedText()
        selection.selectedText = " \n "
        await vm.speakSelectedText()
        assertCues(0, 0)
        XCTAssertEqual(notifications, ["No Selection", "Empty Selection"])
        XCTAssertTrue(tts.texts.isEmpty)
    }

    func testUnavailableAndOccupiedStateRejectWithoutCues() async {
        let vm = await makeViewModel()
        tts.available = false
        await vm.speakSelectedText()
        tts.available = true
        for state in [AppState.recording, .processing, .loading, .speaking] {
            vm.appState = state
            await vm.speakSelectedText()
        }
        assertCues(0, 0)
        XCTAssertTrue(tts.texts.isEmpty)
    }

    func testSelectionWaitCancellationAndStaleDeferDoNotClearNewGuard() async {
        let vm = await makeViewModel()
        selection.selectedText = nil
        var capture: CheckedContinuation<String?, Never>?
        selection.clipboardCapture = { await withCheckedContinuation { capture = $0 } }
        let old = Task { await vm.speakSelectedText() }
        await waitUntil { capture != nil }
        await vm.speakSelectedText() // Pending selection is non-overlapping too.
        XCTAssertEqual(selection.clipboardCalls, 1)
        vm.stopSpeaking() // Unaccepted: no invented stop.
        assertCues(0, 0)
        selection.selectedText = "New synthetic selection"
        tts.automaticCompletion = false
        let newer = await begin(vm)
        capture?.resume(returning: "Old synthetic selection")
        await old.value
        XCTAssertEqual(vm.appState, .speaking)
        await vm.speakSelectedText()
        XCTAssertEqual(tts.texts.count, 1)
        assertCues(1, 0)
        tts.finish(0)
        await newer.value
    }

    func testCallerCancelledDuringSelectionDoesNotAccept() async {
        let vm = await makeViewModel()
        selection.selectedText = nil
        var capture: CheckedContinuation<String?, Never>?
        selection.clipboardCapture = { await withCheckedContinuation { capture = $0 } }
        let task = Task { await vm.speakSelectedText() }
        await waitUntil { capture != nil }
        task.cancel()
        capture?.resume(returning: "Synthetic selection")
        await task.value
        assertCues(0, 0)
        XCTAssertTrue(tts.texts.isEmpty)
        XCTAssertTrue(notifications.isEmpty)
    }

    func testAvailabilityWaitRechecksCancellationAndRecordingEvenOnFailure() async {
        let vm = await makeViewModel()
        var availability: CheckedContinuation<Bool, Never>?
        tts.availability = { await withCheckedContinuation { availability = $0 } }
        let task = Task { await vm.speakSelectedText() }
        await waitUntil { availability != nil }
        task.cancel()
        vm.appState = .recording
        availability?.resume(returning: false)
        await task.value
        assertCues(0, 0)
        XCTAssertEqual(vm.appState, .recording)
        XCTAssertTrue(notifications.isEmpty)
    }

    func testAvailabilitySuccessCannotAcceptOverRecording() async {
        let vm = await makeViewModel()
        var availability: CheckedContinuation<Bool, Never>?
        tts.availability = { await withCheckedContinuation { availability = $0 } }
        let task = Task { await vm.speakSelectedText() }
        await waitUntil { availability != nil }
        vm.appState = .recording
        availability?.resume(returning: true)
        await task.value
        assertCues(0, 0)
        XCTAssertTrue(tts.texts.isEmpty)
        XCTAssertEqual(vm.appState, .recording)
    }

    func testClipboardFallbackAcceptsUsableCurrentText() async {
        let vm = await makeViewModel()
        selection.selectedText = nil
        selection.clipboardText = "Synthetic existing clipboard text"
        await vm.speakSelectedText()
        XCTAssertEqual(tts.texts, ["Synthetic existing clipboard text"])
        XCTAssertEqual(selection.clipboardCalls, 1)
        assertCues(1, 1)
    }

    func testTestHostTTSFallbackIsInert() async throws {
        let inert = InertTextToSpeechService()
        let available = await inert.checkAvailable()
        XCTAssertFalse(available)
        XCTAssertFalse(inert.isSetUp)
        do { try await inert.speak("Synthetic text"); XCTFail("Expected inert rejection") }
        catch { XCTAssertTrue(error is TextToSpeechService.TTSError) }
        inert.stop()
    }
}
