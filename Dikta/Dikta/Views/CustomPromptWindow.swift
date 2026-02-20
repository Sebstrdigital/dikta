import SwiftUI
import AppKit

/// Window controller for editing the custom prompt
@MainActor
final class CustomPromptWindowController {
    private var window: NSWindow?
    private var hostingView: NSHostingView<CustomPromptEditorView>?

    func show(configService: ConfigService) {
        // If already showing, just bring to front
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        close()

        let contentView = CustomPromptEditorView(
            initialPrompt: configService.customPrompt,
            onSave: { [weak self] newPrompt in
                configService.customPrompt = newPrompt
                self?.close()
            },
            onCancel: { [weak self] in
                self?.close()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 280)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Custom Prompt"
        window.contentView = hostingView
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false

        self.window = window
        self.hostingView = hostingView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
        hostingView = nil
    }
}

/// View for editing the custom prompt
struct CustomPromptEditorView: View {
    let initialPrompt: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var promptText: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Custom Prompt")
                .font(.headline)

            TextEditor(text: $promptText)
                .font(.body)
                .frame(minHeight: 120)
                .border(Color.gray.opacity(0.3), width: 1)

            Text("This prompt is sent to the LLM along with your dictation.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave(promptText)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: 280)
        .onAppear {
            promptText = initialPrompt
        }
    }
}
