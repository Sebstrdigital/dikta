import SwiftUI

/// Main menu bar view
struct MenuBarView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @EnvironmentObject var sparkle: SparkleController

    var body: some View {
        Group {
            // Update available badge (US-004): persistent indicator at top of menu
            if sparkle.updateAvailable, let version = sparkle.pendingVersion {
                Button(action: { sparkle.checkForUpdates() }) {
                    Text("Update Available (v\(version))")
                }
                Divider()
            }

            // Status indicator when active
            if viewModel.appState == .recording {
                Button(action: { viewModel.toggleRecording() }) {
                    Text("Stop Recording")
                }
            } else if viewModel.appState == .speaking {
                Button(action: { viewModel.stopSpeaking() }) {
                    Text("Stop Speaking")
                }
            } else if viewModel.appState == .processing {
                if viewModel.isSummarizing, let status = viewModel.debriefStatus {
                    Text(status)
                        .foregroundColor(.secondary)
                } else {
                    Text("Processing...")
                        .foregroundColor(.secondary)
                }
            } else if viewModel.appState == .loading {
                if let progress = viewModel.downloadProgress {
                    Text("Downloading model… \(Int(progress * 100))%")
                        .foregroundColor(.secondary)
                } else {
                    Text("Loading model...")
                        .foregroundColor(.secondary)
                }
            }

            // History submenu
            HistoryMenu(viewModel: viewModel)

            Divider()

            // Hotkeys submenu
            HotkeysMenu(viewModel: viewModel)

            // Audio submenu
            AudioMenu(viewModel: viewModel)

            // Write in (language) submenu
            WriteInMenu(viewModel: viewModel)

            // Post-meeting debrief submenu
            DebriefMenu(viewModel: viewModel)

            // Advanced submenu (includes update controls - US-003)
            AdvancedMenu(viewModel: viewModel)

            Divider()

            Button("About") {
                OnboardingWindowController.shared.show()
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

/// History submenu
struct HistoryMenu: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        Menu("History") {
            if viewModel.configService.history.isEmpty {
                Text("No history yet")
                    .foregroundColor(.secondary)
            } else {
                ForEach(viewModel.configService.history) { item in
                    Button(item.preview) {
                        viewModel.pasteHistoryItem(item)
                    }
                }
            }
        }
    }
}

/// Hotkeys submenu
struct HotkeysMenu: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        Menu("Hotkeys") {
            ForEach(HotkeyMode.allCases, id: \.self) { mode in
                let hotkey = viewModel.configService.getHotkey(for: mode)
                Button("Set \(mode.displayName) Hotkey... (\(hotkey.displayString))") {
                    viewModel.startRecordingHotkey(for: mode)
                }
            }
        }
    }
}

/// Audio submenu
struct AudioMenu: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        Menu("Audio") {
            Button(action: { viewModel.toggleMuteSounds() }) {
                HStack {
                    Text("Mute Sounds")
                    if viewModel.configService.muteSounds {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button(action: { viewModel.toggleMuteNotifications() }) {
                HStack {
                    Text("Mute Notifications")
                    if viewModel.configService.muteNotifications {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            Menu("Mic Sensitivity: \(viewModel.configService.micSensitivity.displayName)") {
                ForEach(MicSensitivity.allCases, id: \.self) { sensitivity in
                    Button(action: {
                        viewModel.setMicSensitivity(sensitivity)
                    }) {
                        HStack {
                            Text(sensitivity.displayName)
                            if viewModel.configService.micSensitivity == sensitivity {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Post-meeting debrief submenu
struct DebriefMenu: View {
    @ObservedObject var viewModel: MenuBarViewModel

    /// Foundation Models only exists on macOS 26 and later; on anything older
    /// the engine is listed but not selectable.
    private var appleIntelligenceAvailable: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    private func displayName(for kind: DebriefEngineKind) -> String {
        switch kind {
        case .auto: return "Auto"
        case .foundationModels: return "Apple Intelligence (macOS 26)"
        case .ollama: return "Ollama (local)"
        case .heuristic: return "Heuristic"
        }
    }

    var body: some View {
        Menu("Debrief") {
            Button(action: { viewModel.toggleDebriefMode() }) {
                HStack {
                    Text("Debrief mode")
                    if viewModel.configService.debriefModeEnabled {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button("Load audio file…") {
                viewModel.loadAudioFileFromPanel()
            }
            .disabled(viewModel.appState == .recording || viewModel.isSummarizing)

            Divider()

            Menu("Engine") {
                ForEach(DebriefEngineKind.allCases, id: \.self) { kind in
                    Button(action: { viewModel.setDebriefEngine(kind) }) {
                        HStack {
                            Text(displayName(for: kind))
                            if viewModel.configService.debriefEngine == kind {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(kind == .foundationModels && !appleIntelligenceAvailable)
                }
            }

            Divider()

            Button("Open Dikta folder") {
                viewModel.openDebriefFolder()
            }
        }
    }
}

/// Write in (language) submenu
struct WriteInMenu: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        Menu("Write in: \(viewModel.configService.language.menuBarCode)") {
            ForEach(Language.allCases, id: \.self) { language in
                let isEnabled = viewModel.configService.isLanguageEnabled(language)
                let isLastEnabled = viewModel.configService.enabledLanguages.count == 1 && isEnabled
                Button(action: {
                    viewModel.toggleLanguage(language)
                }) {
                    HStack {
                        Text(language.displayName)
                        if isEnabled {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(isLastEnabled)
            }
        }
    }
}

/// Advanced settings submenu
struct AdvancedMenu: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @EnvironmentObject var sparkle: SparkleController

    /// The persisted preference — used for the submenu's checkmark, which
    /// reflects what the user picked even while Svenska keeps a different
    /// model (KB-Whisper) actually loaded.
    private var currentModel: WhisperModel {
        WhisperModel(rawValue: viewModel.configService.whisperModel) ?? .small
    }

    /// What's actually loaded in the transcription engine right now — shown in
    /// the submenu title so e.g. "Whisper Model: KB-Whisper Small (Svenska)"
    /// is visible while Svenska is active, even though the preference (and
    /// checkmark) still point at whatever the user picked. Nil only in the
    /// rare case where every load attempt, including the last-resort `.small`
    /// fallback, has failed.
    private var loadedModelTitle: String {
        viewModel.loadedModel?.displayName ?? "Not Loaded"
    }

    var body: some View {
        Menu("Advanced") {
            Button(action: { viewModel.toggleLaunchAtLogin() }) {
                HStack {
                    Text("Start at Login")
                    if viewModel.launchAtLogin {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            Button("Check for Updates...") {
                sparkle.checkForUpdates()
            }

            Divider()

            Menu("Whisper Model: \(loadedModelTitle)") {
                ForEach(WhisperModel.allCases.filter(\.isUserSelectable).sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.self) { model in
                    Button(action: {
                        viewModel.setWhisperModel(model)
                    }) {
                        HStack {
                            Text(model.isRecommended ? "\(model.displayName) ★" : model.displayName)
                            if currentModel == model {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if viewModel.configService.language == .swedish {
                    Divider()
                    Button(action: {}) {
                        Text("Svenska uses KB-Whisper Small automatically")
                    }
                    .disabled(true)
                }
            }

            Button(action: { viewModel.toggleDiagnosticLogging() }) {
                HStack {
                    Text("Diagnostic Logging")
                    if viewModel.configService.diagnosticLogging {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Menu("Voice: \(viewModel.ttsVoice.displayName)") {
                ForEach(KokoroVoice.allCases, id: \.self) { voice in
                    Button(action: {
                        viewModel.setTtsVoice(voice)
                    }) {
                        HStack {
                            Text(voice.displayName)
                            if viewModel.ttsVoice == voice {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }
}
