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
        print("[ClipboardManager] Typed \(text.count) characters directly")
    }
}
