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

    // Hotkey recording state
    @Published var isRecordingHotkey = false
    @Published var recordingHotkeyFor: HotkeyMode?

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

        activeRecordingMode = nil
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
            let text = try await transcriber.transcribe(samples, language: language.whisperCode)

            // Check for silence/empty output from Whisper
            let silenceIndicators = ["[silence]", "[blank_audio]", "[no speech]", "(silence)", "[ silence ]"]
            let lowerText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            if lowerText.isEmpty || silenceIndicators.contains(where: { lowerText.contains($0) }) {
                sendNotification(title: "No Speech", body: "No speech detected in recording", isRoutine: true)
                appState = .idle
                return
            }

            await outputText(text)

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
        sendNotification(title: "Pasted", body: preview, isRoutine: true)
    }

    /// Paste a history item
    func pasteHistoryItem(_ item: HistoryItem) {
        clipboardManager.pasteText(item.text)
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

    // MARK: - Language

    func setLanguage(_ language: Language) {
        configService.language = language
        sendNotification(title: "Language Changed", body: "Now using \(language.displayName)", isRoutine: true)
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
            configService.setHotkey(hotkey, for: mode)
            updateHotkeyConfig()

            isRecordingHotkey = false
            recordingHotkeyFor = nil
            hotkeyManager.stopRecordingHotkey()

            sendNotification(
                title: "Hotkey Set",
                body: "\(mode.displayName) hotkey set to \(hotkey.displayString)",
                isRoutine: true
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
