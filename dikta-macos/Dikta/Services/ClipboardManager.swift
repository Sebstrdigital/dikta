import Foundation
import AppKit
import Carbon.HIToolbox

/// Service for clipboard operations and auto-paste
final class ClipboardManager {
    /// Copy text to the system clipboard
    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Get text from the system clipboard
    func getText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Type text directly by simulating keystrokes (bypasses clipboard entirely)
    func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)

        // Replace newlines with spaces to avoid triggering send in chat apps
        let safeText = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        for char in safeText {
            // Use Unicode input for characters
            var unicodeChar = Array(String(char).utf16)

            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: unicodeChar.count, unicodeString: &unicodeChar)
                keyDown.post(tap: .cghidEventTap)
            }

            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.post(tap: .cghidEventTap)
            }

            // Small delay between keystrokes for reliability
            usleep(1000) // 1ms
        }
    }

    /// Output text by typing it directly (no clipboard)
    func pasteText(_ text: String) {
        // Type text directly - bypasses clipboard entirely
        typeText(text)
        AppLogger.general.debug("Typed \(text.count) characters directly")
    }

    /// Simulate Cmd+C keystroke to copy selection
    func simulateCopy() {
        simulateKeystroke(keyCode: 8, modifierFlags: .maskCommand) // 8 = "c"
    }

    /// Simulate Cmd+V keystroke to paste clipboard
    func simulatePaste() {
        simulateKeystroke(keyCode: 9, modifierFlags: .maskCommand) // 9 = "v"
    }

    private func simulateKeystroke(keyCode: CGKeyCode, modifierFlags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        keyDown.flags = modifierFlags
        keyUp.flags = modifierFlags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Copy selection, format it, paste it back
    func formatSelection(style: FormatterStyle) {
        // Save current pasteboard to restore if needed
        let previousContents = getText()
        let previousChangeCount = NSPasteboard.general.changeCount

        // Simulate Cmd+C
        simulateCopy()

        // Wait for pasteboard to update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            let newChangeCount = NSPasteboard.general.changeCount

            // Check if pasteboard actually changed (something was selected)
            guard newChangeCount != previousChangeCount,
                    let selectedText = getText(),
                    !selectedText.isEmpty else {
                AppLogger.general.debug("Format: no text selected")
                return
            }

            // Format
            let formatted = FormatterEngine().format(selectedText, style: style)

            // Write formatter text to pasteboard
            copy(formatted)

            // Small delay then paste
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.simulatePaste()
                AppLogger.general.debug("Formatted \(selectedText.count) -> \(formatted.count) chars")
            }
        }
    }
}
