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

    var icon: String {
        switch self {
        case .idle: return "mic"
        case .loading: return "hourglass"
        case .recording: return "record.circle.fill"
        case .processing: return "hourglass"
        }
    }

    var iconEmoji: String {
        switch self {
        case .idle: return "🎤"
        case .loading: return "⏳"
        case .recording: return "🔴"
        case .processing: return "⏳"
        }
    }
}

/// ViewModel for the menu bar app
@MainActor
final class MenuBarViewModel: ObservableObject {
    // State
    @Published var appState: AppState = .loading
    @Published var isOllamaAvailable = false

    // Services
    let configService: ConfigService
    private var cancellables = Set<AnyCancellable>()
    private let transcriber: Transcriber
    private let llmService: LLMService
    private let audioRecorder: AudioRecorder
    private let audioFeedback: AudioFeedback
    private let clipboardManager: ClipboardManager
    private let hotkeyManager: HotkeyManager

    // Hotkey recording state
    @Published var isRecordingHotkey = false
    @Published var recordingHotkeyFor: HotkeyMode?

    // Hotkey recording window
    let hotkeyWindowController = HotkeyRecordingWindowController()

    init() {
        self.configService = ConfigService.shared
        self.transcriber = Transcriber(modelName: configService.whisperModel)
        self.llmService = LLMService(model: configService.llmModel)
        self.audioRecorder = AudioRecorder()
        self.audioFeedback = AudioFeedback()
        self.clipboardManager = ClipboardManager()
        self.hotkeyManager = HotkeyManager()

        // Set up hotkey delegate
        hotkeyManager.delegate = self

        // Update hotkey config
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

        // Check microphone permission
        let hasMicPermission = await AudioRecorder.checkPermission()
        if !hasMicPermission {
            sendNotification(title: "Permission Required", body: "Please grant Microphone access in System Preferences")
        }

        // Check Ollama availability
        isOllamaAvailable = await llmService.checkAvailable()

        // If output mode requires Ollama but it's not available, fall back to raw
        if configService.outputMode.requiresOllama && !isOllamaAvailable {
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
            // Transcribe
            let rawText = try await transcriber.transcribe(samples)

            // Format with LLM if needed
            let outputMode = configService.outputMode
            var finalText = rawText

            if outputMode.requiresOllama {
                if isOllamaAvailable {
                    finalText = try await llmService.format(text: rawText, mode: outputMode)
                }
                // If Ollama not available, use raw text
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

    func setOutputMode(_ mode: OutputMode) async {
        if mode.requiresOllama && !isOllamaAvailable {
            // Re-check Ollama
            isOllamaAvailable = await llmService.checkAvailable()

            if !isOllamaAvailable {
                sendNotification(
                    title: "Ollama Required",
                    body: "Enhanced modes require Ollama. Install from ollama.com and run: ollama pull gemma3"
                )
                return
            }
        }

        configService.outputMode = mode
        sendNotification(title: "Mode Changed", body: "Now using \(mode.displayName) mode")
    }

    // MARK: - Hotkey Mode

    func setHotkeyMode(_ mode: HotkeyMode) {
        configService.activeHotkeyMode = mode
        updateHotkeyConfig()
        sendNotification(title: "Mode Changed", body: "Now using \(mode.displayName)")
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
    }

    // MARK: - Notifications

    private var canUseNotifications: Bool {
        // UNUserNotificationCenter requires a proper app bundle
        Bundle.main.bundleIdentifier != nil
    }

    private func sendNotification(title: String, body: String) {
        guard canUseNotifications else {
            print("[\(title)] \(body)")
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
}
