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

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        clipboard = nil
        store = nil
        configService = nil
        tempDir = nil
        super.tearDown()
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
        transcript: String = "This is the debrief of the sprint review."
    ) -> (MenuBarViewModel, FakeTranscriptionEngine) {
        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = transcript
        let viewModel = MenuBarViewModel(
            engine: engine,
            configService: configService,
            debriefSummarizer: summarizer,
            debriefStore: store,
            clipboardManager: clipboard
        )
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
}
