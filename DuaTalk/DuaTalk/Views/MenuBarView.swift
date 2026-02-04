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

            // Quit
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
            // Hotkey mode selection
            Button(action: { viewModel.setHotkeyMode(.toggle) }) {
                HStack {
                    Text("Toggle Mode")
                    if viewModel.configService.activeHotkeyMode == .toggle {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button(action: { viewModel.setHotkeyMode(.pushToTalk) }) {
                HStack {
                    Text("Push-to-Talk Mode")
                    if viewModel.configService.activeHotkeyMode == .pushToTalk {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

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
        WhisperModel(rawValue: viewModel.configService.whisperModel) ?? .base
    }

    var body: some View {
        Menu("Advanced") {
            // Output mode
            Menu("Mode: \(viewModel.configService.outputMode.displayName)") {
                ForEach(OutputMode.allCases, id: \.self) { mode in
                    Button(action: {
                        Task {
                            await viewModel.setOutputMode(mode)
                        }
                    }) {
                        HStack {
                            Text(mode.displayName)
                            if viewModel.configService.outputMode == mode {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

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
