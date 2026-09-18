import Foundation
import AppKit
import UserNotifications
import Combine
import ServiceManagement
import UniformTypeIdentifiers

/// State for the menu bar app
enum AppState {
    case idle
    case loading
    case recording
    case processing
    case speaking
}

/// ViewModel for the menu bar app
@MainActor
final class MenuBarViewModel: ObservableObject {
    // State
    @Published var appState: AppState = .loading
    /// Fraction (0...1) of an in-progress Whisper model download, mirrored from
    /// `transcriber.downloadProgress` while `appState == .loading`. Nil when no
    /// download is happening (bundled load, or not currently loading at all).
    @Published private(set) var downloadProgress: Double?
    static var isModelLoaded = false

    /// The model currently active in the transcription engine — the *effective*
    /// model (see `effectiveModel(for:)`), which can differ from
    /// `configService.whisperModel` (the user's raw preference) whenever Swedish
    /// is the active language. `@Published` so the Whisper Model submenu title
    /// (MenuBarView.AdvancedMenu) can show what's actually loaded, live.
    ///
    /// Nil only when every reload attempt — including the last-resort `.small`
    /// fallback in `reloadWithFallback` — has failed, so nothing is actually
    /// loaded; must never be set to a model that isn't confirmed loaded.
    @Published private(set) var loadedModel: WhisperModel?

    /// True when a language change couldn't safely reload the transcription
    /// engine (recording or processing was in flight) and is waiting for
    /// `appState` to return to `.idle`. See the `$appState` subscription below.
    private var languageModelReloadPending = false

    // Services
    let configService: ConfigService
    private var cancellables = Set<AnyCancellable>()
    private let transcriber: any TranscriptionEngine
    /// Internal rather than private so tests can drive the recorder's live
    /// sample tap (`onLiveSamples`) directly, which is the only way to feed
    /// the call-recording Me track without a real microphone.
    let audioRecorder: AudioRecorder
    /// Builds the system-audio capture used by a call recording. Injected so
    /// tests substitute `FakeSystemAudioCapture` for the real CoreAudio tap.
    private let systemAudioCaptureFactory: () -> any SystemAudioCapturing
    private let audioFeedback: AudioFeedback
    private let clipboardManager: ClipboardManager
    private let hotkeyManager: HotkeyManager
    private let ttsService: TextToSpeechService
    private let textSelectionService: TextSelectionService
    private let muterRegistry: any MuterRegistering

    // Debrief services. Injected ones win; otherwise they are built lazily —
    // the summarizer is rebuilt whenever the configured engine kind or Ollama
    // model changes, so switching engines in the menu takes effect immediately.
    private let injectedDebriefSummarizer: DebriefSummarizer?
    private var builtDebriefSummarizer: DebriefSummarizer?
    private var builtDebriefSummarizerKind: DebriefEngineKind?
    private var builtDebriefSummarizerModel: String?
    private let injectedDebriefStore: DebriefStore?
    private var builtDebriefStore: DebriefStore?

    /// Decodes an audio file to 16 kHz mono. A closure rather than the concrete
    /// `AudioFileLoader` so tests can inject a slow or failing loader and drive
    /// the state machine around it.
    private let audioFileLoader: @Sendable (URL) throws -> [Float]

    // Track which mode initiated a recording (nil when not recording)
    private var activeRecordingMode: HotkeyMode? = nil
    private var recordingStartDate: Date?
    private var activeMuteTokens: [MuteToken] = []

    // Debrief state
    /// True for the whole debrief run (transcribe → summarize → save → paste).
    @Published var isSummarizing = false
    /// Human-readable stage text shown in the menu while `isSummarizing`.
    @Published var debriefStatus: String?
    /// Name of the summarizer engine that produced the most recent debrief.
    var lastDebriefEngineName: String?

    // Hotkey recording state
    @Published var isRecordingHotkey = false
    @Published var recordingHotkeyFor: HotkeyMode?

    // Pending collision — set when a recorded hotkey conflicts with another mode
    @Published var pendingCollision: HotkeyCollision?

    struct HotkeyCollision {
        let newHotkey: HotkeyConfig
        let forMode: HotkeyMode
        let conflictingMode: HotkeyMode
    }

    // Window controllers
    let hotkeyWindowController = HotkeyRecordingWindowController()

    /// - Parameters:
    ///   - engine: Transcription engine to use. Defaults to a real WhisperKit-backed
    ///     `Transcriber` built from the saved config; tests can inject a fake instead.
    ///   - engineFactory: Alternative to `engine` for tests that need to observe which
    ///     model the engine is constructed with (a plain injected `engine` never sees
    ///     the startup model — the fake doesn't care what it's "loaded" with). Ignored
    ///     if `engine` is provided. Production never sets this; it falls through to
    ///     the real `Transcriber(model:)`.
    ///   - configService: Config store to use. Defaults to `.shared` (the real, persisted
    ///     config); tests can inject an isolated instance instead.
    ///   - debriefSummarizer: Summarizer for debrief mode. Defaults to one built lazily
    ///     from the configured engine kind; tests inject a fake so no Ollama or
    ///     Foundation Models call is ever made.
    ///   - debriefStore: Session folder writer. Defaults to `~/Documents/Dikta`; tests
    ///     inject one rooted in a temp directory.
    ///   - clipboardManager: Paste path. Defaults to the real one; tests inject a
    ///     subclass so a test run never posts Cmd+V or clobbers the clipboard.
    ///   - muterRegistry: Other-apps mic muter. Defaults to the real
    ///     `MuterRegistry`; tests inject a fake conforming to `MuterRegistering`
    ///     to assert whether `muteAll()` ran without touching real mic-muting apps.
    ///   - systemAudioCaptureFactory: Builds the system-audio capture for a call
    ///     recording. Defaults to the real `SystemAudioTapRecorder` (a CoreAudio
    ///     process tap); tests inject `FakeSystemAudioCapture` so no tap is ever
    ///     opened and no permission prompt can appear. Called once per call
    ///     recording, so each session gets a fresh capture.
    init(
        engine: (any TranscriptionEngine)? = nil,
        engineFactory: ((WhisperModel) -> any TranscriptionEngine)? = nil,
        configService: ConfigService? = nil,
        debriefSummarizer: DebriefSummarizer? = nil,
        debriefStore: DebriefStore? = nil,
        clipboardManager: ClipboardManager? = nil,
        audioFileLoader: (@Sendable (URL) throws -> [Float])? = nil,
        muterRegistry: (any MuterRegistering)? = nil,
        systemAudioCaptureFactory: (() -> any SystemAudioCapturing)? = nil
    ) {
        let configService = configService ?? .shared
        self.configService = configService
        self.injectedDebriefSummarizer = debriefSummarizer
        self.injectedDebriefStore = debriefStore
        self.audioFileLoader = audioFileLoader ?? { try AudioFileLoader().load(url: $0) }
        let preferenceModel = WhisperModel(rawValue: configService.whisperModel) ?? .small
        let startupModel = Self.effectiveModel(for: configService.language, preference: preferenceModel)
        self.loadedModel = startupModel
        self.transcriber = engine ?? engineFactory?(startupModel) ?? {
            // A `MenuBarViewModel` built without an injected engine while XCTest is
            // linked into this process (a unit test, or `Dikta.app` itself hosting
            // one — see `DiktaApp`) would fall through to a real `Transcriber` here
            // and attempt a live WhisperKit model download/network call as a side
            // effect of the app merely launching. That's silent and harmless on a
            // machine with the model already cached, but hangs or crashes the test
            // host on a clean CI runner. Fail loudly instead of downloading.
            assert(
                !Self.isRunningUnderXCTestHost,
                "MenuBarViewModel() constructed under XCTest without engine:/engineFactory: — this would build a real, network-touching Transcriber. Inject a fake engine."
            )
            return Transcriber(model: startupModel)
        }()
        self.audioRecorder = AudioRecorder()
        self.systemAudioCaptureFactory = systemAudioCaptureFactory ?? { SystemAudioTapRecorder() }
        self.audioFeedback = AudioFeedback()
        let resolvedClipboardManager = clipboardManager ?? ClipboardManager()
        self.clipboardManager = resolvedClipboardManager
        self.hotkeyManager = HotkeyManager()
        self.ttsService = TextToSpeechService()
        self.textSelectionService = TextSelectionService(clipboardManager: resolvedClipboardManager)
        self.muterRegistry = muterRegistry ?? MuterRegistry()

        // Sync mute state from config
        audioFeedback.isMuted = configService.muteSounds

        // Set up hotkey delegate
        hotkeyManager.delegate = self

        // Update hotkey configs (dictation + TTS)
        updateHotkeyConfig()

        // Forward ConfigService changes to trigger view updates
        configService.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Run a deferred language-driven model reload as soon as the app is
        // idle again (see `reloadForCurrentLanguageIfNeeded`).
        $appState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, state == .idle, self.languageModelReloadPending else { return }
                self.reloadForCurrentLanguageIfNeeded()
            }
            .store(in: &cancellables)

        // Start initialization automatically
        Task { @MainActor in
            await self.requestNotificationPermissions()
            await self.initialize()
        }
    }

    /// Runs `work` (a `load()`/`reload(model:)` call on `transcriber`) while
    /// mirroring `transcriber.downloadProgress` into `downloadProgress` on a
    /// short poll, so a menu re-render picks up the current download
    /// percentage. Polling (rather than a Combine subscription) is used
    /// because engines are held as `any TranscriptionEngine` for
    /// testability, which doesn't expose a publisher. Always resets
    /// `downloadProgress` to nil when `work` finishes, success or not.
    private func withDownloadProgressPolling<T>(_ work: () async throws -> T) async rethrows -> T {
        let pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.downloadProgress = self?.transcriber.downloadProgress
                try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
            }
        }
        defer {
            pollingTask.cancel()
            downloadProgress = nil
        }
        return try await work()
    }

    /// Initialize the app (load models, check permissions, etc.)
    func initialize() async {
        appState = .loading

        // Real-app-only side effects: showing a window, prompting for mic access,
        // and grabbing global hotkeys don't belong in (and can crash or hang) a
        // unit test process that constructs a MenuBarViewModel directly.
        if !isRunningUnderXCTest {
            // Always show onboarding on app start
            OnboardingWindowController.shared.show()

            // Now request mic permission (shows system dialog if not determined)
            let hasMicPermission = await AudioRecorder.checkPermission()
            if !hasMicPermission {
                sendNotification(title: "Permission Required", body: "Please grant Microphone access in System Preferences")
            }
        }

        // Load Whisper model
        await withDownloadProgressPolling {
            await transcriber.load()
        }

        if transcriber.isReady {
            appState = .idle

            // Notify About window that model is ready
            Self.isModelLoaded = true
            NotificationCenter.default.post(name: .appModelLoaded, object: nil)

            if !isRunningUnderXCTest {
                // Start hotkey listener
                hotkeyManager.start()
            }

            let toggleHotkey = configService.getHotkey(for: .toggle).displayString
            sendNotification(title: "Ready", body: "Whisper model loaded. Use \(toggleHotkey) to record.", isRoutine: true)
        } else {
            sendNotification(title: "Error", body: transcriber.errorMessage ?? "Failed to load model")
        }
    }

    /// Toggle recording state
    func toggleRecording() {
        if appState == .recording {
            stopRecording()
        } else if appState == .idle {
            startRecording()
        }
    }

    /// Start recording
    func startRecording() {
        guard appState == .idle else { return }

        // A call debrief captures two tracks straight to disk and has its own
        // start sequence; everything below is the single-track mic path.
        if isCallRecordingMode {
            startCallRecording()
            return
        }

        // Debrief mode records until the user stops it: no silence auto-stop,
        // and a 2-hour cap instead of the 5-minute dictation cap.
        let overrides = recorderOverrides(debriefEnabled: configService.debriefModeEnabled)
        audioRecorder.silenceAutoStopEnabled = overrides.silenceAutoStop
        audioRecorder.maxBufferSamples = overrides.maxBufferSamples
        // Always reapplied, not just when false: a previous call recording
        // turned this off on the same recorder, and a mic recording that
        // doesn't turn it back on would capture nothing at all.
        audioRecorder.accumulateInMemory = overrides.accumulateInMemory

        // A mic-only debrief now runs on the same live machinery a call does:
        // audio streams to `audio.wav` and into the chunker as it is captured,
        // so a long debrief is crash-safe and its chunks are transcribed while
        // the user is still talking. Anything under one chunk still takes the
        // single-pass path at the end, unchanged. A failure here is not fatal:
        // the debrief simply falls back to the in-RAM `processAudio` path.
        if configService.debriefModeEnabled, !isCallRecordingMode {
            do {
                let paths = try debriefStore.createSession()
                let session = MicDebriefSession(
                    paths: paths,
                    writer: try debriefStore.makeStreamingAudioWriter(in: paths),
                    live: try makeDebriefPipeline().startLiveSession(
                        tracks: [.me],
                        language: configService.language.whisperCode,
                        micSensitivity: configService.micSensitivity,
                        paths: paths
                    )
                )
                activeMicDebriefSession = session
                audioRecorder.accumulateInMemory = false
                audioRecorder.onLiveSamples = { [weak session] samples in
                    session?.append(samples)
                }
            } catch {
                activeMicDebriefSession = nil
                audioRecorder.onLiveSamples = nil
                AppLogger.audio.error("Mic debrief: could not open a live session (\(error.localizedDescription)); falling back to the in-RAM path")
                DiagnosticLogger.shared.log("DEBRIEF_LIVE | start_failed | \(error.localizedDescription)")
            }
        }

        // Set up silence auto-stop: when 10s of silence is detected, stop and process audio
        audioRecorder.onSilenceAutoStop = { [weak self] samples in
            guard let self, self.appState == .recording else { return }
            AppLogger.audio.info("Silence auto-stop triggered after 10s of silence")
            self.activeRecordingMode = nil
            // Stop the engine and discard its result (we already have the samples)
            _ = self.audioRecorder.stopRecording()
            self.unmuteMicTargets()
            self.appState = .processing
            Task {
                await self.processAudio(samples)
            }
        }

        Task {
            // Muting other apps' mics protects dictation from bleeding into a
            // call app's own input, but debrief mode capturing system audio is
            // recording that call itself — muting would silence the user in
            // their own meeting. That case never reaches here (it is routed to
            // `startCallRecording`, which takes no mute tokens); the guard is
            // kept so the rule survives if that routing ever changes.
            let muteTokens = isCallRecordingMode ? [] : muterRegistry.muteAll()
            activeMuteTokens = muteTokens

            do {
                try await audioRecorder.startRecording(micSensitivity: configService.micSensitivity)
                recordingStartDate = Date()
                appState = .recording
                audioFeedback.beepOn()
                DiagnosticLogger.shared.log("START | mic=\(configService.micSensitivity.displayName) | rate=\(audioRecorder.inputSampleRate)Hz")
            } catch {
                unmuteMicTargets()
                // `startRecording()` threw, so no tap was installed and
                // `onLiveSamples` cannot be firing — the mic debrief session
                // opened above can be torn down directly.
                if let micSession = activeMicDebriefSession {
                    activeMicDebriefSession = nil
                    audioRecorder.onLiveSamples = nil
                    micSession.close()
                }
                sendNotification(title: "Error", body: "Failed to start recording: \(error.localizedDescription)")
                DiagnosticLogger.shared.log("START_FAILED | \(error.localizedDescription)")
            }
        }
    }

    /// Stop recording and process
    func stopRecording() {
        guard appState == .recording else { return }

        if let session = activeCallSession {
            stopCallRecording(session)
            return
        }

        activeRecordingMode = nil
        audioRecorder.onSilenceAutoStop = nil
        let audioSamples = audioRecorder.stopRecording()
        unmuteMicTargets()
        appState = .processing

        // A mic-only debrief captured nothing in RAM (`accumulateInMemory` was
        // off): its audio went to disk and into the chunker, so it finishes
        // through the live session rather than `processAudio`.
        if let micSession = activeMicDebriefSession {
            activeMicDebriefSession = nil
            audioRecorder.onLiveSamples = nil
            micSession.close()

            // `processAudio` owns this line on every other path, and this path
            // never reaches it. Same fields, same order, so one grep still
            // finds every recording. `samples` and `rms` are "n/a": nothing was
            // accumulated in RAM to count or measure, and the frame count the
            // writer holds would report what reached DISK, which is a different
            // quantity from what the recorder captured.
            let duration = recordingStartDate.map { Date().timeIntervalSince($0) } ?? 0
            DiagnosticLogger.shared.log(
                "AUDIO | dur=\(String(format: "%.1f", duration))s | samples=n/a | rms=n/a"
                + " | routeChanges=\(audioRecorder.routeChangeCount)"
                + " | converterErrors=\(audioRecorder.converterErrorCount)"
                + " | emptyBuffers=\(audioRecorder.emptyBufferCount)"
            )
            recordingStartDate = nil

            let live = micSession.live
            Task {
                await runLiveDebrief(live)
            }
            return
        }

        Task {
            await processAudio(audioSamples)
        }
    }

    /// Timeout for transcription (seconds)
    private static let transcriptionTimeout: UInt64 = 60

    /// Internal rather than private so tests can drive the post-recording path
    /// directly without faking a live microphone.
    func processAudio(_ samples: [Float]) async {
        // Diagnostic: log audio buffer stats
        let duration = recordingStartDate.map { Date().timeIntervalSince($0) } ?? 0
        let bufferRMS: Float = samples.isEmpty ? 0 :
            (samples.reduce(0.0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        DiagnosticLogger.shared.log(
            "AUDIO | dur=\(String(format: "%.1f", duration))s | samples=\(samples.count) | rms=\(String(format: "%.6f", bufferRMS))"
            + " | routeChanges=\(audioRecorder.routeChangeCount) | converterErrors=\(audioRecorder.converterErrorCount) | emptyBuffers=\(audioRecorder.emptyBufferCount)"
        )
        recordingStartDate = nil

        // Debrief mode replaces the whole dictation path: longer transcription
        // timeout, a summarization step, and a multi-line paste.
        if configService.debriefModeEnabled {
            await runDebrief(samples: samples, originalFile: nil)
            return
        }

        do {
            // Transcribe with a 60-second timeout to prevent hanging
            let language = configService.language
            let micSensitivity = configService.micSensitivity

            // Diagnostic: log memory before transcription
            if let memBefore = memoryFootprintMB() {
                AppLogger.transcription.info("Memory before transcription: \(String(format: "%.1f", memBefore)) MB")
            }

            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await self.transcriber.transcribe(samples, language: language.whisperCode, micSensitivity: micSensitivity)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: MenuBarViewModel.transcriptionTimeout * 1_000_000_000)
                    throw TranscriptionTimeoutError()
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }

            // Diagnostic: log memory after transcription
            if let memAfter = memoryFootprintMB() {
                AppLogger.transcription.info("Memory after transcription: \(String(format: "%.1f", memAfter)) MB")
            }

            // Check for silence/empty output from Whisper (same rules the
            // debrief pipeline applies — see TranscriptSanitizer)
            if TranscriptSanitizer.isEffectivelyEmpty(text) {
                let matchedIndicator = TranscriptSanitizer.matchedSilenceIndicator(text)
                let reason = matchedIndicator.map { "matched=\"\($0)\"" } ?? "empty text"
                DiagnosticLogger.shared.log("RESULT | no_speech (\(reason)) | text=\"\(text)\"")
                sendNotification(
                    title: "No Speech",
                    body: "No speech detected. Try adjusting Mic Sensitivity in Audio settings."
                )
                appState = .idle
                return
            }

            DiagnosticLogger.shared.log("RESULT | pasted | chars=\(text.count)")
            await outputText(text)
            appState = .idle

        } catch is TranscriptionTimeoutError {
            DiagnosticLogger.shared.log("RESULT | timeout")
            sendNotification(title: "Transcription Timeout", body: "Processing took too long and was cancelled.")
            appState = .idle
        } catch is TranscriberError {
            DiagnosticLogger.shared.log("RESULT | no_speech (TranscriberError)")
            sendNotification(
                title: "No Speech",
                body: "No speech detected. Try adjusting Mic Sensitivity in Audio settings."
            )
            appState = .idle
        } catch {
            DiagnosticLogger.shared.log("RESULT | error | \(error.localizedDescription)")
            sendNotification(title: "Error", body: error.localizedDescription)
            appState = .idle
        }
    }

    private func outputText(_ text: String) async {
        // Add to history
        configService.addHistoryItem(text: text)

        // Paste text
        paste(text)

        // Beep and notify
        audioFeedback.beepOff()

        let preview = text.count > 50 ? String(text.prefix(50)) + "..." : text
        sendNotification(title: "Pasted", body: preview, isRoutine: true)
    }

    /// Routes `text` through `pasteMultiline` when it contains a newline,
    /// preserving structure (e.g. a re-pasted, rendered debrief summary);
    /// otherwise through `pasteText`, whose keystroke simulation flattens
    /// newlines to spaces.
    private func paste(_ text: String) {
        if text.contains("\n") || text.contains("\r") {
            clipboardManager.pasteMultiline(text)
        } else {
            clipboardManager.pasteText(text)
        }
    }

    /// Paste a history item
    func pasteHistoryItem(_ item: HistoryItem) {
        paste(item.text)
    }

    // MARK: - Debrief Mode

    /// The summarizer used for the next debrief. An injected one (tests) always
    /// wins; otherwise one is built from config and cached until the configured
    /// engine kind or Ollama model changes.
    private var debriefSummarizer: DebriefSummarizer {
        if let injectedDebriefSummarizer { return injectedDebriefSummarizer }

        let kind = configService.debriefEngine
        let model = configService.ollamaModel
        if let built = builtDebriefSummarizer,
           builtDebriefSummarizerKind == kind,
           builtDebriefSummarizerModel == model {
            return built
        }

        let summarizer = DebriefSummarizerFactory.make(kind: kind, ollamaModel: model)
        builtDebriefSummarizer = summarizer
        builtDebriefSummarizerKind = kind
        builtDebriefSummarizerModel = model
        return summarizer
    }

    private var debriefStore: DebriefStore {
        if let injectedDebriefStore { return injectedDebriefStore }
        if let builtDebriefStore { return builtDebriefStore }
        let store = DebriefStore()
        builtDebriefStore = store
        return store
    }

    /// Flipping debrief mode decides which machinery a recording runs on, and
    /// that decision is made once, at `startRecording`. Toggling it while a
    /// recording or a debrief run is in flight would leave a live session
    /// capturing while the app believes it is dictating (or the reverse), so
    /// the toggle is ignored in those two states.
    ///
    /// `.loading` is deliberately NOT blocked: the app starts there and stays
    /// there until the Whisper model finishes loading, and the menu has always
    /// been usable during that wait. Nothing is capturing then, so there is no
    /// decision to contradict.
    func toggleDebriefMode() {
        guard appState != .recording, appState != .processing else {
            AppLogger.general.info("Debrief mode toggle ignored: a recording or debrief is in progress")
            return
        }
        configService.debriefModeEnabled.toggle()
    }

    func setDebriefEngine(_ kind: DebriefEngineKind) {
        configService.debriefEngine = kind
    }

    /// Current debrief audio source, forwarded from config. Readable here (in
    /// addition to `configService.debriefSource`) so callers — and tests —
    /// don't need to reach through to the config store just to check it.
    var debriefSource: DebriefSource {
        configService.debriefSource
    }

    func setDebriefSource(_ source: DebriefSource) {
        configService.debriefSource = source
    }

    /// Selects `source` (persisting it, same as `setDebriefSource`) and owns
    /// the one-time "Recording call audio" consent decision: returns true
    /// exactly once, the first time `.microphoneAndSystemAudio` is chosen
    /// while `callRecordingNoticeShown` is still false, and flips that flag
    /// before returning. The caller (the Source menu) is only responsible for
    /// presenting the alert when this returns true — it owns no state itself.
    @discardableResult
    func selectDebriefSource(_ source: DebriefSource) -> Bool {
        let shouldShowNotice = source == .microphoneAndSystemAudio && !configService.callRecordingNoticeShown
        if shouldShowNotice {
            configService.callRecordingNoticeShown = true
        }
        setDebriefSource(source)
        return shouldShowNotice
    }

    /// The recorder settings one recording runs with.
    struct RecorderOverrides {
        let silenceAutoStop: Bool
        let maxBufferSamples: Int
        /// False only for a call recording, which streams both tracks to disk
        /// and must not also hold hours of audio in RAM.
        let accumulateInMemory: Bool
    }

    /// The recorder settings the next recording runs with. Pure so it can be
    /// tested without a microphone; `startRecording`/`startCallRecording` are
    /// its only callers.
    func recorderOverrides(debriefEnabled: Bool, callRecording: Bool = false) -> RecorderOverrides {
        guard debriefEnabled else {
            return RecorderOverrides(
                silenceAutoStop: true,
                maxBufferSamples: AudioRecorder.defaultMaxBufferSamples,
                accumulateInMemory: true
            )
        }
        return RecorderOverrides(
            silenceAutoStop: false,
            maxBufferSamples: Self.debriefMaxBufferSamples,
            accumulateInMemory: !callRecording
        )
    }

    /// Two hours at 16 kHz. A debrief is minutes, not hours; this is a runaway
    /// guard, not an expected limit.
    static let debriefMaxBufferSamples: Int = 16_000 * 60 * 120

    // MARK: - Mic-only debrief (live)

    /// The live half of a mic-only debrief: one streaming `audio.wav` writer
    /// and the live transcription session, both fed from one serial queue.
    ///
    /// Same discipline as `CallRecordingSession`: `StreamingWavWriter` is not
    /// thread-safe and its auto-flush `fsync`s, which must never happen on the
    /// AVAudioEngine tap thread (`onLiveSamples` runs there, under
    /// `bufferLock`). So the tap only copies its buffer and hands it here.
    private final class MicDebriefSession: @unchecked Sendable {
        let paths: DebriefSessionPaths
        let live: DebriefLiveSession
        private let writer: StreamingWavWriter
        private let queue = DispatchQueue(label: "com.duadigital.dikta.micdebrief", qos: .utility)
        private var loggedFailure = false

        init(paths: DebriefSessionPaths, writer: StreamingWavWriter, live: DebriefLiveSession) {
            self.paths = paths
            self.writer = writer
            self.live = live
        }

        func append(_ samples: [Float]) {
            guard !samples.isEmpty else { return }
            queue.async {
                self.live.append(samples, track: .me)
                do {
                    try self.writer.append(samples)
                } catch {
                    guard !self.loggedFailure else { return }
                    self.loggedFailure = true
                    AppLogger.audio.error("Mic debrief: writing audio.wav failed: \(error.localizedDescription) — the recording on disk stops here")
                }
            }
        }

        /// Drains the queue before closing, so every handed-off buffer is
        /// written (and appended to the chunker) first.
        func close() {
            queue.sync {
                do {
                    try writer.close()
                } catch {
                    AppLogger.audio.error("Mic debrief: closing audio.wav failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Non-nil for exactly as long as a mic-only debrief is capturing.
    private var activeMicDebriefSession: MicDebriefSession?

    // MARK: - Call recording (debrief, source = microphone + system audio)

    /// True when the next/current recording is a call: two tracks, streamed
    /// to disk, merged into a labeled transcript at stop.
    var isCallRecordingMode: Bool {
        configService.debriefModeEnabled && configService.debriefSource == .microphoneAndSystemAudio
    }

    /// Non-nil for exactly as long as a call recording is capturing. Retained
    /// on the ViewModel (not just inside the start closure) so stop can reach
    /// the writers and the session folder, and so the two WAVs on disk
    /// survive a crash during processing.
    private var activeCallSession: CallRecordingSession?

    /// True from the moment a call start begins until it has either reached
    /// `.recording` or failed. `appState` alone can't stand in for this: the
    /// system-audio `start()` blocks while the TCC prompt is on screen, and
    /// the app is still `.idle` throughout — so a second hotkey press would
    /// otherwise open a second session folder, writers and tap.
    private var isStartingCallRecording = false

    /// The live half of a call recording: the session folder plus one
    /// streaming WAV writer per track, each with its own serial queue.
    ///
    /// `StreamingWavWriter` is not thread-safe and writing to it means real
    /// disk I/O (including an `fsync` on every auto-flush), which must never
    /// happen on the AVAudioEngine tap thread or the capture's delivery
    /// queue — both are audio-rate callbacks. So each producer callback only
    /// copies its buffer and hands it to that track's `Track` below; every
    /// touch of a writer — `append`, its failure bookkeeping, and `close` —
    /// then happens on that one serial queue and nowhere else.
    ///
    /// `closeWriters()` is called from the main actor after both producers
    /// have been stopped; it drains each track's queue (`sync {}`) before
    /// closing that track's writer, so no append can still be in flight.
    /// Hence `@unchecked Sendable`: every mutable field below is confined to
    /// its own track's queue, and the immutable ones are read-only.
    private final class CallRecordingSession: @unchecked Sendable {
        let paths: DebriefSessionPaths
        let capture: any SystemAudioCapturing
        /// The live transcription/summarization session this recording feeds.
        /// Fed from the *same* per-track queue as the writer, so the chunker
        /// sees each track's buffers in exactly the order they were captured.
        let live: DebriefLiveSession

        /// One writer plus the serial queue that exclusively owns it.
        private final class Track: @unchecked Sendable {
            let writer: StreamingWavWriter
            let queue: DispatchQueue
            let name: DebriefTrack
            /// Only ever read/written on `queue` — one log line per track
            /// even if every buffer fails.
            var loggedFailure = false

            init(writer: StreamingWavWriter, name: DebriefTrack) {
                self.writer = writer
                self.name = name
                self.queue = DispatchQueue(
                    label: "com.duadigital.dikta.callrecording.\(name.rawValue)",
                    qos: .utility
                )
            }
        }

        private let me: Track
        private let them: Track

        init(
            paths: DebriefSessionPaths,
            me: StreamingWavWriter,
            them: StreamingWavWriter,
            capture: any SystemAudioCapturing,
            live: DebriefLiveSession
        ) {
            self.paths = paths
            self.me = Track(writer: me, name: .me)
            self.them = Track(writer: them, name: .them)
            self.capture = capture
            self.live = live
        }

        func appendMe(_ samples: [Float]) { append(samples, to: me) }
        func appendThem(_ samples: [Float]) { append(samples, to: them) }

        /// Returns immediately: the caller is an audio callback, so the write
        /// is handed to the track's own queue rather than performed inline.
        private func append(_ samples: [Float], to track: Track) {
            guard !samples.isEmpty else { return }
            track.queue.async {
                // The chunker first, then disk: `append` only hands the buffer
                // to the chunker's own queue and returns, so transcription is
                // never delayed by this track's disk write — and a write that
                // throws still leaves the audio transcribed. The ordering the
                // chunker depends on ("sample index is time") is this queue's.
                self.live.append(samples, track: track.name)
                do {
                    try track.writer.append(samples)
                } catch {
                    // A failed write must not kill capture of the other
                    // track: the writer latches its own failure and the file
                    // stays valid up to the last flush, so the call still
                    // produces a usable (if truncated) track.
                    guard !track.loggedFailure else { return }
                    track.loggedFailure = true
                    AppLogger.audio.error("Call recording: writing \(track.name.rawValue).wav failed: \(error.localizedDescription) — that track stops here")
                }
            }
        }

        /// Best-effort close of both writers, leaving valid WAV headers.
        /// Drains each track's queue first so every already-handed-off buffer
        /// is written before its writer closes.
        func closeWriters() {
            for track in [me, them] {
                track.queue.sync {
                    do {
                        try track.writer.close()
                    } catch {
                        AppLogger.audio.error("Call recording: closing \(track.name.rawValue).wav failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Starts a two-track call recording: session folder and both writers
    /// first, then the system-audio capture, then the microphone.
    ///
    /// The system capture goes first on purpose. Its `start()` is the
    /// permission gate and can block for seconds while the TCC prompt is on
    /// screen; starting the mic first would leave it recording (and the Me
    /// track filling) throughout that wait, and the merger treats each
    /// track's sample index as time, so the two tracks would be offset by the
    /// whole prompt duration. Starting it second keeps both producers within
    /// a few milliseconds of each other — and if the capture fails, nothing
    /// else has been started yet.
    private func startCallRecording() {
        guard !isStartingCallRecording else { return }
        isStartingCallRecording = true

        let overrides = recorderOverrides(debriefEnabled: true, callRecording: true)
        audioRecorder.silenceAutoStopEnabled = overrides.silenceAutoStop
        audioRecorder.maxBufferSamples = overrides.maxBufferSamples
        audioRecorder.accumulateInMemory = overrides.accumulateInMemory
        // Nothing is buffered in RAM, so there is no captured audio for an
        // auto-stop callback to hand over. The user stops a call themselves.
        audioRecorder.onSilenceAutoStop = nil

        Task {
            defer { isStartingCallRecording = false }

            // No muteAll: this recording *is* the user's call, and muting
            // their mic-muting apps would silence them in it (same gate as
            // the single-track debrief path).
            activeMuteTokens = []

            let session: CallRecordingSession
            do {
                let paths = try debriefStore.createSession()
                // Built before either producer starts: the chunker must exist
                // (and the Whisper model for the current language must already
                // be loaded — see `reloadForCurrentLanguageIfNeeded`, which
                // runs on language change while the app is idle) before the
                // first buffer arrives.
                let pipeline = makeDebriefPipeline()
                session = CallRecordingSession(
                    paths: paths,
                    me: try debriefStore.makeStreamingWriter(for: .me, in: paths),
                    them: try debriefStore.makeStreamingWriter(for: .them, in: paths),
                    capture: systemAudioCaptureFactory(),
                    live: try pipeline.startLiveSession(
                        tracks: [.me, .them],
                        language: configService.language.whisperCode,
                        micSensitivity: configService.micSensitivity,
                        paths: paths
                    )
                )
            } catch {
                DiagnosticLogger.shared.log("CALL_START_FAILED | session | \(error.localizedDescription)")
                sendNotification(title: "Could Not Start Recording", body: error.localizedDescription)
                appState = .idle
                return
            }

            // Each writer is fed by exactly one producer, from that
            // producer's own thread — see CallRecordingSession.
            session.capture.onSamples = { [weak session] samples in
                session?.appendThem(samples)
            }
            audioRecorder.onLiveSamples = { [weak session] samples in
                session?.appendMe(samples)
            }

            do {
                try await session.capture.start()
            } catch {
                // Detaching both callbacks here needs no lock: the mic was
                // never started, so no tap is installed and `onLiveSamples`
                // cannot be firing (the `bufferLock` discipline documented on
                // it only governs a *running* recorder), and `capture.stop()`
                // orders itself against its own delivery queue.
                audioRecorder.onLiveSamples = nil
                session.capture.onSamples = nil
                session.capture.stop()
                session.closeWriters()
                let message = Self.systemAudioFailureMessage(for: error)
                DiagnosticLogger.shared.log("CALL_START_FAILED | systemAudio | \(error.localizedDescription)")
                sendNotification(title: message.title, body: message.body)
                appState = .idle
                return
            }

            do {
                try await audioRecorder.startRecording(micSensitivity: configService.micSensitivity)
            } catch {
                session.capture.stop()
                session.capture.onSamples = nil
                // `startRecording()` threw, so the recorder is not running and
                // installed no tap — clearing the live tap directly is safe
                // for the same reason as the branch above. `stopRecording()`
                // would be a no-op here (it guards on `isRecording`).
                _ = audioRecorder.stopRecording()
                audioRecorder.onLiveSamples = nil
                session.closeWriters()
                DiagnosticLogger.shared.log("CALL_START_FAILED | mic | \(error.localizedDescription)")
                sendNotification(title: "Error", body: "Failed to start recording: \(error.localizedDescription)")
                appState = .idle
                return
            }

            activeCallSession = session
            recordingStartDate = Date()
            appState = .recording
            audioFeedback.beepOn()
            DiagnosticLogger.shared.log(
                "CALL_START | mic=\(configService.micSensitivity.displayName) | rate=\(audioRecorder.inputSampleRate)Hz"
                + " | folder=\(session.paths.folder.lastPathComponent)"
            )
        }
    }

    /// Stops both producers — system capture first, then the microphone, each
    /// of which guarantees no further sample delivery once it returns — then
    /// closes both writers and hands the session folder to the pipeline.
    private func stopCallRecording(_ session: CallRecordingSession) {
        activeCallSession = nil
        activeRecordingMode = nil
        audioRecorder.onSilenceAutoStop = nil

        session.capture.stop()
        session.capture.onSamples = nil
        _ = audioRecorder.stopRecording()
        audioRecorder.onLiveSamples = nil
        session.closeWriters()

        unmuteMicTargets()
        recordingStartDate = nil
        appState = .processing

        let live = session.live
        Task {
            await runLiveDebrief(live)
        }
    }

    /// Title/body for a system-audio capture failure. The permission case
    /// names the exact System Settings pane, since a denied tap is invisible
    /// otherwise — macOS shows no recording indicator for a process tap.
    /// Pure and static so the wording is unit-testable.
    nonisolated static func systemAudioFailureMessage(for error: Error) -> (title: String, body: String) {
        guard let captureError = error as? SystemAudioCaptureError else {
            return ("System Audio Unavailable", error.localizedDescription)
        }
        switch captureError {
        case .permissionDenied:
            return (
                "System Audio Permission Needed",
                "Dikta can't record the other side of the call. Allow it in System Settings → Privacy & Security → "
                + "Screen & System Audio Recording (\"System Audio Recording Only\" on macOS 14), then start the recording again."
            )
        case .unavailable(let osStatus, let stage):
            return (
                "System Audio Unavailable",
                "Could not start system audio capture at \(stage) (OSStatus \(osStatus)). Recording was cancelled."
            )
        case .alreadyRunning:
            return (
                "System Audio Unavailable",
                "System audio capture is already running. Recording was cancelled."
            )
        }
    }

    /// The pipeline every debrief run uses. Built fresh per run (it is
    /// stateless) but always from the same three config-driven pieces: the
    /// loaded Whisper engine, the single-pass summarizer for short
    /// recordings, and the delta engine a live session's rolling summarizer
    /// runs on — the latter selected by exactly the same config values as the
    /// former, so the two can never drift apart.
    private func makeDebriefPipeline() -> DebriefPipeline {
        let kind = configService.debriefEngine
        let model = configService.ollamaModel
        return DebriefPipeline(
            engine: transcriber,
            summarizer: debriefSummarizer,
            store: debriefStore,
            makeDeltaSummarizer: { DeltaSummarizerFactory.make(kind: kind, ollamaModel: model) }
        )
    }

    /// Finishes a live session (call or mic) and reports the result exactly
    /// like any other debrief. The transcription of everything but the last
    /// chunk already happened during the recording, so this is the "~1 minute
    /// after a 1 h meeting" path.
    private func runLiveDebrief(_ live: DebriefLiveSession) async {
        guard claimDebrief(status: "Transcribing…") else {
            sendNotification(title: "Debrief Busy", body: "Debrief already in progress.")
            releaseUnclaimedProcessingState()
            return
        }
        defer { releaseDebrief() }

        do {
            let result = try await live.finish(
                onStage: { [weak self] stage in self?.applyDebriefStage(stage) }
            )
            reportDebriefSuccess(result)
        } catch {
            reportDebriefFailure(error)
        }
    }

    /// Runs the two-track pipeline over a finished call session on disk.
    ///
    /// The live path (`runLiveDebrief`) handles a call as it is recorded; this
    /// re-runs one whose `me.wav`/`them.wav` are already on disk — a session
    /// the app crashed during, replayed through "Load audio file".
    func runCallDebrief(paths: DebriefSessionPaths) async {
        guard claimDebrief(status: "Transcribing…") else {
            sendNotification(title: "Debrief Busy", body: "Debrief already in progress.")
            releaseUnclaimedProcessingState()
            return
        }
        defer { releaseDebrief() }

        let pipeline = makeDebriefPipeline()

        do {
            let result = try await pipeline.runTwoTrack(
                paths: paths,
                language: configService.language.whisperCode,
                micSensitivity: configService.micSensitivity,
                onStage: { [weak self] stage in self?.applyDebriefStage(stage) }
            )
            reportDebriefSuccess(result)
        } catch {
            reportDebriefFailure(error)
        }
    }

    /// Takes ownership of the debrief UI state, or returns false when another
    /// debrief already holds it. Claim and release are split out because
    /// `importAudioFile` must claim *before* it starts decoding a file, which
    /// happens well before there are any samples to hand `runDebrief`.
    private func claimDebrief(status: String) -> Bool {
        guard !isSummarizing else { return false }
        isSummarizing = true
        debriefStatus = status
        appState = .processing
        return true
    }

    /// Called when a debrief run was refused the claim. The caller had
    /// already moved the app to `.processing` (stop → process), so it must
    /// not just return: if a debrief really does hold the claim, that run
    /// owns `.processing` and its own `releaseDebrief()` will return the app
    /// to `.idle`; but if nothing holds it, `.processing` would stick
    /// forever with no recording and no run to clear it. Only that second
    /// case is corrected here, so this can never fight the real owner.
    private func releaseUnclaimedProcessingState() {
        guard !isSummarizing, appState == .processing else { return }
        appState = .idle
    }

    private func releaseDebrief() {
        isSummarizing = false
        debriefStatus = nil
        appState = .idle
    }

    /// Runs the debrief pipeline and pastes the rendered summary. Owns all the
    /// UI state around the run; `DebriefPipeline` itself stays UI-free.
    func runDebrief(samples: [Float], originalFile: URL?) async {
        guard claimDebrief(status: "Transcribing…") else {
            sendNotification(title: "Debrief Busy", body: "Debrief already in progress.")
            // Same reasoning as the call path — see the helper's comment.
            releaseUnclaimedProcessingState()
            return
        }
        await runClaimedDebrief(samples: samples, originalFile: originalFile)
    }

    /// The body of a debrief run, for callers that already hold the claim.
    /// Always releases it, on every exit path.
    private func runClaimedDebrief(samples: [Float], originalFile: URL?) async {
        debriefStatus = "Transcribing…"
        defer { releaseDebrief() }

        let pipeline = makeDebriefPipeline()

        do {
            let result = try await pipeline.run(
                samples: samples,
                language: configService.language.whisperCode,
                micSensitivity: configService.micSensitivity,
                originalFile: originalFile,
                onStage: { [weak self] stage in self?.applyDebriefStage(stage) }
            )
            reportDebriefSuccess(result)
        } catch {
            reportDebriefFailure(error)
        }
    }

    /// Mirrors a pipeline stage into the status text shown in the menu.
    private func applyDebriefStage(_ stage: DebriefStage) {
        switch stage {
        case .transcribing: debriefStatus = "Transcribing…"
        case .summarizing: debriefStatus = "Summarizing…"
        case .saving: debriefStatus = "Saving…"
        }
    }

    /// History, paste, sound and notification for a finished debrief — shared
    /// by the mic path (`runClaimedDebrief`) and the call path
    /// (`runCallDebrief`) so both behave identically.
    private func reportDebriefSuccess(_ result: DebriefResult) {
        lastDebriefEngineName = result.engineName
        DiagnosticLogger.shared.log(
            "DEBRIEF | engine=\(result.engineName) | chars=\(result.renderedText.count)"
            + " | folder=\(result.paths.folder.lastPathComponent)"
        )

        // Same history bookkeeping as a normal transcript (see outputText),
        // but pasted through the multi-line path so the headings survive.
        configService.addHistoryItem(text: result.renderedText)
        clipboardManager.pasteMultiline(result.renderedText)
        audioFeedback.beepOff()

        let preview = result.renderedText.count > 50
            ? String(result.renderedText.prefix(50)) + "..."
            : result.renderedText
        sendNotification(title: "Debrief Pasted", body: preview, isRoutine: true)
    }

    private func reportDebriefFailure(_ error: Error) {
        if error is TranscriptionTimeoutError {
            DiagnosticLogger.shared.log("DEBRIEF | timeout")
            sendNotification(title: "Transcription Timeout", body: "Processing took too long and was cancelled.")
            return
        }
        DiagnosticLogger.shared.log("DEBRIEF | error | \(error.localizedDescription)")
        sendNotification(title: "Debrief Failed", body: error.localizedDescription)
    }

    /// Runs the same debrief pipeline on an existing recording (a Voice Memo,
    /// say) instead of freshly captured microphone audio.
    ///
    /// The debrief state is claimed *before* the file is decoded. Decoding a
    /// long recording takes seconds, and until the claim exists `appState` is
    /// still `.idle`, so the dictation hotkey would happily start a recording
    /// on top of the import — after which `stopRecording` refuses to run
    /// (`appState` is no longer `.recording`) and the microphone never stops.
    func importAudioFile(url: URL) async {
        guard appState != .recording else { return }

        // A crashed call left a session folder with `me.wav` and `them.wav` in
        // it. Picking that folder — or either WAV inside it — re-runs it as a
        // two-track call rather than importing one side as a mono recording.
        if let callFolder = Self.callSessionFolder(for: url) {
            await runCallDebrief(paths: DebriefSessionPaths(folder: callFolder))
            return
        }

        guard claimDebrief(status: "Loading audio…") else {
            sendNotification(title: "Debrief Busy", body: "Debrief already in progress.")
            return
        }

        let load = audioFileLoader
        let samples: [Float]
        do {
            // Decoding and resampling a long recording is CPU/IO work; keep it
            // off the main actor so the menu stays responsive.
            samples = try await Task.detached(priority: .userInitiated) {
                try load(url)
            }.value
        } catch {
            DiagnosticLogger.shared.log("DEBRIEF | load_failed | \(error.localizedDescription)")
            sendNotification(title: "Could Not Load Audio", body: error.localizedDescription)
            releaseDebrief()
            return
        }

        await runClaimedDebrief(samples: samples, originalFile: url)
    }

    /// The debrief session folder `url` identifies, when `url` is a two-track
    /// call session: either the folder itself or one of its two WAVs. `nil`
    /// for an ordinary single recording, which imports as before.
    ///
    /// Both tracks must exist — a folder holding only `me.wav` is a
    /// single-track session and takes the normal import path.
    nonisolated static func callSessionFolder(for url: URL) -> URL? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        let folder: URL
        if isDirectory.boolValue {
            folder = url
        } else if ["me.wav", "them.wav"].contains(url.lastPathComponent.lowercased()) {
            folder = url.deletingLastPathComponent()
        } else {
            return nil
        }

        let paths = DebriefSessionPaths(folder: folder)
        let bothTracksExist = [DebriefTrack.me, .them].allSatisfy {
            fileManager.fileExists(atPath: paths.audioURL(for: $0).path)
        }
        return bothTracksExist ? folder : nil
    }

    /// Menu action: pick an audio file, then run `importAudioFile` on it.
    func loadAudioFileFromPanel() {
        // A menu-bar-only app isn't frontmost when the menu is open, so the
        // panel would otherwise appear behind other windows.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        // Directories are selectable so a crashed call's session folder can be
        // picked whole; `callSessionFolder(for:)` decides what it actually is.
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose a recording — or a call's session folder — to run through the debrief pipeline"
        // If none of the extensions resolve to a UTType, fall back to the audio
        // supertype rather than leaving the list empty — an empty
        // `allowedContentTypes` means "allow everything", which would let the
        // user pick a file the loader is guaranteed to reject.
        let contentTypes = AudioFileLoader.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowedContentTypes = contentTypes.isEmpty ? [.audio] : contentTypes

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { await importAudioFile(url: url) }
    }

    /// Menu action: reveal `~/Documents/Dikta` in Finder, creating it if the
    /// user hasn't run a debrief yet.
    func openDebriefFolder() {
        let root = DebriefStore.defaultRoot
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            AppLogger.general.error("Failed to create debrief folder: \(error.localizedDescription)")
        }
        NSWorkspace.shared.open(root)
    }

    // MARK: - Launch at Login

    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    func toggleLaunchAtLogin() {
        let newValue = !launchAtLogin
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = newValue
        } catch {
            AppLogger.general.error("Failed to \(newValue ? "register" : "unregister") launch at login: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Mute Sounds

    func toggleMuteSounds() {
        configService.muteSounds.toggle()
        audioFeedback.isMuted = configService.muteSounds
    }

    // MARK: - Mute Notifications

    func toggleMuteNotifications() {
        configService.muteNotifications.toggle()
    }

    func toggleDiagnosticLogging() {
        configService.diagnosticLogging.toggle()
    }

    // MARK: - Language

    func setLanguage(_ language: Language) {
        // Auto-enable if the chosen language is currently disabled
        configService.enableLanguage(language)
        applyLanguageChange(language)
        sendNotification(title: "Write in", body: language.displayName, isRoutine: true)
    }

    func cycleLanguage() {
        let enabled = configService.enabledLanguages
        let next = configService.language.next(in: enabled)
        setLanguage(next)
    }

    /// Toggle a language's enabled state in the carousel.
    /// - If enabling: also sets it as the active language.
    /// - If disabling and it was the active language: cycles to the next enabled language.
    /// - No-op if it is the last enabled language (enforced by ConfigService).
    func toggleLanguage(_ language: Language) {
        let wasEnabled = configService.isLanguageEnabled(language)
        let isActive = configService.language == language
        let isLastEnabled = configService.enabledLanguages.count == 1 && wasEnabled

        guard !isLastEnabled else { return }

        if wasEnabled {
            // If disabling the active language, cycle away first
            if isActive {
                // Compute next among remaining enabled (excluding this one)
                let remaining = configService.enabledLanguages.filter { $0 != language }
                let nextLang = remaining.first ?? language
                applyLanguageChange(nextLang)
            }
            configService.disableLanguage(language)
        } else {
            // Enable and activate
            configService.enableLanguage(language)
            applyLanguageChange(language)
            sendNotification(title: "Write in", body: language.displayName, isRoutine: true)
        }
    }

    /// Sets the active language and, if its effective Whisper model (see
    /// `effectiveModel(for:)`) differs from what's currently loaded, reloads to
    /// it — without touching the persisted preference
    /// (`configService.whisperModel`).
    ///
    /// The language change itself is always applied immediately, matching the
    /// existing (pre-KB-Whisper) behaviour of `setLanguage`/`toggleLanguage`,
    /// which never blocked on `appState`; there is no existing precedent for
    /// rejecting a language change mid-recording, so none is introduced here —
    /// only the model swap defers until the app is idle.
    private func applyLanguageChange(_ language: Language) {
        configService.language = language
        reloadForCurrentLanguageIfNeeded()
    }

    /// Reloads to the effective model for the current language if it differs
    /// from what's loaded, using the same reload-with-fallback machinery as
    /// `setWhisperModel`. If the app isn't idle (recording or processing),
    /// defers via `languageModelReloadPending` instead of reloading; the
    /// `$appState` subscription in `init` re-runs this as soon as `appState`
    /// becomes `.idle` again.
    private func reloadForCurrentLanguageIfNeeded() {
        let target = effectiveModel(for: configService.language)
        guard target != loadedModel else {
            languageModelReloadPending = false
            return
        }
        guard appState == .idle else {
            languageModelReloadPending = true
            return
        }

        languageModelReloadPending = false
        // `?? .small` only matters if a prior total failure left nothing
        // loaded (see `reloadWithFallback`); `.small` is bundled in release
        // builds, so it's the safest possible fallback target.
        let previousModel = loadedModel ?? .small
        appState = .loading
        Task { @MainActor in
            await self.reloadWithFallback(to: target, from: previousModel)
        }
    }

    // MARK: - Mic Sensitivity

    func setMicSensitivity(_ sensitivity: MicSensitivity) {
        configService.micSensitivity = sensitivity
        sendNotification(title: "Mic Sensitivity", body: "Set to \(sensitivity.displayName)", isRoutine: true)
    }

    // MARK: - Whisper Model

    /// The model that should be active for `language`: KB-Whisper Small
    /// (Swedish-tuned) when `language` is Swedish, overriding any user
    /// preference — its Swedish WER is far better than the general models', but
    /// it must never be used for any other language, where its WER is far
    /// worse. For every other language, the user's own preference applies —
    /// unless the "preference" isn't actually user-selectable (e.g. a
    /// hand-edited config with `whisper_model: "kb-whisper-small"`), in which
    /// case it's coerced to `.small` rather than smuggling KB-Whisper into a
    /// non-Swedish language.
    ///
    /// Pure and static (and `nonisolated`, since it touches no actor state) so
    /// it's unit-testable without a live `MenuBarViewModel` or `@MainActor`.
    nonisolated static func effectiveModel(for language: Language, preference: WhisperModel) -> WhisperModel {
        guard language == .swedish else {
            return preference.isUserSelectable ? preference : .small
        }
        return .kbWhisperSmall
    }

    /// Convenience over `effectiveModel(for:preference:)` using the currently
    /// persisted preference (`configService.whisperModel`).
    func effectiveModel(for language: Language) -> WhisperModel {
        let preference = WhisperModel(rawValue: configService.whisperModel) ?? .small
        return Self.effectiveModel(for: language, preference: preference)
    }

    /// Switches the persisted preference to `model`, reloading it live. Returns
    /// the `Task` doing the work (nil if the switch was skipped — already
    /// idle-blocked, already on `model`, or a no-op because Swedish is active
    /// and KB-Whisper stays loaded regardless of preference) so tests can await
    /// its completion instead of polling `appState`. Production callers can
    /// ignore the return value.
    @discardableResult
    func setWhisperModel(_ model: WhisperModel) -> Task<Void, Never>? {
        guard model.rawValue != configService.whisperModel else { return nil }

        // While Svenska is active, KB-Whisper stays loaded no matter what the
        // user picks here — just remember the preference for later languages.
        if configService.language == .swedish {
            configService.whisperModel = model.rawValue
            return nil
        }

        guard appState == .idle else { return nil }

        let previousModel = loadedModel ?? .small
        appState = .loading

        return Task { @MainActor in
            await self.reloadWithFallback(to: model, from: previousModel) {
                // Only persist the new model once it has actually loaded.
                self.configService.whisperModel = model.rawValue
                self.sendNotification(
                    title: "Model Changed",
                    body: "Switched to \(model.displayName).",
                    isRoutine: true
                )
            }
        }
    }

    /// Reloads the transcription engine to `model`, using the shared
    /// progress-polling and disk-guard machinery (`withDownloadProgressPolling`,
    /// `Transcriber.reload`), falling back to `previousModel` on failure, and —
    /// if that fallback *also* fails — to `.small` as a last resort (unless
    /// `.small` was already the failed fallback), since `.small` is bundled in
    /// release builds and so can't fail on a network or disk-space problem the
    /// way a download-dependent model can. Updates `loadedModel` and `appState`
    /// on any successful attempt; never touches `configService.whisperModel` —
    /// callers persist the preference themselves via `onSuccess` when the
    /// reload represents an explicit user choice (see `setWhisperModel`).
    /// Caller is responsible for the `appState == .idle` guard and setting
    /// `appState = .loading` before calling this, so it's shared unmodified by
    /// both the user-driven and the language-driven reload paths.
    private func reloadWithFallback(to model: WhisperModel, from previousModel: WhisperModel, onSuccess: (() -> Void)? = nil) async {
        do {
            try await withDownloadProgressPolling {
                try await transcriber.reload(model: model)
            }
            loadedModel = model
            appState = .idle
            onSuccess?()
        } catch {
            // The new model failed to load. Fall back to the model that was
            // working before, so recording (which requires appState == .idle)
            // doesn't stay broken until an app restart.
            do {
                try await withDownloadProgressPolling {
                    try await transcriber.reload(model: previousModel)
                }
                loadedModel = previousModel
                appState = .idle
                if model == .kbWhisperSmall {
                    sendNotification(
                        title: "Error",
                        body: "Could not load KB-Whisper Small. Svenska will use \(previousModel.displayName) until you switch language again."
                    )
                } else {
                    sendNotification(
                        title: "Error",
                        body: "Could not load \(model.displayName), kept \(previousModel.displayName)."
                    )
                }
            } catch {
                // Both the target and the fallback failed. Last resort: try
                // `.small` (skip if it was already the failed fallback above —
                // no point retrying the same failure).
                if previousModel != .small {
                    do {
                        try await withDownloadProgressPolling {
                            try await transcriber.reload(model: .small)
                        }
                        loadedModel = .small
                        appState = .idle
                        sendNotification(
                            title: "Error",
                            body: "Could not load \(model.displayName) or \(previousModel.displayName). Fell back to \(WhisperModel.small.displayName)."
                        )
                        return
                    } catch {
                        // Fall through to the terminal failure below.
                    }
                }

                // Every attempt failed, including the last-resort `.small`
                // fallback (or it was skipped because `.small` was already the
                // failed fallback above). Mirror the startup-failure path
                // (initialize()) by staying out of .idle rather than
                // pretending the app is ready to record — and don't leave
                // `loadedModel` claiming a model that isn't actually loaded.
                loadedModel = nil
                sendNotification(
                    title: "Error",
                    body: transcriber.errorMessage ?? "Failed to load Whisper model"
                )
            }
        }
    }

    // MARK: - TTS Voice

    var ttsVoice: KokoroVoice {
        ttsService.voice
    }

    func setTtsVoice(_ voice: KokoroVoice) {
        ttsService.voice = voice
        sendNotification(title: "Voice Changed", body: "Now using \(voice.displayName)", isRoutine: true)
    }

    // MARK: - Hotkey Recording

    func startRecordingHotkey(for mode: HotkeyMode) {
        // Open the hotkey recording window
        hotkeyWindowController.show(for: mode, viewModel: self)
    }

    /// Called directly by the hotkey window (no notification needed)
    func startRecordingHotkeyDirect(for mode: HotkeyMode) {
        isRecordingHotkey = true
        recordingHotkeyFor = mode
        hotkeyManager.startRecordingHotkey()
    }

    func cancelHotkeyRecording() {
        isRecordingHotkey = false
        recordingHotkeyFor = nil
        pendingCollision = nil
        hotkeyManager.stopRecordingHotkey()
    }

    func closeHotkeyWindow() {
        hotkeyWindowController.close()
    }

    private func updateHotkeyConfig() {
        hotkeyManager.updateConfig(
            toggle: configService.getHotkey(for: .toggle),
            pushToTalk: configService.getHotkey(for: .pushToTalk)
        )
        hotkeyManager.updateTtsConfig(configService.ttsHotkey)
        hotkeyManager.updateLanguageConfig(configService.languageToggleHotkey)
        hotkeyManager.updateFormatConfig(configService.getHotkey(for: .formatSelection))
    }

    // MARK: - Text-to-Speech

    /// Speak selected text using TTS
    func speakSelectedText() async {
        guard appState == .idle else { return }

        // Get selected text via Accessibility API or clipboard fallback
        guard let text = textSelectionService.getSelectedText()
              ?? textSelectionService.getSelectedTextViaClipboard() else {
            sendNotification(title: "No Selection", body: "Please select text first")
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendNotification(title: "Empty Selection", body: "Selected text is empty")
            return
        }

        // Check if TTS server is available
        if !(await ttsService.checkAvailable()) {
            if ttsService.isSetUp {
                sendNotification(title: "TTS Starting Up", body: "Voice engine is loading, please try again shortly.", isRoutine: true)
            } else {
                sendNotification(title: "TTS Not Available", body: "Open Setup to install Text-to-Speech.")
            }
            return
        }

        appState = .speaking
        audioFeedback.beepOn()

        do {
            try await ttsService.speak(text)
            audioFeedback.beepOff()
        } catch {
            sendNotification(title: "TTS Error", body: error.localizedDescription)
        }

        appState = .idle
    }

    /// Stop current TTS playback
    func stopSpeaking() {
        ttsService.stop()
        appState = .idle
    }

    private func unmuteMicTargets() {
        guard !activeMuteTokens.isEmpty else { return }
        muterRegistry.unmuteAll(activeMuteTokens)
        activeMuteTokens = []
    }

    // MARK: - Notifications

    /// True when XCTest is linked into this process — true under both `swift test`
    /// and `xcodebuild test`, hosted or not (including `Dikta.app` itself, when it's
    /// acting as the unit-test host for `xcodebuild test -scheme Dikta`). Used to
    /// skip real-app side effects (notifications, the onboarding window, the global
    /// hotkey listener) that either crash or misbehave when a `MenuBarViewModel` is
    /// constructed directly in a unit test, since `init()` kicks them off
    /// automatically — and, via `init`'s engine-construction guard below, to catch
    /// any `MenuBarViewModel()` built under XCTest without an injected `engine`/
    /// `engineFactory`, which would otherwise silently build a real, network-touching
    /// `Transcriber` (see `DiktaApp`, which must inject a no-op engine for exactly
    /// this reason).
    static let isRunningUnderXCTestHost: Bool = NSClassFromString("XCTestCase") != nil

    private var isRunningUnderXCTest: Bool { Self.isRunningUnderXCTestHost }

    private var canUseNotifications: Bool {
        // UNUserNotificationCenter requires a proper app bundle and crashes
        // (bundleProxyForCurrentProcess is nil) when called from the bare xctest
        // executable. Bundle.main.bundleIdentifier alone doesn't rule that out
        // (the xctest tool itself has one), hence the XCTest check too.
        Bundle.main.bundleIdentifier != nil && !isRunningUnderXCTest
    }

    private func sendNotification(title: String, body: String, isRoutine: Bool = false) {
        if isRoutine && configService.muteNotifications { return }
        guard canUseNotifications else {
            AppLogger.general.info("[\(title)] \(body)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Dikta"
        content.subtitle = title
        content.body = body
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Request notification permissions
    func requestNotificationPermissions() async {
        guard canUseNotifications else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Returns the app's memory footprint in MB, or nil if unavailable.
    private func memoryFootprintMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / (1024 * 1024)
    }

    deinit {
        hotkeyManager.stop()
    }
}

// MARK: - HotkeyManagerDelegate

extension MenuBarViewModel: HotkeyManagerDelegate {
    nonisolated func hotkeyPressed(mode: HotkeyMode) {
        Task { @MainActor in
            if appState == .idle {
                // A call recording is toggle-only (decision 10: "stop only").
                // Push-to-talk must not start one — its release would end the
                // recording the moment the user let go of the key, mid-call.
                if mode == .pushToTalk && isCallRecordingMode { return }
                // Start recording and track which mode initiated it
                activeRecordingMode = mode
                startRecording()
            } else if appState == .recording && mode == .toggle && activeRecordingMode == .toggle {
                // Only toggle mode can stop its own recording via press
                stopRecording()
            }
            // Otherwise ignore (e.g., PTT press while toggle is recording)
        }
    }

    nonisolated func hotkeyReleased(mode: HotkeyMode) {
        Task { @MainActor in
            // Only stop if PTT released its own recording — and never while a
            // call recording is running: push-to-talk is ignored there
            // entirely (decision 10), including a key that was already down
            // when the call recording started.
            if mode == .pushToTalk && activeRecordingMode == .pushToTalk && activeCallSession == nil {
                stopRecording()
            }
        }
    }

    nonisolated func hotkeyRecorded(modifiers: [ModifierKey], key: String?) {
        Task { @MainActor in
            guard let mode = recordingHotkeyFor else { return }

            let hotkey = HotkeyConfig(modifiers: modifiers, key: key)

            // Check for collision with any other mode
            if let conflicting = findConflictingMode(for: hotkey, excluding: mode) {
                // Pause recording state — let the view show the collision warning
                isRecordingHotkey = false
                hotkeyManager.stopRecordingHotkey()
                pendingCollision = HotkeyCollision(newHotkey: hotkey, forMode: mode, conflictingMode: conflicting)
                return
            }

            applyHotkey(hotkey, for: mode)
        }
    }
    
    nonisolated func formatHotkeyPressed() {
        Task { @MainActor in
            let currentLanguage = configService.language
            clipboardManager.formatSelection(style: .message, language: currentLanguage)
        }
    }

    /// Find another mode that uses the same hotkey, if any
    private func findConflictingMode(for hotkey: HotkeyConfig, excluding mode: HotkeyMode) -> HotkeyMode? {
        for other in HotkeyMode.allCases where other != mode {
            let existing = configService.getHotkey(for: other)
            if existing == hotkey {
                return other
            }
        }
        return nil
    }

    /// Save a hotkey for a mode, clear recording state, notify
    private func applyHotkey(_ hotkey: HotkeyConfig, for mode: HotkeyMode) {
        configService.setHotkey(hotkey, for: mode)
        updateHotkeyConfig()

        isRecordingHotkey = false
        recordingHotkeyFor = nil
        pendingCollision = nil
        hotkeyManager.stopRecordingHotkey()

        sendNotification(
            title: "Hotkey Set",
            body: "\(mode.displayName) hotkey set to \(hotkey.displayString)",
            isRoutine: true
        )
    }

    /// Resolve a hotkey collision by overriding: clear the conflicting mode's hotkey and apply
    func resolveCollisionOverride() {
        guard let collision = pendingCollision else { return }
        // Clear the conflicting mode's hotkey
        configService.setHotkey(HotkeyConfig(modifiers: [], key: nil), for: collision.conflictingMode)
        applyHotkey(collision.newHotkey, for: collision.forMode)
        sendNotification(
            title: "Hotkey Cleared",
            body: "\(collision.conflictingMode.displayName) hotkey was cleared due to conflict",
            isRoutine: true
        )
    }

    /// Cancel a pending collision — re-enter recording mode so user can try a different hotkey
    func resolveCollisionCancel() {
        guard let collision = pendingCollision else { return }
        let mode = collision.forMode
        pendingCollision = nil
        // Re-start recording for the same mode
        startRecordingHotkeyDirect(for: mode)
    }

    nonisolated func hotkeyManagerDidFailToStart(_ error: String) {
        Task { @MainActor in
            sendNotification(title: "Hotkey Error", body: error)
        }
    }

    nonisolated func languageHotkeyPressed() {
        Task { @MainActor in
            cycleLanguage()
        }
    }

    nonisolated func ttsHotkeyPressed() {
        Task { @MainActor in
            // Toggle: if speaking, stop; otherwise start
            if appState == .speaking {
                stopSpeaking()
            } else {
                await speakSelectedText()
            }
        }
    }
}

// MARK: - Supporting Types

/// Thrown when transcription exceeds the timeout limit
/// Internal rather than private so `DebriefPipeline` (which races the same
/// transcription call against its own, much longer timeout) can throw it too.
struct TranscriptionTimeoutError: Error, LocalizedError {
    var errorDescription: String? { "Transcription timed out" }
}
