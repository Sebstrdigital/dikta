import XCTest
import ApplicationServices
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

    private func makeViewModel(
        configFile: URL? = nil,
        ttsService: (any TextToSpeechSpeaking)? = nil
    ) async -> MenuBarViewModel {
        let vm = MenuBarViewModel(
            engine: FakeTranscriptionEngine(),
            configService: ConfigService(configFile: configFile ?? directory.appendingPathComponent("config.json")),
            clipboardManager: FakeClipboardManager(),
            muterRegistry: FakeMuterRegistry(),
            systemAudioCaptureFactory: { FakeSystemAudioCapture() },
            audioRecorder: FakeAudioRecorder(),
            audioFeedback: feedback,
            ttsService: ttsService ?? tts,
            textSelectionService: selection,
            readAloudNotification: { [weak self] title, _ in self?.notifications.append(title) }
        )
        await waitUntil { vm.appState == .idle }
        return vm
    }

    func testHotkeyTimestampAndIDCorrelateSelectionAvailabilityAndScheduling() async {
        let events = ReadAloudEventCapture()
        await ReadAloudTiming.$observer.withValue({ events.append($0) }) {
            let vm = await makeViewModel()
            tts.automaticCompletion = false
            let trigger = ReadAloudTrace(origin: .hotkey, triggeredAt: ReadAloudTiming.now - 0.1)
            vm.ttsHotkeyPressed(trigger: trigger)
            await waitUntil { self.tts.texts.count == 1 }
            tts.startPlayback(0) // Invoked outside the request task, just like a deferred event.
            tts.finish(0)
            await waitUntil { vm.readAloudPhase == nil }
            let captured = events.snapshot.filter { $0.trace?.id == trigger.id }
            for stage in ["hotkey.handled", "request.accepted", "selection.ax", "selection", "availability", "request_to_playback_scheduled", "request.end"] {
                XCTAssertTrue(captured.contains { $0.stage == stage }, "Missing correlated stage: \(stage)")
            }
            XCTAssertTrue(captured.allSatisfy { $0.trace?.triggeredAt == trigger.triggeredAt })
            XCTAssertTrue(captured.allSatisfy { $0.uptime >= trigger.triggeredAt })
            XCTAssertFalse(captured.map(\.message).joined().contains("Synthetic selection"))
        }
    }

    func testHotkeyCorrelationReachesExistingServiceGenerationAndPlayerTimings() async {
        let events = ReadAloudEventCapture()
        await ReadAloudTiming.$observer.withValue({ events.append($0) }) {
            let service = TextToSpeechService(runtime: CorrelationFixtureRuntime(), player: CorrelationFixturePlayer())
            let vm = await makeViewModel(ttsService: service)
            let trigger = ReadAloudTrace(origin: .hotkey)
            vm.ttsHotkeyPressed(trigger: trigger)
            await waitUntil { events.snapshot.contains { $0.trace?.id == trigger.id && $0.stage == "request.end" } }
            let captured = events.snapshot.filter { $0.trace?.id == trigger.id }
            for stage in ["selection", "availability", "service.assets", "service.first_buffer", "playback.schedule", "request_to_playback_scheduled"] {
                XCTAssertTrue(captured.contains { $0.stage == stage }, "Missing service correlation: \(stage)")
            }
            XCTAssertEqual(vm.appState, .idle)
        }
    }

    func testFallbackAndCancelledRequestKeepTheirOwnCorrelation() async {
        let events = ReadAloudEventCapture()
        await ReadAloudTiming.$observer.withValue({ events.append($0) }) {
            let vm = await makeViewModel()
            selection.selectedText = nil
            var capture: CheckedContinuation<String?, Never>?
            selection.clipboardCapture = { await withCheckedContinuation { capture = $0 } }
            let old = ReadAloudTrace(origin: .hotkey)
            vm.ttsHotkeyPressed(trigger: old)
            await waitUntil { capture != nil }
            vm.stopSpeaking()
            selection.selectedText = "New public synthetic selection"
            tts.automaticCompletion = false
            let newer = ReadAloudTrace(origin: .hotkey)
            vm.ttsHotkeyPressed(trigger: newer)
            await waitUntil { self.tts.texts.count == 1 }
            capture?.resume(returning: "Old public synthetic selection")
            await waitUntil { events.snapshot.contains { $0.trace?.id == old.id && $0.stage == "request.end" } }
            tts.startPlayback(0)
            tts.finish(0)
            await waitUntil { vm.readAloudPhase == nil }
            let captured = events.snapshot
            XCTAssertTrue(captured.contains { $0.trace?.id == old.id && $0.stage == "selection.clipboard_fallback" })
            XCTAssertTrue(captured.contains { $0.trace?.id == old.id && $0.stage == "request.cancel" })
            XCTAssertFalse(captured.contains { $0.trace?.id == old.id && $0.stage == "request_to_playback_scheduled" })
            XCTAssertTrue(captured.contains { $0.trace?.id == newer.id && $0.stage == "request_to_playback_scheduled" })
        }
    }

    func testBothHotkeyRoutesTimestampBeforeDispatchWithoutPostingSystemEvents() async throws {
        let manager = HotkeyManager() // Never call start(): no real tap or global effects.
        let delegate = ReadAloudHotkeyCapture()
        manager.delegate = delegate
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.flags = [.maskCommand, .maskAlternate]
        manager.handleEvent(type: .flagsChanged, event: event)
        manager.handleEvent(type: .flagsChanged, event: event) // Modifier hold does not duplicate.
        await waitUntil { delegate.snapshot.count == 1 }
        manager.updateTtsConfig(HotkeyConfig(modifiers: [.ctrl, .alt, .cmd], key: "r"))
        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 15, keyDown: true))
        key.flags = [.maskControl, .maskAlternate, .maskCommand]
        manager.handleEvent(type: .keyDown, event: key)
        await waitUntil { delegate.snapshot.count == 2 }
        let captured = delegate.snapshot
        XCTAssertNotEqual(captured[0].0.id, captured[1].0.id)
        XCTAssertTrue(captured.allSatisfy { $0.0.origin == .hotkey && $0.0.triggeredAt <= $0.1 })
    }

    func testTimingContextFollowsChildTasksAndDoesNotLeakAcrossRequests() async {
        let events = ReadAloudEventCapture()
        let trigger = ReadAloudTrace(origin: .hotkey)
        await ReadAloudTiming.$observer.withValue({ events.append($0) }) {
            await ReadAloudTiming.$trace.withValue(trigger) {
                await Task { ReadAloudTiming.log("helper.first_buffer", 0.25) }.value
            }
            ReadAloudTiming.log("unrelated.probe", 0.1)
        }
        XCTAssertEqual(events.snapshot.first?.trace?.id, trigger.id)
        XCTAssertEqual(events.snapshot.first?.seconds, 0.25)
        XCTAssertNil(events.snapshot.last?.trace)
    }

    private func writePersistedVoice(_ voice: String, to configFile: URL) throws {
        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = AppConfig.default
        config.ttsVoiceRawValue = voice
        try JSONEncoder().encode(config).write(to: configFile)
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

    /// Separately opted-in SDK/output qualification, never an ordinary unit test.
    func testIsolatedPublicColdWarmOnsetQualification() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DIKTA_ONSET_QUALIFICATION"] == "1" else {
            throw XCTSkip("Real model/output onset qualification requires explicit isolated assets")
        }
        let home = URL(fileURLWithPath: try XCTUnwrap(env["DIKTA_ONSET_HOME"]))
        let output = URL(fileURLWithPath: try XCTUnwrap(env["DIKTA_ONSET_OUTPUT"]))
        let executable = URL(fileURLWithPath: try XCTUnwrap(env["DIKTA_ONSET_HELPER"]))
        XCTAssertEqual(ConfigService.shared.storageURLForTesting.path, "/tmp/dikta-parakeet-ultra-isolated-config/config.json")
        XCTAssertEqual(env["DIKTA_REAL_SESSIONS_DIR"], "/tmp/dikta-parakeet-ultra-isolated-empty-sessions")
        XCTAssertEqual(env["CFFIXED_USER_HOME"], home.path)
        guard home.path.hasPrefix("/Users/sebastianstrandberg/artifacts/dikta-read-aloud-onset-model-home"),
              executable.path.hasPrefix(output.path + "/") else { throw NKError.identity }
        let text = "The morning light falls across the quiet garden. A small bird rests on the wooden fence, while the leaves move gently in the breeze. Today we will review the project, discuss the next steps, and write a clear summary for everyone on the team."
        var records: [[String: Any]] = []
        // ABBA order reduces one-way warm-cache/order bias; this is still a
        // bounded public fixture, not a general performance distribution.
        for (trial, earlier) in [false, true, true, false].enumerated() {
            let children = OnsetQualificationChildren()
            var stages: [[String: Any]] = []
            let sink: (String, TimeInterval) -> Void = { stage, duration in
                stages.append(["stage": stage, "seconds": duration])
            }
            let runtime = NativeKokoroRuntimeClient(resolveHome: { home },
                makeSession: { NativeKokoroSession(factory: { try children.launch(executable) }) }, timing: sink)
            // This is deliberately real audio OUTPUT, not microphone/process-tap input.
            let service = TextToSpeechService(runtime: runtime, player: AVNativeTTSPlayer(),
                chunker: ProgressiveTextChunker(earlierFirstSentence: earlier), timing: sink)
            defer { service.stop(); runtime.stop(); children.cleanup() }
            let vm = MenuBarViewModel(engine: FakeTranscriptionEngine(),
                configService: ConfigService(configFile: directory.appendingPathComponent("qualification.json")),
                clipboardManager: FakeClipboardManager(), muterRegistry: FakeMuterRegistry(),
                systemAudioCaptureFactory: { FakeSystemAudioCapture() }, audioRecorder: FakeAudioRecorder(),
                audioFeedback: FakeAudioFeedback(), ttsService: service, textSelectionService: selection,
                readAloudNotification: { title, _ in XCTFail("Unexpected public qualification error: \(title)") })
            await waitUntil { vm.appState == .idle }
            selection.selectedText = text
            for temperature in ["process-cold", "warm"] {
                stages = []
                let start = ProcessInfo.processInfo.systemUptime
                let task = Task { await vm.speakSelectedText() }
                let deadline = start + 95
                while vm.readAloudPhase != .playbackScheduled, ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                let onset = ProcessInfo.processInfo.systemUptime - start
                XCTAssertEqual(vm.readAloudPhase, .playbackScheduled)
                await task.value
                XCTAssertEqual(vm.appState, .idle)
                XCTAssertNil(vm.readAloudPhase)
                records.append(["trial": trial, "earlier_sentence": earlier, "temperature": temperature,
                    "request_to_playback_scheduled_seconds": onset, "stages": stages,
                    "selection": "synthetic getter; no AX/clipboard", "audible_onset_measured": false])
            }
            service.stop(); runtime.stop()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !children.allExited, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(children.allExited, "Only owned qualification helpers must be reaped")
            children.cleanup()
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("service-onset-timings.json"))
    }

    func testSelectionAcknowledgedImmediatelyAndKeybindCancelsPendingCapture() async {
        let vm = await makeViewModel()
        selection.selectedText = nil
        var capture: CheckedContinuation<String?, Never>?
        selection.clipboardCapture = { await withCheckedContinuation { capture = $0 } }
        let task = Task { await vm.speakSelectedText() }
        await waitUntil { capture != nil }
        XCTAssertEqual(vm.readAloudPhase, .selecting)
        assertCues(0, 0) // Acknowledgement is not accepted speech or playback.
        vm.ttsHotkeyPressed()
        for _ in 0..<100 { await Task.yield() }
        capture?.resume(returning: "Synthetic selected sentence.")
        await task.value
        XCTAssertTrue(tts.texts.isEmpty)
        XCTAssertNil(vm.readAloudPhase)
        assertCues(0, 0)
    }

    func testAvailabilityWaitHasAccuratePreparingStatusAndStopClearsIt() async {
        let vm = await makeViewModel()
        var availability: CheckedContinuation<Bool, Never>?
        tts.availability = { await withCheckedContinuation { availability = $0 } }
        let task = Task { await vm.speakSelectedText() }
        await waitUntil { availability != nil }
        XCTAssertEqual(vm.readAloudPhase, .checkingAssets)
        vm.stopSpeaking()
        XCTAssertNil(vm.readAloudPhase)
        availability?.resume(returning: true)
        await task.value
        XCTAssertTrue(tts.texts.isEmpty)
        assertCues(0, 0)
    }

    func testAcceptedRequestHasOneDedicatedStartBeforeSynthesisAndOneNaturalStop() async {
        tts.automaticCompletion = false
        let vm = await makeViewModel()
        let task = await begin(vm)
        XCTAssertEqual(vm.appState, .speaking)
        XCTAssertEqual(vm.readAloudPhase, .generating)
        assertCues(1, 0)
        tts.startPlayback(0)
        XCTAssertEqual(vm.readAloudPhase, .playbackScheduled)
        XCTAssertEqual(vm.readAloudPhase?.status, "Read Aloud: playback scheduled")
        tts.finish(0)
        await task.value
        XCTAssertNil(vm.readAloudPhase)
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
        tts.startPlayback(0) // A late scheduling event must not promote the new request.
        XCTAssertEqual(vm.readAloudPhase, .generating)
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
        XCTAssertNil(vm.readAloudPhase)
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
        XCTAssertNil(vm.readAloudPhase)
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
        XCTAssertNil(vm.readAloudPhase)
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

    func testVoiceCapturedBeforeAvailabilityWaitAndChangeAppliesToNextRequest() async {
        let vm = await makeViewModel()
        var availability: CheckedContinuation<Bool, Never>?
        var first = true
        tts.availability = {
            if first {
                first = false
                return await withCheckedContinuation { availability = $0 }
            }
            return true
        }
        let requestA = Task { await vm.speakSelectedText() }
        await waitUntil { availability != nil }
        vm.setTtsVoice(.af_bella)
        availability?.resume(returning: true)
        await requestA.value
        XCTAssertEqual(tts.availabilityRequests.map(\.voice), [.af_heart])
        XCTAssertEqual(tts.requests.map(\.voice), [.af_heart])

        await vm.speakSelectedText()
        XCTAssertEqual(tts.availabilityRequests.map(\.voice), [.af_heart, .af_bella])
        XCTAssertEqual(tts.requests.map(\.voice), [.af_heart, .af_bella])
    }

    func testPersistedRemovedVoiceIsPreservedAndBlocksBeforeRead() async throws {
        let configFile = directory.appendingPathComponent("persisted-removed.json")
        try writePersistedVoice(KokoroVoice.af_bella.rawValue, to: configFile)
        let restoredTTS = FakeTextToSpeechService()
        let restored = await makeViewModel(configFile: configFile, ttsService: restoredTTS)

        XCTAssertEqual(restored.ttsVoice, .af_heart)
        XCTAssertEqual(restored.unsupportedTtsVoiceID, KokoroVoice.af_bella.rawValue)
        XCTAssertFalse(restored.isTtsVoiceSelected(.af_heart))
        await restored.speakSelectedText()
        XCTAssertTrue(restoredTTS.availabilityRequests.isEmpty)
        XCTAssertTrue(restoredTTS.texts.isEmpty)
        XCTAssertEqual(ConfigService(configFile: configFile).ttsVoiceRawValue, KokoroVoice.af_bella.rawValue)
    }

    func testPersistedUnknownVoiceHasNoSelectedRowAndBlocksBeforeRead() async throws {
        let configFile = directory.appendingPathComponent("persisted-unknown.json")
        try writePersistedVoice("future_voice", to: configFile)
        let restoredTTS = FakeTextToSpeechService()

        let restored = await makeViewModel(configFile: configFile, ttsService: restoredTTS)

        XCTAssertEqual(restored.ttsVoice, .af_heart, "The service fallback is not a selected preference")
        XCTAssertEqual(restored.unsupportedTtsVoiceID, "future_voice")
        XCTAssertEqual(restored.ttsVoiceDisplayName, "future_voice")
        XCTAssertFalse(restored.isTtsVoiceSelected(.af_heart))
        XCTAssertFalse(restored.isTtsVoiceSelected(.af_bella))
        await restored.speakSelectedText()
        XCTAssertTrue(restoredTTS.availabilityRequests.isEmpty)
        XCTAssertTrue(restoredTTS.texts.isEmpty)
        XCTAssertEqual(ConfigService(configFile: configFile).ttsVoiceRawValue, "future_voice")
    }

    func testUnknownPersistedSpeedUsesNormalUntilExplicitSelectionReplacesRawValue() async throws {
        let configFile = directory.appendingPathComponent("future-speed.json")
        var config = AppConfig.default; config.ttsSpeedRawValue = 2.5
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: configFile)
        let vm = await makeViewModel(configFile: configFile)
        XCTAssertEqual(vm.ttsSpeed, .normal)
        XCTAssertEqual(ConfigService(configFile: configFile).ttsSpeedRawValue, 2.5)
        vm.setTtsSpeed(.fast)
        XCTAssertEqual(ConfigService(configFile: configFile).ttsSpeedRawValue, TextToSpeechSpeed.fast.rawValue)
    }

    func testSpeedCapturedBeforeAvailabilityWaitAndChangeAppliesToNextRequest() async {
        let vm = await makeViewModel()
        var availability: CheckedContinuation<Bool, Never>?
        var first = true
        tts.availability = {
            if first { first = false; return await withCheckedContinuation { availability = $0 } }
            return true
        }
        let firstRead = Task { await vm.speakSelectedText() }
        await waitUntil { availability != nil }
        vm.setTtsSpeed(.speedy)
        availability?.resume(returning: true)
        await firstRead.value
        XCTAssertEqual(tts.requests.map(\.speed), [.normal])
        await vm.speakSelectedText()
        XCTAssertEqual(tts.requests.map(\.speed), [.normal, .speedy])
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

@MainActor
private final class CorrelationFixtureRuntime: NativeKokoroRuntimeServing {
    func prepare(voiceID: String, speed: Float) async throws -> NativeKokoroAssetSnapshot {
        .init(revision: "synthetic-correlation-fixture", voiceID: voiceID, voiceDigest: "fixture", speed: speed)
    }
    func synthesize(text: String, snapshot: NativeKokoroAssetSnapshot) async throws -> Data {
        await Task.yield() // Exercise asynchronous propagation without models or devices.
        return Data("synthetic-correlation-audio".utf8)
    }
    func playbackDrained() {}
    func stop() {}
}

@MainActor
private final class CorrelationFixturePlayer: NativeTTSPlayback {
    var eventHandler: ((NativeTTSPlaybackEvent) -> Void)?
    func play(wav: Data, tag: UUID) throws {
        eventHandler?(.started(tag)); eventHandler?(.finished(tag))
    }
    func stop() {}
}

private final class ReadAloudHotkeyCapture: HotkeyManagerDelegate {
    private let lock = NSLock()
    private var triggers: [(ReadAloudTrace, TimeInterval)] = []
    var snapshot: [(ReadAloudTrace, TimeInterval)] { lock.lock(); defer { lock.unlock() }; return triggers }
    func ttsHotkeyPressed(trigger: ReadAloudTrace) {
        lock.lock(); triggers.append((trigger, ReadAloudTiming.now)); lock.unlock()
    }
    func hotkeyPressed(mode: HotkeyMode) {}
    func hotkeyReleased(mode: HotkeyMode) {}
    func hotkeyRecorded(modifiers: [ModifierKey], key: String?) {}
    func formatHotkeyPressed() {}
    func hotkeyManagerDidFailToStart(_ error: String) {}
}

private final class ReadAloudEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ReadAloudTimingEvent] = []
    func append(_ event: ReadAloudTimingEvent) { lock.lock(); events.append(event); lock.unlock() }
    var snapshot: [ReadAloudTimingEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

/// Owns only children launched by this qualification; no PID discovery or app control.
private final class OnsetQualificationChildren: @unchecked Sendable {
    private let lock = NSLock()
    private var children: [NativeKokoroChild] = []
    func launch(_ executable: URL) throws -> NativeKokoroChild {
        let child = try NativeKokoroChild(executable: executable)
        lock.lock(); children.append(child); lock.unlock()
        return child
    }
    var allExited: Bool {
        lock.lock(); let snapshot = children; lock.unlock()
        return !snapshot.isEmpty && snapshot.allSatisfy { $0.exited() }
    }
    func cleanup() {
        lock.lock(); let snapshot = children; lock.unlock()
        for child in snapshot where !child.exited() {
            child.closeControl(); child.signal(force: true)
        }
    }
}
