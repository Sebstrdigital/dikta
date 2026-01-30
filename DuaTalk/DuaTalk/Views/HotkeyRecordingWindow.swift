import SwiftUI
import AppKit

/// Window controller for hotkey recording
@MainActor
final class HotkeyRecordingWindowController {
    private var window: NSWindow?
    private var hostingView: NSHostingView<HotkeyRecordingView>?
    private var windowDelegate: WindowDelegate?
    private weak var viewModel: MenuBarViewModel?

    func show(for mode: HotkeyMode, viewModel: MenuBarViewModel) {
        // Close existing window if any
        close()

        self.viewModel = viewModel

        let contentView = HotkeyRecordingView(mode: mode, viewModel: viewModel) { [weak self] in
            self?.close()
        }

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 140)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set \(mode.displayName) Hotkey"
        window.contentView = hostingView
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false

        // Handle window close - store delegate to keep it alive
        let delegate = WindowDelegate { [weak self] in
            Task { @MainActor in
                self?.viewModel?.cancelHotkeyRecording()
            }
        }
        self.windowDelegate = delegate
        window.delegate = delegate

        self.window = window
        self.hostingView = hostingView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
        hostingView = nil
        windowDelegate = nil
    }
}

private class WindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// View for hotkey recording
struct HotkeyRecordingView: View {
    let mode: HotkeyMode
    @ObservedObject var viewModel: MenuBarViewModel
    let onDismiss: () -> Void

    @State private var hasRecordedHotkey = false

    var body: some View {
        VStack(spacing: 16) {
            Text(hasRecordedHotkey ? "Hotkey recorded" : "Press your desired key combination")
                .font(.headline)

            let hotkey = viewModel.configService.getHotkey(for: mode)

            if viewModel.isRecordingHotkey {
                Text("Waiting for keys...")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)
            } else {
                Text(hotkey.displayString.isEmpty ? "Not set" : hotkey.displayString)
                    .font(.title)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(hasRecordedHotkey ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                    .cornerRadius(8)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    viewModel.cancelHotkeyRecording()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                if hasRecordedHotkey {
                    Button("Try Again") {
                        hasRecordedHotkey = false
                        viewModel.startRecordingHotkeyDirect(for: mode)
                    }

                    Button("Save") {
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 320, height: 140)
        .onAppear {
            viewModel.startRecordingHotkeyDirect(for: mode)
        }
        .onChange(of: viewModel.isRecordingHotkey) { _, isRecording in
            if !isRecording && !hasRecordedHotkey {
                hasRecordedHotkey = true
            }
        }
    }
}
