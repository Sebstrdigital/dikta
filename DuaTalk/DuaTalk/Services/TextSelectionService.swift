import AppKit
import ApplicationServices

/// Service for getting selected text from any application
final class TextSelectionService {
    private let clipboardManager: ClipboardManager

    init(clipboardManager: ClipboardManager) {
        self.clipboardManager = clipboardManager
    }

    /// Get currently selected text using Accessibility API
    func getSelectedText() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        guard appResult == .success, let app = focusedApp else {
            return nil
        }

        var focusedElement: AnyObject?
        let elementResult = AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard elementResult == .success, let element = focusedElement else {
            return nil
        }

        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText)

        if textResult == .success, let text = selectedText as? String, !text.isEmpty {
            return text
        }
        return nil
    }

    /// Fallback: Copy selected text via Cmd+C and read from clipboard
    func getSelectedTextViaClipboard() -> String? {
        // Save current clipboard
        let original = clipboardManager.getText()

        // Clear clipboard to detect if copy worked
        NSPasteboard.general.clearContents()

        // Simulate Cmd+C
        simulateCopy()

        // Brief delay for clipboard to update
        usleep(100000) // 100ms

        // Get copied text
        let selected = clipboardManager.getText()

        // Restore original clipboard
        if let orig = original {
            clipboardManager.copy(orig)
        }

        return selected
    }

    private func simulateCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyC: CGKeyCode = 8 // 'C' key

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
