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
    ///   - engine: Transcription engine to use. Defaults to a real WhisperKit-backed
    ///     `Transcriber` built from the saved config; tests can inject a fake instead.
    ///   - engineFactory: Alternative to `engine` for tests that need to observe which
    ///     model the engine is constructed with (a plain injected `engine` never sees
    ///     the startup model — the fake doesn't care what it's "loaded" with). Ignored
    ///     if `engine` is provided. Production never sets this; it falls through to
    ///     the real `Transcriber(model:)`.
    ///   - configService: Config store to use. Defaults to `.shared` (the real, persisted
    ///     config); tests can inject an isolated instance instead.
    init(
        engine: (any TranscriptionEngine)? = nil,
        engineFactory: ((WhisperModel) -> any TranscriptionEngine)? = nil,
        configService: ConfigService? = nil
    ) {
        let configService = configService ?? .shared
        self.configService = configService
        let preferenceModel = WhisperModel(rawValue: configService.whisperModel) ?? .small
        let startupModel = Self.effectiveModel(for: configService.language, preference: preferenceModel)
        self.loadedModel = startupModel
        self.transcriber = engine ?? engineFactory?(startupModel) ?? Transcriber(model: startupModel)
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
