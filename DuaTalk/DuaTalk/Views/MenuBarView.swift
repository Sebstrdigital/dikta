import SwiftUI

/// Main menu bar view
struct MenuBarView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        Group {
            // Recording control
            Button(action: { viewModel.toggleRecording() }) {
                Text(viewModel.appState == .recording ? "Stop Recording" : "Start Recording")
            }
            .disabled(viewModel.appState == .loading || viewModel.appState == .processing)

            Divider()

            // History submenu
            HistoryMenu(viewModel: viewModel)

            Divider()

            // Output mode submenu
            ModeMenu(viewModel: viewModel)

            // Settings submenu
            SettingsMenu(viewModel: viewModel)

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

/// Output mode submenu
struct ModeMenu: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
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

            // Hotkey configuration - opens a window
            let toggleHotkey = viewModel.configService.getHotkey(for: .toggle)
            Button("Set Toggle Hotkey... (\(toggleHotkey.displayString))") {
                viewModel.startRecordingHotkey(for: .toggle)
            }

            let pttHotkey = viewModel.configService.getHotkey(for: .pushToTalk)
            Button("Set Push-to-Talk Hotkey... (\(pttHotkey.displayString))") {
                viewModel.startRecordingHotkey(for: .pushToTalk)
            }
        }
    }
}
