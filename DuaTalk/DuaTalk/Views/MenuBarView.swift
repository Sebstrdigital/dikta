import SwiftUI

/// Main menu bar view
struct MenuBarView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        Group {
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

            // Settings submenu
            SettingsMenu(viewModel: viewModel)

            // Advanced submenu
            AdvancedMenu(viewModel: viewModel)

            Divider()

            Button("Setup...") {
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

/// Settings submenu
struct SettingsMenu: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        Menu("Settings") {
            // Hotkey configuration
            let toggleHotkey = viewModel.configService.getHotkey(for: .toggle)
            Button("Set Toggle Hotkey... (\(toggleHotkey.displayString))") {
                viewModel.startRecordingHotkey(for: .toggle)
            }

            let pttHotkey = viewModel.configService.getHotkey(for: .pushToTalk)
            Button("Set Push-to-Talk Hotkey... (\(pttHotkey.displayString))") {
                viewModel.startRecordingHotkey(for: .pushToTalk)
            }

            Divider()

            // TTS hotkey configuration
            let ttsHotkey = viewModel.configService.getHotkey(for: .textToSpeech)
            Button("Set Read Aloud Hotkey... (\(ttsHotkey.displayString))") {
                viewModel.startRecordingHotkey(for: .textToSpeech)
            }
        }
    }
}

/// Advanced settings submenu
struct AdvancedMenu: View {
    @ObservedObject var viewModel: MenuBarViewModel

    private var currentModel: WhisperModel {
        WhisperModel(rawValue: viewModel.configService.whisperModel) ?? .small
    }

    var body: some View {
        Menu("Advanced") {
            // Language
            Menu("Language: \(viewModel.configService.language.displayName)") {
                ForEach(Language.allCases, id: \.self) { language in
                    Button(action: {
                        viewModel.setLanguage(language)
                    }) {
                        HStack {
                            Text(language.displayName)
                            if viewModel.configService.language == language {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            // Whisper model
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

            // TTS Voice
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
