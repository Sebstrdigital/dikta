import XCTest
@testable import Dikta

/// Records paste calls instead of posting CGEvents, so a test run never types
/// into whatever window happens to be frontmost and never clobbers the
/// developer's clipboard.
final class FakeClipboardManager: ClipboardManager {
    private(set) var pastedMultiline: [String] = []
    private(set) var pastedText: [String] = []

    override func pasteMultiline(_ text: String) {
        pastedMultiline.append(text)
    }

    override func pasteText(_ text: String) {
        pastedText.append(text)
    }
}

/// Records `muteAll()`/`unmuteAll()` calls instead of touching real mic-muting
/// apps (Meet, Teams, Slack, ...), so tests can assert whether the debrief
/// "Microphone + system audio" gating skipped muting.
final class FakeMuterRegistry: MuterRegistering {
    private(set) var muteAllCallCount = 0
    private(set) var unmuteAllCallCount = 0

    func muteAll() -> [MuteToken] {
        muteAllCallCount += 1
        return []
    }

    func unmuteAll(_ tokens: [MuteToken]) {
        unmuteAllCallCount += 1
    }
}

/// Suspends an `async` caller (never blocks a thread) until the test opens
/// the gate — used to hold `SystemAudioCapturing.start()` open the way a TCC
/// permission prompt does, so the test can act during that window.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

/// Blocks a fake audio loader on its background thread until the test releases
/// it, so the test can inspect ViewModel state mid-decode.
final class LoaderGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    /// Called on the loader's detached thread. Never call from the main actor.
    func waitUntilReleased() {
        _ = semaphore.wait(timeout: .now() + 5)
    }

    func release() {
        semaphore.signal()
    }
}

/// Tests the debrief branch of `MenuBarViewModel`. Every dependency that would
/// otherwise reach the outside world — transcription engine, summarizer,
/// session store, clipboard, config file — is injected, so these tests touch
/// nothing but a temp directory.
@MainActor
final class MenuBarViewModelDebriefTests: XCTestCase {
    private var tempDir: URL!
    private var configService: ConfigService!
    private var store: DebriefStore!
    private var clipboard: FakeClipboardManager!

    /// Every ViewModel a test built that may have touched the real
    /// `AudioRecorder`. `AudioRecorder` has no deinit teardown, so an
    /// `AVAudioEngine` whose `startRecording()` completed after the test gave
    /// up waiting would stay running for the rest of the test *process* —
    /// enough leaked input clients and the next `AVAudioEngine` any test
    /// builds (e.g. `AudioFeedback`'s, in `MenuBarViewModel.init`) blocks
    /// forever inside CoreAudio. `tearDown` force-stops them.
    private var recordingViewModels: [MenuBarViewModel] = []

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        configService = ConfigService(configFile: tempDir.appendingPathComponent("config.json"))
        // Keep the run silent: no beeps, no notification banners.
        configService.muteSounds = true
        configService.muteNotifications = true
        store = DebriefStore(rootDirectory: tempDir.appendingPathComponent("sessions"))
        clipboard = FakeClipboardManager()
    }

    override func tearDown() async throws {
        // Release any real audio engine a test left running before anything
        // else — see `recordingViewModels`. A start that landed after the
        // test stopped waiting has nobody else to stop it.
        await MainActor.run {
            for viewModel in recordingViewModels {
                viewModel.stopRecording()
                _ = viewModel.audioRecorder.stopRecording()
                viewModel.audioRecorder.onLiveSamples = nil
            }
            recordingViewModels.removeAll()
        }

        try? FileManager.default.removeItem(at: tempDir)
        clipboard = nil
        store = nil
        configService = nil
        tempDir = nil
        try await super.tearDown()
    }

    private func summary() -> DebriefSummary {
        DebriefSummary(
            summary: "Sprint review went well.",
            decisions: ["Cut scope on the importer"],
            actionItems: [DebriefActionItem(text: "Send the notes", owner: nil, due: nil)],
            openQuestions: []
        )
    }

    private func makeViewModel(
        summarizer: DebriefSummarizer,
        transcript: String = "This is the debrief of the sprint review.",
        muterRegistry: (any MuterRegistering)? = nil
    ) -> (MenuBarViewModel, FakeTranscriptionEngine) {
        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = transcript
        let viewModel = MenuBarViewModel(
            engine: engine,
            configService: configService,
            debriefSummarizer: summarizer,
            debriefStore: store,
            clipboardManager: clipboard,
            muterRegistry: muterRegistry
        )
        recordingViewModels.append(viewModel)
        return (viewModel, engine)
    }

    private func silence(seconds: Int = 1) -> [Float] {
        [Float](repeating: 0, count: 16_000 * seconds)
    }

    /// A real WAV on disk, written by the store's own writer. The pipeline
    /// copies the imported file into the session folder, so a URL that doesn't
    /// exist would fail the run before it ever reaches the summarizer.
    private func makeSourceWAV(named name: String) throws -> URL {
        let sourceStore = DebriefStore(rootDirectory: tempDir.appendingPathComponent("source-\(name)"))
        let paths = try sourceStore.createSession()
        try sourceStore.writeAudio(silence(), to: paths)
        return paths.audio
    }

    // MARK: - processAudio routing

    func test_processAudio_withDebriefModeEnabled_runsSummarizer() async {
        configService.debriefModeEnabled = true
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        await viewModel.processAudio(silence())

        XCTAssertEqual(summarizer.summarizeCallCount, 1)
        XCTAssertEqual(viewModel.lastDebriefEngineName, "Fake")
        XCTAssertFalse(viewModel.isSummarizing)
        XCTAssertNil(viewModel.debriefStatus)
        XCTAssertEqual(viewModel.appState, .idle)
    }

    func test_processAudio_withDebriefModeDisabled_runsNormalDictationPath() async {
        configService.debriefModeEnabled = false
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let transcript = "This is the debrief of the sprint review."
        let (viewModel, _) = makeViewModel(summarizer: summarizer, transcript: transcript)

        await viewModel.processAudio(silence())

        // No debrief...
        XCTAssertEqual(summarizer.summarizeCallCount, 0)
        XCTAssertNil(viewModel.lastDebriefEngineName)
        XCTAssertFalse(viewModel.isSummarizing)
        XCTAssertTrue(clipboard.pastedMultiline.isEmpty)

        // ...but the normal dictation path did run: the raw transcript went out
        // through pasteText and into history.
        XCTAssertEqual(clipboard.pastedText, [transcript])
        XCTAssertEqual(configService.history.first?.text, transcript)
        XCTAssertEqual(viewModel.appState, .idle)
    }

    func test_processAudio_withDebriefModeDisabled_silenceMarkerIsRejected() async {
        configService.debriefModeEnabled = false
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer, transcript: "[BLANK_AUDIO]")

        await viewModel.processAudio(silence())

        XCTAssertTrue(clipboard.pastedText.isEmpty, "a silence marker must never be pasted")
        XCTAssertTrue(configService.history.isEmpty)
        XCTAssertEqual(viewModel.appState, .idle)
    }

    func test_runDebrief_pastesRenderedTextAndAddsHistory() async {
        configService.debriefModeEnabled = true
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        await viewModel.processAudio(silence())

        XCTAssertEqual(clipboard.pastedMultiline.count, 1)
        XCTAssertTrue(clipboard.pastedText.isEmpty, "debrief output must not go through the newline-flattening path")
        let pasted = clipboard.pastedMultiline.first ?? ""
        XCTAssertTrue(pasted.contains("SUMMARY"), "pasted text was:\n\(pasted)")
        XCTAssertEqual(configService.history.first?.text, pasted)
    }

    func test_runDebrief_summarizerFailure_leavesViewModelIdle() async {
        configService.debriefModeEnabled = true
        let summarizer = FakeDebriefSummarizer(
            name: "Fake",
            available: true,
            result: .failure(DebriefSummarizerError.unavailable("no engine"))
        )
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        await viewModel.processAudio(silence())

        XCTAssertFalse(viewModel.isSummarizing)
        XCTAssertNil(viewModel.debriefStatus)
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertTrue(clipboard.pastedMultiline.isEmpty)
        XCTAssertNil(viewModel.lastDebriefEngineName)
    }

    // MARK: - History re-paste

    func test_pasteHistoryItem_withMultilineText_pastesViaMultilinePathOnly() {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)
        let rendered = summary().renderPlainText(language: "en")
        let item = HistoryItem(text: rendered, outputMode: .general)

        viewModel.pasteHistoryItem(item)

        XCTAssertEqual(clipboard.pastedMultiline, [rendered])
        XCTAssertTrue(clipboard.pastedText.isEmpty, "a multi-line history item must not go through the newline-flattening path")
    }

    func test_pasteHistoryItem_withSingleLineText_pastesViaPasteTextOnly() {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)
        let item = HistoryItem(text: "A short dictated note.", outputMode: .general)

        viewModel.pasteHistoryItem(item)

        XCTAssertEqual(clipboard.pastedText, ["A short dictated note."])
        XCTAssertTrue(clipboard.pastedMultiline.isEmpty)
    }

    // MARK: - Audio file import

    func test_importAudioFile_runsPipelineAndKeepsOriginal() async throws {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        // Produce a real WAV with the store's own writer, outside the session root.
        let sourceStore = DebriefStore(rootDirectory: tempDir.appendingPathComponent("source"))
        let sourcePaths = try sourceStore.createSession()
        try sourceStore.writeAudio(silence(), to: sourcePaths)

        await viewModel.importAudioFile(url: sourcePaths.audio)

        XCTAssertEqual(summarizer.summarizeCallCount, 1)
        XCTAssertFalse(viewModel.isSummarizing)

        let sessionRoot = tempDir.appendingPathComponent("sessions")
        let sessions = try FileManager.default.contentsOfDirectory(at: sessionRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(sessions.count, 1)
        let original = try XCTUnwrap(sessions.first).appendingPathComponent("original.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func test_importAudioFile_unsupportedFile_surfacesErrorWithoutSummarizing() async throws {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        let bogus = tempDir.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try "not audio".write(to: bogus, atomically: true, encoding: .utf8)

        await viewModel.importAudioFile(url: bogus)

        XCTAssertEqual(summarizer.summarizeCallCount, 0)
        XCTAssertFalse(viewModel.isSummarizing)
    }

    // MARK: - Recorder overrides

    func test_recorderOverrides_debriefMode_disablesSilenceAutoStopAndRaisesCap() {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        let debrief = viewModel.recorderOverrides(debriefEnabled: true)
        XCTAssertFalse(debrief.silenceAutoStop)
        XCTAssertEqual(debrief.maxBufferSamples, MenuBarViewModel.debriefMaxBufferSamples)
        XCTAssertEqual(debrief.maxBufferSamples, 16_000 * 60 * 120)
        XCTAssertGreaterThan(debrief.maxBufferSamples, AudioRecorder.defaultMaxBufferSamples)
    }

    func test_recorderOverrides_normalMode_matchesRecorderDefaults() {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        let normal = viewModel.recorderOverrides(debriefEnabled: false)
        XCTAssertTrue(normal.silenceAutoStop)
        XCTAssertEqual(normal.maxBufferSamples, AudioRecorder.defaultMaxBufferSamples)

        // A freshly built recorder must already be in exactly this state, so
        // normal dictation behaves identically whether or not debrief mode has
        // ever been switched on.
        let recorder = AudioRecorder()
        XCTAssertEqual(recorder.silenceAutoStopEnabled, normal.silenceAutoStop)
        XCTAssertEqual(recorder.maxBufferSamples, normal.maxBufferSamples)
    }

    // MARK: - Import concurrency

    func test_importAudioFile_claimsStateBeforeDecoding_soRecordingCannotStart() async throws {
        let sourceURL = try makeSourceWAV(named: "claim")
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = "Imported debrief."

        // Blocks the loader until the test releases it, standing in for a long
        // file decode.
        let gate = LoaderGate()
        let viewModel = MenuBarViewModel(
            engine: engine,
            configService: configService,
            debriefSummarizer: summarizer,
            debriefStore: store,
            clipboardManager: clipboard,
            audioFileLoader: { _ in
                gate.waitUntilReleased()
                return [Float](repeating: 0, count: 16_000)
            }
        )

        let importTask = Task { await viewModel.importAudioFile(url: sourceURL) }

        // Wait for the claim to land — it must happen before the decode starts.
        await waitUntil { viewModel.isSummarizing }
        XCTAssertEqual(viewModel.debriefStatus, "Loading audio…")
        XCTAssertEqual(viewModel.appState, .processing)

        // The hotkey path must refuse while the import holds the state.
        viewModel.startRecording()
        XCTAssertNotEqual(viewModel.appState, .recording, "startRecording must be refused during an import")

        gate.release()
        await importTask.value

        XCTAssertFalse(viewModel.isSummarizing)
        XCTAssertNil(viewModel.debriefStatus)
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertEqual(summarizer.summarizeCallCount, 1)
    }

    func test_importAudioFile_whileSummarizing_isRefusedAndLeavesFirstRunAlone() async throws {
        let firstURL = try makeSourceWAV(named: "first")
        let secondURL = try makeSourceWAV(named: "second")
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = "Imported debrief."

        let gate = LoaderGate()
        let viewModel = MenuBarViewModel(
            engine: engine,
            configService: configService,
            debriefSummarizer: summarizer,
            debriefStore: store,
            clipboardManager: clipboard,
            audioFileLoader: { _ in
                gate.waitUntilReleased()
                return [Float](repeating: 0, count: 16_000)
            }
        )

        let first = Task { await viewModel.importAudioFile(url: firstURL) }
        await waitUntil { viewModel.isSummarizing }

        // Second import while the first holds the claim: refused outright.
        await viewModel.importAudioFile(url: secondURL)
        XCTAssertTrue(viewModel.isSummarizing, "the refused import must not release the first run's claim")

        gate.release()
        await first.value

        XCTAssertEqual(summarizer.summarizeCallCount, 1, "only the first import should have run")
        XCTAssertFalse(viewModel.isSummarizing)
        XCTAssertEqual(viewModel.appState, .idle)
    }

    func test_importAudioFile_loadFailure_releasesState() async {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let engine = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(
            engine: engine,
            configService: configService,
            debriefSummarizer: summarizer,
            debriefStore: store,
            clipboardManager: clipboard,
            audioFileLoader: { url in throw AudioFileLoaderError.unsupportedFormat(url) }
        )

        await viewModel.importAudioFile(url: URL(fileURLWithPath: "/tmp/notes.txt"))

        XCTAssertFalse(viewModel.isSummarizing)
        XCTAssertNil(viewModel.debriefStatus)
        XCTAssertEqual(viewModel.appState, .idle, "a failed decode must not leave the app stuck in .processing")
        XCTAssertEqual(summarizer.summarizeCallCount, 0)
    }

    /// Polls the main actor until `condition` holds or the timeout elapses.
    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Engine selection

    func test_setDebriefEngine_persistsToConfig() {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        viewModel.setDebriefEngine(.heuristic)

        XCTAssertEqual(configService.debriefEngine, .heuristic)
    }

    func test_toggleDebriefMode_flipsConfig() {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        XCTAssertFalse(configService.debriefModeEnabled)
        viewModel.toggleDebriefMode()
        XCTAssertTrue(configService.debriefModeEnabled)
        viewModel.toggleDebriefMode()
        XCTAssertFalse(configService.debriefModeEnabled)
    }

    // MARK: - Debrief source

    func test_setDebriefSource_persistsToConfigAndIsReadableFromViewModel() {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        XCTAssertEqual(viewModel.debriefSource, .microphone)

        viewModel.setDebriefSource(.microphoneAndSystemAudio)

        XCTAssertEqual(configService.debriefSource, .microphoneAndSystemAudio)
        XCTAssertEqual(viewModel.debriefSource, .microphoneAndSystemAudio)
    }

    /// `selectDebriefSource` owns the one-time consent-notice decision: the
    /// menu (View) only presents the alert when this returns true, so the
    /// show-once behavior has to be correct here, not in the UI layer.
    func test_selectDebriefSource_showsConsentNoticeExactlyOnceForSystemAudio() {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        XCTAssertFalse(configService.callRecordingNoticeShown)

        let firstResult = viewModel.selectDebriefSource(.microphoneAndSystemAudio)
        XCTAssertTrue(firstResult, "the first selection of mic + system audio must ask the caller to show the notice")
        XCTAssertTrue(configService.callRecordingNoticeShown)
        XCTAssertEqual(configService.debriefSource, .microphoneAndSystemAudio)

        let secondResult = viewModel.selectDebriefSource(.microphoneAndSystemAudio)
        XCTAssertFalse(secondResult, "a later selection must not ask the caller to show the notice again")
    }

    func test_selectDebriefSource_microphoneNeverShowsConsentNotice() {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        let result = viewModel.selectDebriefSource(.microphone)

        XCTAssertFalse(result)
        XCTAssertFalse(configService.callRecordingNoticeShown)
        XCTAssertEqual(configService.debriefSource, .microphone)
    }

    // MARK: - Muter gating (source = mic + system audio must not mute other apps)

    /// Lets the fire-and-forget `Task` inside `startRecording()` run its
    /// synchronous prefix (the mute decision, before the first `await`) even
    /// though `audioRecorder.startRecording()` itself is real and will likely
    /// fail for lack of mic permission in CI — that failure happens strictly
    /// after the mute decision, so it doesn't affect what's being asserted.
    private func yieldForStartRecordingTask() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    func test_startRecording_debriefModeWithSystemAudioSource_skipsMuting() async {
        configService.debriefModeEnabled = true
        configService.debriefSource = .microphoneAndSystemAudio
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let muter = FakeMuterRegistry()
        let (viewModel, _) = makeViewModel(summarizer: summarizer, muterRegistry: muter)

        // startRecording() guards on appState == .idle, which only lands after
        // the ViewModel's own init-time Task finishes loading the (fake)
        // transcriber. Without this wait, startRecording() is a same-tick no-op
        // and the assertion below passes for the wrong reason.
        await waitUntil { viewModel.appState == .idle }
        viewModel.startRecording()
        await yieldForStartRecordingTask()

        XCTAssertEqual(muter.muteAllCallCount, 0, "debrief mode capturing system audio must not mute the user's own mic-muting apps")
    }

    func test_startRecording_debriefModeWithMicOnlySource_mutesAsNormal() async {
        configService.debriefModeEnabled = true
        configService.debriefSource = .microphone
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let muter = FakeMuterRegistry()
        let (viewModel, _) = makeViewModel(summarizer: summarizer, muterRegistry: muter)

        await waitUntil { viewModel.appState == .idle }
        viewModel.startRecording()
        await waitUntil { muter.muteAllCallCount > 0 }

        XCTAssertEqual(muter.muteAllCallCount, 1)
    }

    func test_startRecording_debriefModeDisabled_mutesAsNormalRegardlessOfSource() async {
        configService.debriefModeEnabled = false
        configService.debriefSource = .microphoneAndSystemAudio
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let muter = FakeMuterRegistry()
        let (viewModel, _) = makeViewModel(summarizer: summarizer, muterRegistry: muter)

        await waitUntil { viewModel.appState == .idle }
        viewModel.startRecording()
        await waitUntil { muter.muteAllCallCount > 0 }

        XCTAssertEqual(muter.muteAllCallCount, 1, "the gate only applies while debrief mode is on")
    }

    // MARK: - Call recording (source = mic + system audio, two tracks to disk)

    private func makeCallViewModel(
        capture: FakeSystemAudioCapture,
        summarizer: DebriefSummarizer,
        muterRegistry: (any MuterRegistering)? = nil
    ) -> (MenuBarViewModel, FakeTranscriptionEngine) {
        configService.debriefModeEnabled = true
        configService.debriefSource = .microphoneAndSystemAudio
        let engine = FakeTranscriptionEngine()
        let viewModel = MenuBarViewModel(
            engine: engine,
            configService: configService,
            debriefSummarizer: summarizer,
            debriefStore: store,
            clipboardManager: clipboard,
            muterRegistry: muterRegistry,
            systemAudioCaptureFactory: { capture }
        )
        recordingViewModels.append(viewModel)
        return (viewModel, engine)
    }

    private var sessionFolders: [URL] {
        let root = tempDir.appendingPathComponent("sessions")
        return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }

    /// Starts a call recording and waits for `.recording`. Skips the test when
    /// the machine running it has no usable microphone — the real
    /// `AudioRecorder` is used here, and nothing about the call path can be
    /// exercised if it can't start.
    private func startCallRecordingOrSkip(_ viewModel: MenuBarViewModel) async throws {
        await waitUntil { viewModel.appState == .idle }
        viewModel.startRecording()
        await waitUntil(timeout: 5) { viewModel.appState == .recording }
        try XCTSkipIf(
            viewModel.appState != .recording,
            "no usable microphone in this environment — call recording cannot start"
        )
    }

    /// Builds a call-mode ViewModel whose store can never create a session,
    /// so the very first step of `startCallRecording` fails.
    private func makeCallViewModelWithUnwritableStore(
        capture: FakeSystemAudioCapture,
        summarizer: DebriefSummarizer
    ) -> MenuBarViewModel {
        configService.debriefModeEnabled = true
        configService.debriefSource = .microphoneAndSystemAudio
        // `/dev/null` is a character device, so creating a directory under it
        // always fails — no permissions games, no machine dependence.
        let brokenStore = DebriefStore(rootDirectory: URL(fileURLWithPath: "/dev/null/dikta-sessions"))
        let viewModel = MenuBarViewModel(
            engine: FakeTranscriptionEngine(),
            configService: configService,
            debriefSummarizer: summarizer,
            debriefStore: brokenStore,
            clipboardManager: clipboard,
            systemAudioCaptureFactory: { capture }
        )
        recordingViewModels.append(viewModel)
        return viewModel
    }

    func test_startCallRecording_sessionCreationFailure_startsNothingAndStaysIdle() async throws {
        let capture = FakeSystemAudioCapture()
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let viewModel = makeCallViewModelWithUnwritableStore(capture: capture, summarizer: summarizer)

        await waitUntil { viewModel.appState == .idle }
        viewModel.startRecording()
        await yieldForStartRecordingTask()

        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertEqual(capture.startCallCount, 0, "the tap must not open when there is nowhere to write")
        XCTAssertFalse(viewModel.audioRecorder.recording)
        XCTAssertNil(viewModel.audioRecorder.onLiveSamples)
        XCTAssertTrue(sessionFolders.isEmpty)
    }

    func test_startCallRecording_secondStartWhileCaptureStartIsPending_isIgnored() async throws {
        let capture = FakeSystemAudioCapture()
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeCallViewModel(capture: capture, summarizer: summarizer)

        // Hold capture.start() open, exactly as the TCC prompt does. The app
        // is still `.idle` the whole time, so nothing but the re-entrancy
        // guard stops a second hotkey press from opening a second session.
        let gate = AsyncGate()
        capture.startGate = { await gate.wait() }

        await waitUntil { viewModel.appState == .idle }
        viewModel.startRecording()
        await waitUntil(timeout: 5) { capture.startCallCount > 0 }

        XCTAssertEqual(viewModel.appState, .idle, "still inside the permission gate")
        viewModel.startRecording()
        viewModel.hotkeyPressed(mode: .toggle)
        await yieldForStartRecordingTask()

        XCTAssertEqual(capture.startCallCount, 1, "a start already in flight must not be started again")
        XCTAssertEqual(sessionFolders.count, 1, "a second start would have created a second session folder")

        gate.open()
        await waitUntil(timeout: 5) { viewModel.appState == .recording }
        try XCTSkipIf(viewModel.appState != .recording, "no usable microphone in this environment")
        XCTAssertEqual(sessionFolders.count, 1)

        viewModel.stopRecording()
        await waitUntil(timeout: 5) { viewModel.appState == .idle }
    }

    func test_runCallDebrief_whileAnotherDebriefHoldsTheClaim_endsIdleAndKeepsTheOtherRun() async throws {
        let sourceURL = try makeSourceWAV(named: "busy")
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = "Imported debrief."

        let loaderGate = LoaderGate()
        let viewModel = MenuBarViewModel(
            engine: engine,
            configService: configService,
            debriefSummarizer: summarizer,
            debriefStore: store,
            clipboardManager: clipboard,
            audioFileLoader: { _ in
                loaderGate.waitUntilReleased()
                return [Float](repeating: 0, count: 16_000)
            }
        )
        recordingViewModels.append(viewModel)

        let importTask = Task { await viewModel.importAudioFile(url: sourceURL) }
        await waitUntil { viewModel.isSummarizing }

        // A call finishing while that import still holds the claim: refused,
        // and it must not strand the app in .processing either way.
        let paths = try store.createSession()
        viewModel.appState = .processing
        await viewModel.runCallDebrief(paths: paths)

        XCTAssertTrue(viewModel.isSummarizing, "the refused run must not release the import's claim")
        XCTAssertEqual(summarizer.summarizeCallCount, 0, "nothing should have been summarized yet")

        loaderGate.release()
        await importTask.value

        XCTAssertEqual(viewModel.appState, .idle, "the app must never be left stuck in .processing")
        XCTAssertFalse(viewModel.isSummarizing)
        XCTAssertEqual(summarizer.summarizeCallCount, 1, "only the import ran")
    }

    func test_runCallDebrief_withNothingHoldingTheClaim_neverLeavesProcessingStuck() async throws {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, engine) = makeCallViewModel(capture: FakeSystemAudioCapture(), summarizer: summarizer)
        engine.segmentsPerCall = [[TranscriptSegment(start: 0, end: 1, text: "Both sides spoke.")]]

        await waitUntil { viewModel.appState == .idle }
        let paths = try store.createSession()
        let writer = try store.makeStreamingWriter(for: .me, in: paths)
        try writer.append([Float](repeating: 0.1, count: 16_000))
        try writer.close()

        viewModel.appState = .processing
        await viewModel.runCallDebrief(paths: paths)

        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertFalse(viewModel.isSummarizing)
        XCTAssertEqual(summarizer.summarizeCallCount, 1)
    }

    func test_startCallRecording_startsSystemCaptureBeforeMicAndOpensBothWriters() async throws {
        let capture = FakeSystemAudioCapture()
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let muter = FakeMuterRegistry()
        let (viewModel, _) = makeCallViewModel(capture: capture, summarizer: summarizer, muterRegistry: muter)

        // Ordering probe: the mic must not be running yet when the system
        // capture's start() is called — it is the permission gate and can
        // block for seconds, which would offset the two tracks.
        var micWasRecordingAtCaptureStart: Bool?
        capture.onStartCalled = { [weak viewModel] in
            micWasRecordingAtCaptureStart = viewModel?.audioRecorder.recording
        }

        try await startCallRecordingOrSkip(viewModel)

        XCTAssertEqual(capture.startCallCount, 1)
        XCTAssertEqual(micWasRecordingAtCaptureStart, false, "system audio capture must start before the microphone")
        XCTAssertTrue(viewModel.audioRecorder.recording)
        XCTAssertEqual(muter.muteAllCallCount, 0, "recording a call must not mute the user's own call app")

        // One session folder with both tracks already on disk (valid,
        // zero-frame WAVs) — a crash from here on still leaves them.
        let folders = sessionFolders
        XCTAssertEqual(folders.count, 1)
        let paths = DebriefSessionPaths(folder: try XCTUnwrap(folders.first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.audioURL(for: .me).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.audioURL(for: .them).path))

        viewModel.stopRecording()
        await waitUntil(timeout: 5) { viewModel.appState == .idle }
    }

    func test_callRecording_liveSamplesLandInMeAndThemWavsAndAreTranscribedSeparately() async throws {
        let capture = FakeSystemAudioCapture()
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, engine) = makeCallViewModel(capture: capture, summarizer: summarizer)
        engine.segmentsPerCall = [
            [TranscriptSegment(start: 0, end: 1, text: "My side of the call.")],
            [TranscriptSegment(start: 2, end: 3, text: "Their side of the call.")]
        ]

        try await startCallRecordingOrSkip(viewModel)

        // Mic track: drive the recorder's live tap directly, the same closure
        // the AVAudioEngine tap callback invokes.
        let meTap = try XCTUnwrap(viewModel.audioRecorder.onLiveSamples)
        meTap([Float](repeating: 0.25, count: 16_000))
        // System audio track: through the fake capture, as the real tap does.
        capture.feed([Float](repeating: -0.25, count: 32_000))

        viewModel.stopRecording()
        await waitUntil(timeout: 5) { viewModel.appState == .idle }

        XCTAssertEqual(capture.stopCallCount, 1)
        XCTAssertFalse(viewModel.audioRecorder.recording)

        let paths = DebriefSessionPaths(folder: try XCTUnwrap(sessionFolders.first))
        let loader = AudioFileLoader()
        let me = try loader.load(url: paths.audioURL(for: .me))
        let them = try loader.load(url: paths.audioURL(for: .them))
        XCTAssertEqual(Double(me.count), 16_000, accuracy: 100)
        XCTAssertEqual(Double(them.count), 32_000, accuracy: 100)
        XCTAssertEqual(Double(me[100]), 0.25, accuracy: 0.001)
        XCTAssertEqual(Double(them[100]), -0.25, accuracy: 0.001)

        // Both tracks were transcribed and merged into one labeled transcript,
        // then pasted and recorded in History like any other debrief.
        XCTAssertEqual(engine.receivedPromptTexts.count, 2)
        let transcript = try String(contentsOf: paths.transcript, encoding: .utf8)
        XCTAssertEqual(transcript, "Me: My side of the call.\n\nThem: Their side of the call.")
        XCTAssertEqual(summarizer.summarizeCallCount, 1)
        XCTAssertEqual(clipboard.pastedMultiline.count, 1)
        XCTAssertTrue(clipboard.pastedText.isEmpty)
        XCTAssertEqual(configService.history.first?.text, clipboard.pastedMultiline.first)
        XCTAssertEqual(viewModel.lastDebriefEngineName, "Fake")
        XCTAssertFalse(viewModel.isSummarizing)
        XCTAssertNil(viewModel.debriefStatus)
    }

    func test_startCallRecording_permissionDenied_revertsToIdleWithWritersClosedAndNoMuting() async throws {
        let capture = FakeSystemAudioCapture()
        capture.errorToThrow = SystemAudioCaptureError.permissionDenied
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let muter = FakeMuterRegistry()
        let (viewModel, _) = makeCallViewModel(capture: capture, summarizer: summarizer, muterRegistry: muter)

        await waitUntil { viewModel.appState == .idle }
        viewModel.startRecording()
        await waitUntil(timeout: 5) { capture.startCallCount > 0 }
        await yieldForStartRecordingTask()

        XCTAssertEqual(viewModel.appState, .idle, "a denied tap must leave the app idle, not stuck in .recording")
        XCTAssertFalse(viewModel.audioRecorder.recording, "the microphone must never start once the tap failed")
        XCTAssertNil(viewModel.audioRecorder.onLiveSamples, "the live tap must be detached again")
        XCTAssertEqual(muter.muteAllCallCount, 0)
        XCTAssertTrue(clipboard.pastedMultiline.isEmpty)

        // The session folder is left behind, but both writers are closed: the
        // files are complete, zero-frame WAVs rather than half-open handles.
        let paths = DebriefSessionPaths(folder: try XCTUnwrap(sessionFolders.first))
        let loader = AudioFileLoader()
        XCTAssertEqual(try loader.duration(url: paths.audioURL(for: .me)), 0)
        XCTAssertEqual(try loader.duration(url: paths.audioURL(for: .them)), 0)

        // A second attempt is still possible — nothing is latched.
        XCTAssertNil(viewModel.audioRecorder.onLiveSamples)
    }

    func test_systemAudioFailureMessage_permissionDeniedNamesThePrivacyPane() {
        let denied = MenuBarViewModel.systemAudioFailureMessage(for: SystemAudioCaptureError.permissionDenied)
        XCTAssertTrue(denied.body.contains("Privacy & Security"), denied.body)
        XCTAssertTrue(denied.body.contains("System Audio Recording"), denied.body)

        let unavailable = MenuBarViewModel.systemAudioFailureMessage(
            for: SystemAudioCaptureError.unavailable(osStatus: -66748, stage: "AudioDeviceStart")
        )
        XCTAssertTrue(unavailable.body.contains("AudioDeviceStart"), "the failing stage must be named: \(unavailable.body)")
        XCTAssertFalse(unavailable.body.contains("Privacy & Security"), "a non-permission failure must not blame permissions")
    }

    func test_pushToTalk_isIgnoredWhileCallRecordingIsArmedAndRunning() async throws {
        let capture = FakeSystemAudioCapture()
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeCallViewModel(capture: capture, summarizer: summarizer)

        await waitUntil { viewModel.appState == .idle }

        // PTT must not start a call recording at all (decision 10).
        viewModel.hotkeyPressed(mode: .pushToTalk)
        await yieldForStartRecordingTask()
        XCTAssertEqual(viewModel.appState, .idle)
        XCTAssertEqual(capture.startCallCount, 0)

        // Started by the record hotkey instead...
        viewModel.hotkeyPressed(mode: .toggle)
        await waitUntil(timeout: 5) { viewModel.appState == .recording }
        try XCTSkipIf(viewModel.appState != .recording, "no usable microphone in this environment")

        // ...a PTT press and release while it runs change nothing.
        viewModel.hotkeyPressed(mode: .pushToTalk)
        viewModel.hotkeyReleased(mode: .pushToTalk)
        await yieldForStartRecordingTask()
        XCTAssertEqual(viewModel.appState, .recording, "push-to-talk must not stop a call recording")
        XCTAssertEqual(capture.stopCallCount, 0)

        // The record hotkey does stop it.
        viewModel.hotkeyPressed(mode: .toggle)
        await waitUntil(timeout: 5) { viewModel.appState == .idle }
        XCTAssertEqual(capture.stopCallCount, 1)
    }

    func test_recorderOverrides_callRecording_disablesInMemoryAccumulation() {
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeViewModel(summarizer: summarizer)

        let call = viewModel.recorderOverrides(debriefEnabled: true, callRecording: true)
        XCTAssertFalse(call.accumulateInMemory, "a two-hour call must not be held in RAM")
        XCTAssertFalse(call.silenceAutoStop)

        // Every other path is unchanged.
        XCTAssertTrue(viewModel.recorderOverrides(debriefEnabled: true).accumulateInMemory)
        XCTAssertTrue(viewModel.recorderOverrides(debriefEnabled: false).accumulateInMemory)
        XCTAssertTrue(AudioRecorder().accumulateInMemory)
    }

    /// The recorder is shared across recordings, so a call recording's
    /// "don't buffer in RAM" setting must not survive into the next normal
    /// one — which would otherwise capture, and transcribe, nothing.
    func test_startRecording_afterACallRecording_restoresInMemoryAccumulation() async throws {
        let capture = FakeSystemAudioCapture()
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary()))
        let (viewModel, _) = makeCallViewModel(capture: capture, summarizer: summarizer)

        try await startCallRecordingOrSkip(viewModel)
        XCTAssertFalse(viewModel.audioRecorder.accumulateInMemory)
        viewModel.stopRecording()
        await waitUntil(timeout: 5) { viewModel.appState == .idle }

        // Back to plain dictation on the same ViewModel and recorder.
        configService.debriefModeEnabled = false
        configService.debriefSource = .microphone
        viewModel.startRecording()
        await waitUntil(timeout: 5) { viewModel.appState == .recording }
        try XCTSkipIf(viewModel.appState != .recording, "no usable microphone in this environment")

        XCTAssertTrue(viewModel.audioRecorder.accumulateInMemory)
        XCTAssertTrue(viewModel.audioRecorder.silenceAutoStopEnabled)
        XCTAssertEqual(viewModel.audioRecorder.maxBufferSamples, AudioRecorder.defaultMaxBufferSamples)

        viewModel.stopRecording()
        await waitUntil(timeout: 5) { viewModel.appState == .idle }
    }
}
