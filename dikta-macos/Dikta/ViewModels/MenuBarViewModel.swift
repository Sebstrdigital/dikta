import Foundation
import AppKit
import UserNotifications
import Combine
import ServiceManagement

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

    // Services
    let configService: ConfigService
    private var cancellables = Set<AnyCancellable>()
    private var transcriber: any TranscriptionEngine
    /// Builds a `TranscriptionEngine` for a given kind/model. Defaults to
    /// `TranscriptionEngineFactory.make`; tests inject a fake so `setEngine`
    /// can be exercised without touching WhisperKit or Speech.
    private let engineFactory: (TranscriptionEngineKind, WhisperModel, ConfigService) -> any TranscriptionEngine
    private let audioRecorder: AudioRecorder
    private let audioFeedback: AudioFeedback
    private let clipboardManager: ClipboardManager
    private let hotkeyManager: HotkeyManager
    private let ttsService: TextToSpeechService
    private let textSelectionService: TextSelectionService
    private let muterRegistry: MuterRegistry

    // Track which mode initiated a recording (nil when not recording)
    private var activeRecordingMode: HotkeyMode? = nil
    private var recordingStartDate: Date?
    private var activeMuteTokens: [MuteToken] = []

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
    ///   - engine: Transcription engine to use. Defaults to one built by
    ///     `engineFactory` from the saved config's engine kind; tests can
    ///     inject a fake instead.
    ///   - configService: Config store to use. Defaults to `.shared` (the real, persisted
    ///     config); tests can inject an isolated instance instead.
    ///   - engineFactory: Builds the default `engine` when none is injected, and
    ///     builds every engine `setEngine` switches to. Defaults to
    ///     `TranscriptionEngineFactory.make`; tests inject a fake factory.
    init(
        engine: (any TranscriptionEngine)? = nil,
        configService: ConfigService? = nil,
        engineFactory: @escaping (TranscriptionEngineKind, WhisperModel, ConfigService) -> any TranscriptionEngine = TranscriptionEngineFactory.make
    ) {
        let configService = configService ?? .shared
        self.configService = configService
        self.engineFactory = engineFactory
        let model = WhisperModel(rawValue: configService.whisperModel) ?? .small
        self.transcriber = engine ?? engineFactory(configService.engine, model, configService)
        self.audioRecorder = AudioRecorder()
        self.audioFeedback = AudioFeedback()
        self.clipboardManager = ClipboardManager()
        self.hotkeyManager = HotkeyManager()
        self.ttsService = TextToSpeechService()
        self.textSelectionService = TextSelectionService(clipboardManager: clipboardManager)
        self.muterRegistry = MuterRegistry()

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

        // Start initialization automatically
        Task { @MainActor in
            await self.requestNotificationPermissions()
            await self.initialize()
        }
    }

    /// Runs `work` (a `load()`/`reload(model:)` call on `engine`) while mirroring
    /// `engine.downloadProgress` into `downloadProgress` on a short poll, so
    /// a menu re-render picks up the current download percentage. Polling (rather
    /// than a Combine subscription) is used because engines are held as
    /// `any TranscriptionEngine` for testability, which doesn't expose a publisher.
    /// Always resets `downloadProgress` to nil when `work` finishes, success or not.
    ///
    /// `engine` defaults to the currently active `transcriber`, which is what
    /// every call site wants except `setEngine` — that one is loading a brand
    /// new engine instance that isn't `transcriber` yet, so it passes that
    /// instance explicitly.
    private func withDownloadProgressPolling<T>(observing engine: (any TranscriptionEngine)? = nil, _ work: () async throws -> T) async rethrows -> T {
        let engine = engine ?? transcriber
        let pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.downloadProgress = engine.downloadProgress
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
            let muteTokens = muterRegistry.muteAll()
            activeMuteTokens = muteTokens

            do {
                try await audioRecorder.startRecording(micSensitivity: configService.micSensitivity)
                recordingStartDate = Date()
                appState = .recording
                audioFeedback.beepOn()
                DiagnosticLogger.shared.log("START | mic=\(configService.micSensitivity.displayName) | rate=\(audioRecorder.inputSampleRate)Hz")
            } catch {
                unmuteMicTargets()
                sendNotification(title: "Error", body: "Failed to start recording: \(error.localizedDescription)")
                DiagnosticLogger.shared.log("START_FAILED | \(error.localizedDescription)")
            }
        }
    }

    /// Stop recording and process
    func stopRecording() {
        guard appState == .recording else { return }

        activeRecordingMode = nil
        audioRecorder.onSilenceAutoStop = nil
        let audioSamples = audioRecorder.stopRecording()
        unmuteMicTargets()
        appState = .processing

        Task {
            await processAudio(audioSamples)
        }
    }

    /// Timeout for transcription (seconds)
    private static let transcriptionTimeout: UInt64 = 60

    private func processAudio(_ samples: [Float]) async {
        // Diagnostic: log audio buffer stats
        let duration = recordingStartDate.map { Date().timeIntervalSince($0) } ?? 0
        let bufferRMS: Float = samples.isEmpty ? 0 :
            (samples.reduce(0.0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        DiagnosticLogger.shared.log(
            "AUDIO | dur=\(String(format: "%.1f", duration))s | samples=\(samples.count) | rms=\(String(format: "%.6f", bufferRMS))"
            + " | routeChanges=\(audioRecorder.routeChangeCount) | converterErrors=\(audioRecorder.converterErrorCount) | emptyBuffers=\(audioRecorder.emptyBufferCount)"
        )
        recordingStartDate = nil

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

            // Check for silence/empty output from Whisper
            let silenceIndicators = ["[silence]", "[blank_audio]", "[no speech]", "(silence)", "[ silence ]"]
            let lowerText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            let matchedIndicator = silenceIndicators.first(where: { lowerText.contains($0) })
            if lowerText.isEmpty || matchedIndicator != nil {
                let reason = lowerText.isEmpty ? "empty text" : "matched=\"\(matchedIndicator!)\""
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
        clipboardManager.pasteText(text)

        // Beep and notify
        audioFeedback.beepOff()

        let preview = text.count > 50 ? String(text.prefix(50)) + "..." : text
        sendNotification(title: "Pasted", body: preview, isRoutine: true)
    }

    /// Paste a history item
    func pasteHistoryItem(_ item: HistoryItem) {
        clipboardManager.pasteText(item.text)
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

    /// Switches the active dictation language to `language`, `prepare`-ing
    /// the active engine for it first (see `TranscriptionEngine.prepare(language:)`).
    /// Matters for Apple Dictation, which must resolve/install the new
    /// language's assets before `transcribe` can use it — without this step,
    /// switching languages while Apple Dictation is active left `transcribe`
    /// throwing `.assetsNotInstalled` until the app restarted. WhisperKit's
    /// `Transcriber` no-ops `prepare` (it takes a language code per-call).
    ///
    /// Mirrors `setWhisperModel`/`setEngine`'s safe-switch pattern: only runs
    /// when idle, goes `.loading` during the switch, and only persists the
    /// new language once `prepare` has actually succeeded — on failure the
    /// previous language stays configured and a notification explains why.
    /// Returns the `Task` doing the work (nil if skipped — not idle, or
    /// already on `language`) so tests can await completion instead of
    /// polling `appState`; production callers can ignore the return value.
    ///
    /// - Parameters:
    ///   - notifyOnSuccess: Whether to send a "Write in: <language>"
    ///     notification once switched — existing callers only want that for
    ///     a deliberate language pick, not `toggleLanguage`'s "cycle away
    ///     from the language being disabled" step.
    ///   - onSuccess: Runs after the language switch (and its notification)
    ///     succeeds. `toggleLanguage` uses this to disable the old language
    ///     only once cycling away from it has actually worked.
    @discardableResult
    private func activateLanguage(_ language: Language, notifyOnSuccess: Bool, onSuccess: (() -> Void)? = nil) -> Task<Void, Never>? {
        guard appState == .idle else { return nil }
        guard language != configService.language else { return nil }

        let previousLanguage = configService.language
        appState = .loading

        return Task { @MainActor in
            do {
                try await withDownloadProgressPolling {
                    try await transcriber.prepare(language: language)
                }
                // Only persist the new language once the engine has actually
                // prepared for it.
                configService.language = language
                appState = .idle
                if notifyOnSuccess {
                    sendNotification(title: "Write in", body: language.displayName, isRoutine: true)
                }
                onSuccess?()
            } catch {
                // The engine couldn't prepare for the new language (e.g.
                // Apple Dictation doesn't support it, or its assets failed to
                // install) — keep the previous language active/configured
                // rather than leaving transcribe() broken until restart.
                appState = .idle
                sendNotification(
                    title: "Error",
                    body: "Could not switch to \(language.displayName), kept \(previousLanguage.displayName). \(error.localizedDescription)"
                )
            }
        }
    }

    @discardableResult
    func setLanguage(_ language: Language) -> Task<Void, Never>? {
        // Auto-enable if the chosen language is currently disabled
        configService.enableLanguage(language)
        return activateLanguage(language, notifyOnSuccess: true)
    }

    @discardableResult
    func cycleLanguage() -> Task<Void, Never>? {
        let enabled = configService.enabledLanguages
        let next = configService.language.next(in: enabled)
        return setLanguage(next)
    }

    /// Toggle a language's enabled state in the carousel.
    /// - If enabling: also sets it as the active language.
    /// - If disabling and it was the active language: cycles to the next enabled language.
    /// - No-op if it is the last enabled language (enforced by ConfigService).
    @discardableResult
    func toggleLanguage(_ language: Language) -> Task<Void, Never>? {
        let wasEnabled = configService.isLanguageEnabled(language)
        let isActive = configService.language == language
        let isLastEnabled = configService.enabledLanguages.count == 1 && wasEnabled

        guard !isLastEnabled else { return nil }

        if wasEnabled {
            guard isActive else {
                // Disabling a language that isn't the active one touches
                // neither the active language nor the engine.
                configService.disableLanguage(language)
                return nil
            }
            // Disabling the active language: cycle to the next enabled one
            // first, through the same prepare-before-persist path as
            // `setLanguage`, and only disable `language` once that's
            // actually succeeded — a failed engine prepare must not leave
            // the carousel with no active language.
            let remaining = configService.enabledLanguages.filter { $0 != language }
            guard let nextLanguage = remaining.first else { return nil }
            return activateLanguage(nextLanguage, notifyOnSuccess: false) { [weak self] in
                self?.configService.disableLanguage(language)
            }
        } else {
            // Enable and activate
            configService.enableLanguage(language)
            return activateLanguage(language, notifyOnSuccess: true)
        }
    }

    // MARK: - Mic Sensitivity

    func setMicSensitivity(_ sensitivity: MicSensitivity) {
        configService.micSensitivity = sensitivity
        sendNotification(title: "Mic Sensitivity", body: "Set to \(sensitivity.displayName)", isRoutine: true)
    }

    // MARK: - Whisper Model

    /// Switches to `model`, reloading it live. Returns the `Task` doing the work
    /// (nil if the switch was skipped — already idle-blocked, or already on
    /// `model`) so tests can await its completion instead of polling `appState`.
    /// Production callers can ignore the return value.
    @discardableResult
    func setWhisperModel(_ model: WhisperModel) -> Task<Void, Never>? {
        guard appState == .idle else { return nil }
        guard model.rawValue != configService.whisperModel else { return nil }

        let previousModel = WhisperModel(rawValue: configService.whisperModel) ?? .small
        appState = .loading

        return Task { @MainActor in
            do {
                try await withDownloadProgressPolling {
                    try await transcriber.reload(model: model)
                }
                // Only persist the new model once it has actually loaded.
                configService.whisperModel = model.rawValue
                appState = .idle
                sendNotification(
                    title: "Model Changed",
                    body: "Switched to \(model.displayName).",
                    isRoutine: true
                )
            } catch {
                // The new model failed to load. Fall back to the model that was
                // working before, so recording (which requires appState == .idle)
                // doesn't stay broken until an app restart.
                do {
                    try await withDownloadProgressPolling {
                        try await transcriber.reload(model: previousModel)
                    }
                    appState = .idle
                    sendNotification(
                        title: "Error",
                        body: "Could not load \(model.displayName), kept \(previousModel.displayName)."
                    )
                } catch {
                    // Fallback also failed: mirror the startup-failure path
                    // (initialize()) by staying out of .idle rather than
                    // pretending the app is ready to record with no model loaded.
                    sendNotification(
                        title: "Error",
                        body: transcriber.errorMessage ?? "Failed to load Whisper model"
                    )
                }
            }
        }
    }

    // MARK: - Transcription Engine

    /// Switches the active transcription engine to `kind`. Returns the `Task`
    /// doing the work (nil if the switch was skipped — already idle-blocked,
    /// or already on `kind`) so tests can await its completion instead of
    /// polling `appState`. Production callers can ignore the return value.
    ///
    /// Unlike `setWhisperModel` (which reloads WhisperKit's *same* long-lived
    /// instance in place), this builds a brand new engine via `engineFactory`
    /// and only swaps `transcriber` to it once its `load()` has actually
    /// succeeded. The previous engine is never touched, so on failure it's
    /// still loaded and ready — "falling back" to it is just not swapping,
    /// with no extra reload step needed.
    @discardableResult
    func setEngine(_ kind: TranscriptionEngineKind) -> Task<Void, Never>? {
        guard appState == .idle else { return nil }
        guard kind != configService.engine else { return nil }

        let previousKind = configService.engine
        let model = WhisperModel(rawValue: configService.whisperModel) ?? .small
        appState = .loading

        return Task { @MainActor in
            let newEngine = engineFactory(kind, model, configService)
            await withDownloadProgressPolling(observing: newEngine) {
                await newEngine.load()
            }

            if newEngine.isReady {
                transcriber = newEngine
                // Only persist the new engine once it has actually loaded.
                configService.engine = kind
                appState = .idle
                sendNotification(
                    title: "Engine Changed",
                    body: "Switched to \(kind.displayName).",
                    isRoutine: true
                )
            } else {
                appState = .idle
                let detail = newEngine.errorMessage.map { " \($0)" } ?? ""
                sendNotification(
                    title: "Error",
                    body: "Could not switch to \(kind.displayName), kept \(previousKind.displayName).\(detail)"
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
    /// and `xcodebuild test`, hosted or not. Used to skip real-app side effects
    /// (notifications, the onboarding window, the global hotkey listener) that
    /// either crash or misbehave when a `MenuBarViewModel` is constructed directly
    /// in a unit test, since `init()` kicks them off automatically.
    private var isRunningUnderXCTest: Bool {
        NSClassFromString("XCTestCase") != nil
    }

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
            // Only stop if PTT released its own recording
            if mode == .pushToTalk && activeRecordingMode == .pushToTalk {
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
private struct TranscriptionTimeoutError: Error, LocalizedError {
    var errorDescription: String? { "Transcription timed out" }
}
