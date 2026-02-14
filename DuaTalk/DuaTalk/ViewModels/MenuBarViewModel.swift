import Foundation
import AppKit
import UserNotifications
import Combine

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
    @Published var isLLMReady = false
    @Published var llmSetupManager = LLMSetupManager.shared

    // Services
    let configService: ConfigService
    private var cancellables = Set<AnyCancellable>()
    private let transcriber: Transcriber
    private let llmService: LocalLLMService
    private let audioRecorder: AudioRecorder
    private let audioFeedback: AudioFeedback
    private let clipboardManager: ClipboardManager
    private let hotkeyManager: HotkeyManager
    private let ttsService: TextToSpeechService
    private let textSelectionService: TextSelectionService

    // Hotkey recording state
    @Published var isRecordingHotkey = false
    @Published var recordingHotkeyFor: HotkeyMode?

    // Window controllers
    let hotkeyWindowController = HotkeyRecordingWindowController()
    let customPromptWindowController = CustomPromptWindowController()

    init() {
        self.configService = ConfigService.shared
        self.transcriber = Transcriber(modelName: configService.whisperModel)
        self.llmService = LocalLLMService()
        self.audioRecorder = AudioRecorder()
        self.audioFeedback = AudioFeedback()
        self.clipboardManager = ClipboardManager()
        self.hotkeyManager = HotkeyManager()
        self.ttsService = TextToSpeechService()
        self.textSelectionService = TextSelectionService(clipboardManager: clipboardManager)

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

        // Update isLLMReady and send download notifications
        llmSetupManager.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] (status: LLMSetupStatus) in
                guard let self = self else { return }
                switch status {
                case .downloading(let progress) where progress == 0:
                    self.sendNotification(title: "Downloading", body: "Enhanced Dictation model download started...")
                case .downloaded:
                    self.isLLMReady = true
                    self.sendNotification(title: "Download Complete", body: "Enhanced Dictation model is ready to use.")
                case .failed(let msg):
                    self.sendNotification(title: "Download Failed", body: msg)
                default:
                    break
                }
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

        // Check if LLM model is downloaded
        isLLMReady = llmService.isModelDownloaded

        // If output mode requires LLM but model not downloaded, fall back to raw
        if configService.outputMode.requiresLLM && !isLLMReady {
            configService.outputMode = .raw
        }

        // Load Whisper model
        await transcriber.loadModel()

        if transcriber.isReady {
            appState = .idle

            // Start hotkey listener
            hotkeyManager.start()

            let hotkey = configService.activeHotkey.displayString
            sendNotification(title: "Ready", body: "Whisper model loaded. Use \(hotkey) to record.")
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

        do {
            try audioRecorder.startRecording()
            appState = .recording
            audioFeedback.beepOn()
        } catch {
            sendNotification(title: "Error", body: "Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Stop recording and process
    func stopRecording() {
        guard appState == .recording else { return }

        let audioSamples = audioRecorder.stopRecording()
        appState = .processing

        Task {
            await processAudio(audioSamples)
        }
    }

    private func processAudio(_ samples: [Float]) async {
        do {
            // Transcribe with selected language
            let language = configService.language
            let rawText = try await transcriber.transcribe(samples, language: language.whisperCode)

            // Check for silence/empty output from Whisper
            let silenceIndicators = ["[silence]", "[blank_audio]", "[no speech]", "(silence)", "[ silence ]"]
            let lowerText = rawText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            if lowerText.isEmpty || silenceIndicators.contains(where: { lowerText.contains($0) }) {
                sendNotification(title: "No Speech", body: "No speech detected in recording")
                appState = .idle
                return
            }

            // Format with LLM if needed
            let outputMode = configService.outputMode
            var finalText = rawText

            if outputMode.requiresLLM && isLLMReady {
                do {
                    let custom = outputMode == .custom ? configService.customPrompt : nil
                    finalText = try await llmService.format(text: rawText, mode: outputMode, language: language, customPrompt: custom)
                } catch {
                    AppLogger.llm.error("LLM formatting failed, using raw text: \(error.localizedDescription)")
                    // Fall through to raw text
                }
            }

            // Skip if LLM returned empty (silence detected)
            if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sendNotification(title: "No Speech", body: "No speech detected in recording")
                appState = .idle
                return
            }

            // Output
            await outputText(finalText)

        } catch {
            sendNotification(title: "Error", body: error.localizedDescription)
        }

        appState = .idle
    }

    private func outputText(_ text: String) async {
        // Add to history
        configService.addHistoryItem(text: text)

        // Paste text
        clipboardManager.pasteText(text)

        // Beep and notify
        audioFeedback.beepOff()

        let preview = text.count > 50 ? String(text.prefix(50)) + "..." : text
        sendNotification(title: "Pasted", body: preview)
    }

    /// Paste a history item
    func pasteHistoryItem(_ item: HistoryItem) {
        clipboardManager.pasteText(item.text)
    }

    // MARK: - Output Mode

    func setOutputMode(_ mode: OutputMode) {
        if mode.requiresLLM && !isLLMReady {
            sendNotification(
                title: "Model Required",
                body: "Download the Enhanced Dictation model first (Settings → Advanced or reopen onboarding)"
            )
            return
        }

        configService.outputMode = mode
        sendNotification(title: "Mode Changed", body: "Now using \(mode.displayName) mode")
    }

    /// Open onboarding to download LLM model (has download progress UI)
    func downloadLLMModel() {
        OnboardingWindowController.shared.show()
    }

    /// Delete the downloaded LLM model
    func deleteLLMModel() {
        llmSetupManager.deleteModel()
        isLLMReady = false
        // Fall back to raw mode if current mode requires LLM
        if configService.outputMode.requiresLLM {
            configService.outputMode = .raw
        }
        sendNotification(title: "Model Deleted", body: "Enhanced Dictation model removed.")
    }

    /// Open the custom prompt editor window
    func editCustomPrompt() {
        customPromptWindowController.show(configService: configService)
    }

    // MARK: - Hotkey Mode

    func setHotkeyMode(_ mode: HotkeyMode) {
        configService.activeHotkeyMode = mode
        updateHotkeyConfig()
        sendNotification(title: "Mode Changed", body: "Now using \(mode.displayName)")
    }

    // MARK: - Language

    func setLanguage(_ language: Language) {
        configService.language = language
        sendNotification(title: "Language Changed", body: "Now using \(language.displayName)")
    }

    // MARK: - Whisper Model

    func setWhisperModel(_ model: WhisperModel) {
        configService.whisperModel = model.rawValue
        sendNotification(
            title: "Model Changed",
            body: "Switched to \(model.displayName). Restart app to load new model."
        )
    }

    // MARK: - TTS Voice

    var ttsVoice: KokoroVoice {
        ttsService.voice
    }

    func setTtsVoice(_ voice: KokoroVoice) {
        ttsService.voice = voice
        sendNotification(title: "Voice Changed", body: "Now using \(voice.displayName)")
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
        hotkeyManager.stopRecordingHotkey()
    }

    func closeHotkeyWindow() {
        hotkeyWindowController.close()
    }

    private func updateHotkeyConfig() {
        hotkeyManager.updateConfig(configService.activeHotkey, mode: configService.activeHotkeyMode)
        hotkeyManager.updateTtsConfig(configService.ttsHotkey)
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
        guard await ttsService.checkAvailable() else {
            sendNotification(
                title: "TTS Not Available",
                body: "TTS server not running. Reopen Dua Talk to set up Text-to-Speech."
            )
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

    private func sendNotification(title: String, body: String) {
        guard canUseNotifications else {
            AppLogger.general.info("[\(title)] \(body)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Dua Talk"
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

    deinit {
        hotkeyManager.stop()
    }
}

// MARK: - HotkeyManagerDelegate

extension MenuBarViewModel: HotkeyManagerDelegate {
    nonisolated func hotkeyPressed() {
        Task { @MainActor in
            if configService.activeHotkeyMode == .toggle {
                toggleRecording()
            } else {
                startRecording()
            }
        }
    }

    nonisolated func hotkeyReleased() {
        Task { @MainActor in
            if configService.activeHotkeyMode == .pushToTalk {
                stopRecording()
            }
        }
    }

    nonisolated func hotkeyRecorded(modifiers: [ModifierKey], key: String?) {
        Task { @MainActor in
            guard let mode = recordingHotkeyFor else { return }

            let hotkey = HotkeyConfig(modifiers: modifiers, key: key)
            configService.setHotkey(hotkey, for: mode)
            updateHotkeyConfig()

            isRecordingHotkey = false
            recordingHotkeyFor = nil
            hotkeyManager.stopRecordingHotkey()

            sendNotification(
                title: "Hotkey Set",
                body: "\(mode.displayName) hotkey set to \(hotkey.displayString)"
            )
        }
    }

    nonisolated func hotkeyManagerDidFailToStart(_ error: String) {
        Task { @MainActor in
            sendNotification(title: "Hotkey Error", body: error)
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
