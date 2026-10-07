import AppKit
import ApplicationServices

/// Materialized data for every item and advertised format, not just plain text.
typealias SelectionClipboardContents = [[NSPasteboard.PasteboardType: Data]]

@MainActor
protocol SelectionClipboard: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> SelectionClipboardContents?
    func text() -> String?
}

@MainActor
private final class SystemSelectionClipboard: SelectionClipboard {
    private var pasteboard: NSPasteboard { .general }
    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> SelectionClipboardContents? {
        var result: SelectionClipboardContents = []
        for item in pasteboard.pasteboardItems ?? [] {
            var formats: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // If a promised format cannot be materialized, do not risk losing it.
                guard let data = item.data(forType: type) else { return nil }
                formats[type] = data
            }
            result.append(formats)
        }
        return result
    }

    func text() -> String? { pasteboard.string(forType: .string) }
}

/// Closed labels and numeric/boolean metadata only: no payload can enter this sink.
struct SelectionCaptureDiagnostic {
    enum Stage: String {
        case axApplication, axElement, axText, axUnavailable, axSuccess
        case clipboardStart, concurrent, cancelled, noFocus, focusChanged
        case modifierWait, modifierDeadline, modifiersReleased, modifiersRepressed
        case snapshotUnavailable, snapshotMutation, snapshotReady, copyPosted
        case copyWaitComplete, noText, whitespace, readInterference
        case stabilityInterference, clipboardSuccess, pauseFailed
    }
    let stage: Stage
    var count: Int? = nil
    var expectedCount: Int? = nil
    var status: Int32? = nil
    var typeID: UInt? = nil
    var present: Bool? = nil
    var empty: Bool? = nil

    var message: String {
        var fields = ["SELECTION_CAPTURE", "stage=\(stage.rawValue)"]
        if let count { fields.append("count=\(count)") }
        if let expectedCount { fields.append("expectedCount=\(expectedCount)") }
        if let status { fields.append("status=\(status)") }
        if let typeID { fields.append("typeID=\(typeID)") }
        if let present { fields.append("present=\(present)") }
        if let empty { fields.append("empty=\(empty)") }
        return fields.joined(separator: " ")
    }
}

/// Service for getting selected text from any application.
@MainActor
final class TextSelectionService {
    private let clipboard: any SelectionClipboard
    private let copy: () -> Void
    private let modifiers: () -> CGEventFlags
    private let focusedApplication: () -> pid_t?
    private let now: () -> TimeInterval
    private let pause: (TimeInterval) async throws -> Void
    private var capturing = false
    private let diagnostic: (SelectionCaptureDiagnostic) -> Void
    private let axRead: (AXUIElement, CFString) -> (AXError, AnyObject?)

    private static func readAX(_ element: AXUIElement, _ attribute: CFString) -> (AXError, AnyObject?) {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (status, value)
    }

    private func emit(_ stage: SelectionCaptureDiagnostic.Stage, count: Int? = nil, expectedCount: Int? = nil) {
        diagnostic(SelectionCaptureDiagnostic(stage: stage, count: count, expectedCount: expectedCount))
    }

    init(clipboardManager: ClipboardManager) {
        diagnostic = { event in
            // Notice is retained by unified logging in Release; no debug/config toggle needed.
            AppLogger.tts.notice("\(event.message, privacy: .public)")
        }
        axRead = Self.readAX
        clipboard = SystemSelectionClipboard()
        copy = { clipboardManager.simulateCopy() }
        modifiers = { CGEventSource.flagsState(.hidSystemState) }
        focusedApplication = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        now = { ProcessInfo.processInfo.systemUptime }
        pause = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    }

    /// Entirely injected capture environment for offline tests (no system pasteboard/events).
    init(
        clipboard: any SelectionClipboard,
        copy: @escaping () -> Void,
        modifiers: @escaping () -> CGEventFlags,
        focusedApplication: @escaping () -> pid_t?,
        now: @escaping () -> TimeInterval,
        pause: @escaping (TimeInterval) async throws -> Void,
        diagnostic: @escaping (SelectionCaptureDiagnostic) -> Void = { _ in },
        axRead: @escaping (AXUIElement, CFString) -> (AXError, AnyObject?) = { _, _ in (.notImplemented, nil) }
    ) {
        self.clipboard = clipboard
        self.copy = copy
        self.modifiers = modifiers
        self.focusedApplication = focusedApplication
        self.now = now
        self.pause = pause
        self.diagnostic = diagnostic
        self.axRead = axRead
    }

    /// Get currently selected text using Accessibility API
    func getSelectedText() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()

        func recordAX(_ stage: SelectionCaptureDiagnostic.Stage, _ status: AXError, _ value: AnyObject?) {
            diagnostic(SelectionCaptureDiagnostic(
                stage: stage, status: status.rawValue,
                typeID: value.map { CFGetTypeID($0 as CFTypeRef) },
                present: value != nil, empty: (value as? String).map { $0.isEmpty }
            ))
        }

        let (appResult, focusedApp) = axRead(systemWideElement, kAXFocusedApplicationAttribute as CFString)
        recordAX(.axApplication, appResult, focusedApp)
        guard appResult == .success, let focusedApp else {
            emit(.axUnavailable)
            return nil
        }
        // Verify CF type before casting — guards against Accessibility API returning
        // an unexpected type on malformed element trees, returning nil instead of crashing.
        guard CFGetTypeID(focusedApp as CFTypeRef) == AXUIElementGetTypeID() else {
            emit(.axUnavailable)
            return nil
        }
        let appElement = focusedApp as! AXUIElement

        let (elementResult, focusedElement) = axRead(appElement, kAXFocusedUIElementAttribute as CFString)
        recordAX(.axElement, elementResult, focusedElement)
        guard elementResult == .success, let focusedElement else {
            emit(.axUnavailable)
            return nil
        }
        guard CFGetTypeID(focusedElement as CFTypeRef) == AXUIElementGetTypeID() else {
            emit(.axUnavailable)
            return nil
        }
        let element = focusedElement as! AXUIElement

        let (textResult, selectedText) = axRead(element, kAXSelectedTextAttribute as CFString)
        recordAX(.axText, textResult, selectedText)

        if textResult == .success, let text = selectedText as? String, !text.isEmpty {
            emit(.axSuccess)
            return text
        }
        emit(.axUnavailable)
        return nil
    }

    /// Best-effort fallback: attempt Cmd+C without clearing, wait asynchronously,
    /// then read current usable text, including pre-copied or old no-selection text.
    /// Change counts detect observable read/stability interference, not writer identity:
    /// an unrelated writer during the wait may supply the text. Never restore historical
    /// contents over an unattributable write; all current formats are left untouched.
    func getSelectedTextViaClipboard(
        modifierTimeout: TimeInterval = 1.5,
        copyWait: TimeInterval = 0.5,
        pollInterval: TimeInterval = 0.02
    ) async -> String? {
        emit(.clipboardStart)
        guard !capturing else { emit(.concurrent); return nil }
        guard !Task.isCancelled else { emit(.cancelled); return nil }
        guard let application = focusedApplication() else { emit(.noFocus); return nil }
        capturing = true
        defer { capturing = false }

        func stillFocused() -> Bool {
            guard !Task.isCancelled else { emit(.cancelled); return false }
            guard focusedApplication() == application else { emit(.focusChanged); return false }
            return true
        }

        let modifierDeadline = now() + modifierTimeout
        do {
            var recordedModifierWait = false
            while !modifiers().intersection(ClipboardManager.outputBlockingModifiers).isEmpty {
                if !recordedModifierWait { emit(.modifierWait); recordedModifierWait = true }
                guard stillFocused() else { return nil }
                guard now() < modifierDeadline else { emit(.modifierDeadline); return nil }
                try await pause(pollInterval)
            }
            guard stillFocused() else { return nil }
            emit(.modifiersReleased)

            // Materialize all advertised formats without clearing or writing. Reject
            // observable snapshot interference, but never use its cached text as the result.
            let originalCount = clipboard.changeCount
            guard clipboard.snapshot() != nil else {
                emit(.snapshotUnavailable, count: originalCount); return nil
            }
            let snapshotCount = clipboard.changeCount
            guard snapshotCount == originalCount else {
                emit(.snapshotMutation, count: snapshotCount, expectedCount: originalCount); return nil
            }
            guard stillFocused() else { return nil }
            guard modifiers().intersection(ClipboardManager.outputBlockingModifiers).isEmpty else {
                emit(.modifiersRepressed); return nil
            }
            emit(.snapshotReady, count: originalCount)
            copy()
            emit(.copyPosted, expectedCount: originalCount)
            let copyDeadline = now() + copyWait

            // Wait the full copy interval even for immediate or unchanged text.
            // Short asynchronous pauses retain responsive focus/cancellation checks.
            while now() < copyDeadline {
                guard stillFocused() else { return nil }
                try await pause(min(pollInterval, copyDeadline - now()))
            }
            guard stillFocused() else { return nil }
            let capturedCount = clipboard.changeCount
            emit(.copyWaitComplete, count: capturedCount, expectedCount: originalCount)
            guard let text = clipboard.text() else { emit(.noText); return nil }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                emit(.whitespace); return nil
            }
            let readCount = clipboard.changeCount
            guard readCount == capturedCount else {
                emit(.readInterference, count: readCount, expectedCount: capturedCount); return nil
            }
            // Yield once to detect a subsequent observable writer. Both changed and
            // unchanged generations must pass this check, and neither is restored.
            try await pause(pollInterval)
            guard stillFocused() else { return nil }
            let stableCount = clipboard.changeCount
            guard stableCount == capturedCount else {
                emit(.stabilityInterference, count: stableCount, expectedCount: capturedCount); return nil
            }
            emit(.clipboardSuccess)
            return text
        } catch {
            // Never log the error description: it is not part of the privacy-safe schema.
            emit(error is CancellationError || Task.isCancelled ? .cancelled : .pauseFailed)
            // Cancellation leaves the current clipboard untouched.
            return nil
        }
    }
}
