import Foundation
import AppKit
import Carbon.HIToolbox

/// Service for clipboard operations and auto-paste.
///
/// Not `final` so tests can substitute a subclass that records paste calls
/// instead of posting real CGEvents and clobbering the developer's clipboard.
class ClipboardManager {
    /// Modifiers that, if still physically held when output is posted, turn
    /// typed characters into shortcuts (e.g. ⌥⌘N opening a new window).
    static let outputBlockingModifiers: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn
    ]

    /// Reads the physical modifier state. Injectable so tests can simulate
    /// a hotkey still being held.
    private let modifierFlags: () -> CGEventFlags

    init(modifierFlags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) }) {
        self.modifierFlags = modifierFlags
    }

    /// Runs `body` on the main queue once no output-blocking modifier is held,
    /// or after `timeout` as a fallback.
    ///
    /// A modifier-only toggle hotkey (e.g. ⌥⌘) fires on press, so with a fast
    /// engine the transcript is ready while the user's fingers are still on
    /// the keys. Posting keystrokes then merges the held modifiers into every
    /// character. Polls asynchronously so the main thread (and the hotkey
    /// event tap) stays responsive while waiting.
    func whenModifiersReleased(
        timeout: TimeInterval = 1.5,
        pollInterval: TimeInterval = 0.02,
        _ body: @escaping () -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        func check() {
            let held = modifierFlags().intersection(Self.outputBlockingModifiers)
            if held.isEmpty {
                body()
            } else if Date() >= deadline {
                AppLogger.general.debug("Modifiers still held after \(timeout)s, outputting anyway")
                body()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { check() }
            }
        }

        DispatchQueue.main.async { check() }
    }

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
                // A .hidSystemState source stamps the currently held modifiers
                // onto the event; clear them so a held key can't make a shortcut.
                keyDown.flags = []
                keyDown.post(tap: .cghidEventTap)
            }

            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.flags = []
                keyUp.post(tap: .cghidEventTap)
            }

            // Small delay between keystrokes for reliability
            usleep(1000) // 1ms
        }
    }

    /// Output text by typing it directly (no clipboard)
    func pasteText(_ text: String) {
        // Type text directly - bypasses clipboard entirely
        whenModifiersReleased { [weak self] in
            self?.typeText(text)
            AppLogger.general.debug("Typed \(text.count) characters directly")
        }
    }

    /// Output multi-line text via the pasteboard and Cmd+V, preserving line
    /// breaks. `pasteText` types characters one by one and deliberately
    /// flattens newlines to spaces, which destroys the structure of a rendered
    /// debrief summary, so that path can't be reused here.
    ///
    /// The previous clipboard contents are put back after a short delay, once
    /// the receiving app has had time to read the pasteboard.
    func pasteMultiline(_ text: String) {
        whenModifiersReleased { [weak self] in
            guard let self else { return }
            let previous = self.getText()

            self.copy(text)

            // Same 0.05 s settle as formatSelection: Cmd+V posted in the same
            // runloop turn as the pasteboard write can land before the receiving
            // app sees the new contents, pasting whatever was there before.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.simulatePaste()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, let previous else { return }
                    self.copy(previous)
                }
            }

            AppLogger.general.debug("Pasted \(text.count) characters via pasteboard")
        }
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

            // Infer only from the selected text. Ambiguous, mixed, and
            // unsupported text deliberately uses heuristic-only splitting.
            let language = TextLanguageInference.infer(from: selectedText)
            let formatted = FormatterEngine().format(selectedText, style: style, language: language)

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
