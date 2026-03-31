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
    static var isModelLoaded = false

    // Services
    let configService: ConfigService
    private var cancellables = Set<AnyCancellable>()
    private let transcriber: Transcriber
    private let audioRecorder: AudioRecorder
    private let audioFeedback: AudioFeedback
    private let clipboardManager: ClipboardManager
    private let hotkeyManager: HotkeyManager
    private let ttsService: TextToSpeechService
    private let textSelectionService: TextSelectionService

    // Track which mode initiated a recording (nil when not recording)
    private var activeRecordingMode: HotkeyMode? = nil
    private var recordingStartDate: Date?

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

    init() {
        self.configService = ConfigService.shared
        self.transcriber = Transcriber(modelName: configService.whisperModel)
        self.audioRecorder = AudioRecorder()
        self.audioFeedback = AudioFeedback()
        self.clipboardManager = ClipboardManager()
        self.hotkeyManager = HotkeyManager()
        self.ttsService = TextToSpeechService()
        self.textSelectionService = TextSelectionService(clipboardManager: clipboardManager)

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

    /// Initialize the app (load models, check permissions, etc.)
    func initialize() async {
        appState = .loading

        // Always show onboarding on app start
        OnboardingWindowController.shared.show()

        // Now request mic permission (shows system dialog if not determined)
        let hasMicPermission = await AudioRecorder.checkPermission()
        if !hasMicPermission {
            sendNotification(title: "Permission Required", body: "Please grant Microphone access in System Preferences")
        }

        // Load Whisper model
        await transcriber.loadModel()

        if transcriber.isReady {
            appState = .idle

            // Notify About window that model is ready
            Self.isModelLoaded = true
            NotificationCenter.default.post(name: .appModelLoaded, object: nil)

            // Start hotkey listener
            hotkeyManager.start()

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
            self.appState = .processing
            Task {
                await self.processAudio(samples)
            }
        }

        Task {
            do {
                try await audioRecorder.startRecording(micSensitivity: configService.micSensitivity)
                recordingStartDate = Date()
                appState = .recording
                audioFeedback.beepOn()
                DiagnosticLogger.shared.log("START | mic=\(configService.micSensitivity.displayName) | rate=\(audioRecorder.inputSampleRate)Hz")
            } catch {
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
        configService.language = language
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
                configService.language = nextLang
            }
            configService.disableLanguage(language)
        } else {
            // Enable and activate
            configService.enableLanguage(language)
            configService.language = language
            sendNotification(title: "Write in", body: language.displayName, isRoutine: true)
        }
    }

    // MARK: - Mic Sensitivity

    func setMicSensitivity(_ sensitivity: MicSensitivity) {
        configService.micSensitivity = sensitivity
        sendNotification(title: "Mic Sensitivity", body: "Set to \(sensitivity.displayName)", isRoutine: true)
    }

    // MARK: - Whisper Model

    func setWhisperModel(_ model: WhisperModel) {
        configService.whisperModel = model.rawValue
        sendNotification(
            title: "Model Changed",
            body: "Switched to \(model.displayName). Restart app to load new model.",
            isRoutine: true
        )
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

    // MARK: - Notifications

    private var canUseNotifications: Bool {
        // UNUserNotificationCenter requires a proper app bundle
        Bundle.main.bundleIdentifier != nil
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
            clipboardManager.formatSelection(style: .message) // Hardcoded for now
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
