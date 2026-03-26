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
                Text("Processing...")
                    .foregroundColor(.secondary)
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

/// Write in (language) submenu
struct WriteInMenu: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        Menu("Write in: \(viewModel.configService.language.displayName)") {
            ForEach(Language.allCases, id: \.self) { language in
                let isEnabled = viewModel.configService.isLanguageEnabled(language)
                let isActive = viewModel.configService.language == language
                Button(action: {
                    viewModel.setLanguage(language)
                }) {
                    HStack {
                        Text(language.displayName)
                            .foregroundColor(isEnabled ? .primary : .secondary)
                        if isActive {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }
}

/// Advanced settings submenu
struct AdvancedMenu: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @EnvironmentObject var sparkle: SparkleController

    private var currentModel: WhisperModel {
        WhisperModel(rawValue: viewModel.configService.whisperModel) ?? .small
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

            Menu("Whisper Model: \(currentModel.displayName)") {
                ForEach(WhisperModel.allCases, id: \.self) { model in
                    Button(action: {
                        viewModel.setWhisperModel(model)
                    }) {
                        HStack {
                            Text(model.displayName)
                            if currentModel == model {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
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
