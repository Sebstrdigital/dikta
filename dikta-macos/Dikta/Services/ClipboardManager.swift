import Foundation
import AppKit
import Carbon.HIToolbox

/// Independent, value-only copies of all advertised pasteboard representations.
struct ClipboardSnapshot: Equatable {
    let items: [[String: Data]]

    static func materialize(_ representations: [[(String, Data?)]]) -> ClipboardSnapshot? {
        var items: [[String: Data]] = []
        for representations in representations {
            guard !representations.isEmpty else { return nil }
            var values: [String: Data] = [:]
            for (type, data) in representations {
                // File promises contain provider-backed capabilities, not just
                // durable file URLs. Copying their descriptor bytes cannot
                // recreate the provider; preserve the board by skipping paste.
                let promises = ["com.apple.pasteboard.promised-file-url",
                                "com.apple.pasteboard.promised-file-content-type",
                                "NSFilesPromisePboardType"]
                guard !promises.contains(type), let data else { return nil }
                values[type] = Data(data)
            }
            items.append(values)
        }
        return ClipboardSnapshot(items: items)
    }

    static func text(_ text: String) -> ClipboardSnapshot {
        ClipboardSnapshot(items: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]])
    }
}

enum ClipboardWriteResult {
    case written(generation: Int)
    case failed(ownedGeneration: Int?)
    case ownershipLost
}

protocol MultilinePasteboard: AnyObject {
    var generation: Int { get }
    func snapshot() -> ClipboardSnapshot?
    /// Compare ownership immediately before mutation; failed writes report any
    /// generation still owned so the caller can attempt safe rollback.
    func replace(with snapshot: ClipboardSnapshot, ifGeneration: Int) -> ClipboardWriteResult
}

final class AppKitMultilinePasteboard: MultilinePasteboard {
    private let board: NSPasteboard

    init(board: NSPasteboard = .general) { self.board = board }
    var generation: Int { board.changeCount }

    func snapshot() -> ClipboardSnapshot? {
        guard let items = board.pasteboardItems else {
            return (board.types ?? []).isEmpty ? ClipboardSnapshot(items: []) : nil
        }
        return ClipboardSnapshot.materialize(items.map { item in
            item.types.map { ($0.rawValue, item.data(forType: $0)) }
        })
    }

    func replace(with snapshot: ClipboardSnapshot, ifGeneration expected: Int) -> ClipboardWriteResult {
        // Prepare every representation before clearing anything. Never silently
        // drop an item or type that cannot be represented by AppKit.
        var items: [NSPasteboardItem] = []
        for values in snapshot.items {
            guard !values.isEmpty else { return .failed(ownedGeneration: nil) }
            let item = NSPasteboardItem()
            for (type, data) in values {
                guard item.setData(data, forType: NSPasteboard.PasteboardType(type)) else {
                    return .failed(ownedGeneration: nil)
                }
            }
            items.append(item)
        }
        guard generation == expected else { return .ownershipLost }
        let clearedGeneration = board.clearContents()
        guard generation == clearedGeneration else { return .ownershipLost }
        guard items.isEmpty || board.writeObjects(items) else {
            return .failed(ownedGeneration: generation == clearedGeneration ? clearedGeneration : nil)
        }
        let writtenGeneration = generation
        // Read back all data, rather than equating a successful API call with
        // ownership of whatever another process might have written meanwhile.
        guard self.snapshot() == snapshot, generation == writtenGeneration else { return .ownershipLost }
        return .written(generation: writtenGeneration)
    }
}

/// Cmd+V is a request, not confirmation from the receiving application.
enum MultilinePasteResult: Equatable {
    case pasteRequested
    case skippedBecauseClipboardChanged
    case skippedBecauseOriginalFormatCouldNotBeSafelySnapshotted
    case skippedBecausePasteboardWriteFailed
}

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

    private let multilineBoard: any MultilinePasteboard
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let postPaste: (() -> Void)?

    private struct PasteOperation {
        let id = UUID()
        let text: String
        let completion: (MultilinePasteResult) -> Void
    }
    private var pendingPastes: [PasteOperation] = []
    private var activePaste: UUID?
    private var pastePosted = false

    init(
        modifierFlags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) },
        multilineBoard: any MultilinePasteboard = AppKitMultilinePasteboard(),
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
        },
        postPaste: (() -> Void)? = nil
    ) {
        self.modifierFlags = modifierFlags
        self.multilineBoard = multilineBoard
        self.schedule = schedule
        self.postPaste = postPaste
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
    func pasteMultiline(_ text: String, completion: @escaping (MultilinePasteResult) -> Void = { _ in }) {
        // Serialize overlapping operations through restoration, so a second
        // operation never mistakes our first generated output for the original.
        pendingPastes.append(PasteOperation(text: text, completion: completion))
        startNextPaste()
    }

    private func startNextPaste() {
        guard activePaste == nil, !pendingPastes.isEmpty else { return }
        let operation = pendingPastes.removeFirst()
        activePaste = operation.id
        pastePosted = false
        whenModifiersReleased { [weak self] in
            guard let self, self.activePaste == operation.id else { return }
            let previousGeneration = self.multilineBoard.generation
            let original = self.multilineBoard.snapshot()
            guard self.multilineBoard.generation == previousGeneration else {
                self.finishPaste(operation, result: .skippedBecauseClipboardChanged)
                return
            }
            guard let original else {
                self.finishPaste(operation, result: .skippedBecauseOriginalFormatCouldNotBeSafelySnapshotted)
                return
            }
            switch self.multilineBoard.replace(with: .text(operation.text), ifGeneration: previousGeneration) {
            case .ownershipLost:
                self.finishPaste(operation, result: .skippedBecauseClipboardChanged)
            case .failed(let ownedGeneration):
                if let ownedGeneration {
                    _ = self.multilineBoard.replace(with: original, ifGeneration: ownedGeneration)
                }
                self.finishPaste(operation, result: .skippedBecausePasteboardWriteFailed)
            case .written(let generation):
                self.schedule(0.05) { [weak self] in
                    guard let self, self.activePaste == operation.id, !self.pastePosted else { return }
                    guard self.multilineBoard.generation == generation else {
                        self.finishPaste(operation, result: .skippedBecauseClipboardChanged)
                        return
                    }
                    self.pastePosted = true
                    if let postPaste = self.postPaste { postPaste() } else { self.simulatePaste() }
                    operation.completion(.pasteRequested)
                    self.schedule(0.5) { [weak self] in
                        guard let self, self.activePaste == operation.id else { return }
                        // The backend rechecks generation at the mutation boundary.
                        _ = self.multilineBoard.replace(with: original, ifGeneration: generation)
                        self.activePaste = nil
                        self.startNextPaste()
                    }
                }
            }
        }
    }

    private func finishPaste(_ operation: PasteOperation, result: MultilinePasteResult) {
        guard activePaste == operation.id else { return }
        activePaste = nil
        operation.completion(result)
        startNextPaste()
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

}
