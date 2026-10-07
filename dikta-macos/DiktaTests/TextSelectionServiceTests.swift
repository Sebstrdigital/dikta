import AppKit
import ApplicationServices
import XCTest
@testable import Dikta

/// All capture dependencies are fake: no developer clipboard, shortcuts, AX, audio or TTS.
@MainActor
final class TextSelectionServiceTests: XCTestCase {
    private final class Clipboard: SelectionClipboard {
        var changeCount = 10
        var contents: SelectionClipboardContents = [[.string: Data("stale".utf8)]]
        var canSnapshot = true
        var textReads = 0
        var onText: (() -> Void)?
        var onSnapshot: (() -> Void)?

        func snapshot() -> SelectionClipboardContents? {
            onSnapshot?()
            return canSnapshot ? contents : nil
        }
        func text() -> String? {
            textReads += 1
            let result = contents.first?[.string].flatMap { String(data: $0, encoding: .utf8) }
            onText?()
            return result
        }
        func write(_ text: String) {
            contents = [[.string: Data(text.utf8)]]
            changeCount += 1
        }
    }

    @MainActor
    private final class Environment {
        let clipboard = Clipboard()
        var time: TimeInterval = 0
        var flags: CGEventFlags = []
        var focus: pid_t? = 42
        var copies = 0
        var pauses = 0
        var onCopy: (() -> Void)?
        var onPause: (() async throws -> Void)?
        var diagnostics: [SelectionCaptureDiagnostic] = []
        var axValues: [(AXError, AnyObject?)] = []
        var stages: [SelectionCaptureDiagnostic.Stage] { diagnostics.map(\.stage) }

        lazy var service = TextSelectionService(
            clipboard: clipboard,
            copy: { [unowned self] in copies += 1; onCopy?() },
            modifiers: { [unowned self] in flags },
            focusedApplication: { [unowned self] in focus },
            now: { [unowned self] in time },
            pause: { [unowned self] interval in
                time += interval
                pauses += 1
                try await onPause?()
                await Task.yield()
            },
            diagnostic: { [unowned self] in diagnostics.append($0) },
            axRead: { [unowned self] _, _ in axValues.removeFirst() }
        )

        func capture() async -> String? {
            await service.getSelectedTextViaClipboard(modifierTimeout: 0.2, copyWait: 0.5, pollInterval: 0.02)
        }
    }

    func testEveryBlockingModifierWaitsForReleaseBeforeCopy() async {
        for flag: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn] {
            let e = Environment()
            e.flags = flag
            e.onPause = {
                XCTAssertEqual(e.copies, 0)
                if e.time >= 0.06 { e.flags = []; e.onPause = nil }
            }
            e.onCopy = {
                XCTAssertTrue(e.flags.isEmpty)
                e.clipboard.write("selected")
            }
            let result = await e.capture()
            XCTAssertEqual(result, "selected")
            XCTAssertEqual(e.copies, 1)
            XCTAssertEqual(e.clipboard.changeCount, 11)
        }
    }

    func testHeldModifierTimeoutNeverPostsCopyOrChangesClipboard() async {
        let e = Environment()
        e.flags = [.maskAlternate, .maskCommand]
        let original = e.clipboard.contents
        let result = await e.capture()
        XCTAssertNil(result)
        XCTAssertEqual(e.copies, 0)
        XCTAssertGreaterThan(e.pauses, 0)
        XCTAssertTrue(e.stages.contains(.modifierWait))
        XCTAssertEqual(e.stages.last, .modifierDeadline)
        XCTAssertEqual(e.clipboard.contents, original)
        XCTAssertEqual(e.clipboard.changeCount, 10)
    }

    func testDelayedCopyBeyondOldHundredMillisecondsSucceeds() async {
        let e = Environment()
        e.onPause = {
            if e.time >= 0.16 { e.clipboard.write("delayed selection"); e.onPause = nil }
        }
        let result = await e.capture()
        XCTAssertEqual(result, "delayed selection")
        XCTAssertEqual(e.copies, 1)
        XCTAssertGreaterThanOrEqual(e.time, 0.5)
        XCTAssertLessThanOrEqual(e.time, 0.53)
        XCTAssertEqual(e.clipboard.text(), "delayed selection")
        XCTAssertEqual(e.clipboard.changeCount, 11)
    }

    func testPreCopiedPiTextWithoutNewWriteIsReadAfterFullWait() async {
        let e = Environment()
        e.clipboard.contents = [[.string: Data("pi auto-copied selection".utf8)]]
        e.clipboard.onText = { XCTAssertGreaterThanOrEqual(e.time, 0.5) }
        let result = await e.service.getSelectedTextViaClipboard()
        XCTAssertEqual(result, "pi auto-copied selection")
        XCTAssertEqual(e.copies, 1)
        XCTAssertEqual(e.clipboard.textReads, 1)
        XCTAssertEqual(e.clipboard.changeCount, 10)
        XCTAssertEqual(e.stages.last, .clipboardSuccess)
        XCTAssertGreaterThanOrEqual(e.time, 0.5)
        XCTAssertLessThanOrEqual(e.time, 0.53)
    }

    func testNoSelectionIntentionallyReturnsOldNonemptyClipboard() async {
        let e = Environment()
        // Ineffective Cmd+C cannot distinguish old text from a pre-copied selection.
        let result = await e.capture()
        XCTAssertEqual(result, "stale")
        XCTAssertEqual(e.clipboard.changeCount, 10)
        XCTAssertGreaterThanOrEqual(e.time, 0.5)
        XCTAssertLessThanOrEqual(e.time, 0.53)
    }

    func testImmediateCopyOfIdenticalTextStillWaitsFullInterval() async {
        let e = Environment()
        e.onCopy = { e.clipboard.write("stale") }
        e.clipboard.onText = { XCTAssertGreaterThanOrEqual(e.time, 0.5) }
        let result = await e.capture()
        XCTAssertEqual(result, "stale")
        XCTAssertEqual(e.clipboard.changeCount, 11)
        XCTAssertGreaterThanOrEqual(e.time, 0.5)
        XCTAssertLessThanOrEqual(e.time, 0.53)
    }

    func testEmptyOrWhitespaceClipboardIsRejectedWhetherChangedOrUnchanged() async {
        for changed in [false, true] {
            for text in ["", " \n\t"] {
                let e = Environment()
                e.clipboard.contents = [[.string: Data(text.utf8)]]
                if changed { e.onCopy = { e.clipboard.write(text) } }
                let result = await e.capture()
                XCTAssertNil(result)
                XCTAssertEqual(e.clipboard.contents, [[.string: Data(text.utf8)]])
                XCTAssertEqual(e.clipboard.changeCount, changed ? 11 : 10)
                XCTAssertEqual(e.stages.last, .whitespace)
                XCTAssertGreaterThanOrEqual(e.time, 0.5)
            }
        }
    }

    func testNonTextClipboardIsRejectedWhetherChangedOrUnchanged() async {
        for changed in [false, true] {
            let e = Environment()
            let image: SelectionClipboardContents = [[.png: Data([1, 2, 3])]]
            e.clipboard.contents = image
            if changed { e.onCopy = { e.clipboard.contents = image; e.clipboard.changeCount += 1 } }
            let result = await e.capture()
            XCTAssertNil(result)
            XCTAssertEqual(e.clipboard.contents, image)
            XCTAssertEqual(e.clipboard.changeCount, changed ? 11 : 10)
            XCTAssertEqual(e.stages.last, .noText)
        }
    }

    func testPreservesAllFormatsAndMultipleItems() async {
        let e = Environment()
        let original: SelectionClipboardContents = [
            [.string: Data("original".utf8), .rtf: Data([0, 1, 255]),
             NSPasteboard.PasteboardType("test.custom"): Data([4, 5])],
            [.png: Data([9, 8, 7]), .fileURL: Data("file:///example".utf8)]
        ]
        e.clipboard.contents = original
        let result = await e.capture()
        XCTAssertEqual(result, "original")
        XCTAssertEqual(e.clipboard.contents, original)
        XCTAssertEqual(e.clipboard.changeCount, 10)
    }

    func testCopyIntoOriginallyEmptyClipboardIsLeftIntact() async {
        let e = Environment()
        e.clipboard.contents = []
        e.onCopy = { e.clipboard.write("selected") }
        let result = await e.capture()
        XCTAssertEqual(result, "selected")
        XCTAssertEqual(e.clipboard.text(), "selected")
        XCTAssertEqual(e.clipboard.changeCount, 11)
    }

    func testUnavailableSnapshotDoesNotCopy() async {
        let e = Environment()
        e.clipboard.canSnapshot = false
        let result = await e.capture()
        XCTAssertNil(result)
        XCTAssertEqual(e.copies, 0)
        XCTAssertEqual(e.clipboard.changeCount, 10)
        XCTAssertEqual(e.stages.last, .snapshotUnavailable)
    }

    func testClipboardWriteDuringModifierWaitIsNotRestoredOverCopy() async {
        let e = Environment()
        e.flags = .maskCommand
        e.onPause = {
            e.clipboard.write("new original")
            e.flags = []
            e.onPause = nil
        }
        e.onCopy = { e.clipboard.write("selected") }
        let result = await e.capture()
        XCTAssertEqual(result, "selected")
        XCTAssertEqual(e.clipboard.text(), "selected")
        XCTAssertEqual(e.clipboard.changeCount, 12)
    }

    func testStabilityInterferenceRejectsChangedAndUnchangedTextWithoutWriting() async {
        for changed in [false, true] {
            let e = Environment()
            if changed { e.onCopy = { e.clipboard.write("selected") } }
            e.onPause = { if e.time > 0.5 { e.clipboard.write("external newer") } }
            let result = await e.capture()
            XCTAssertNil(result)
            XCTAssertEqual(e.clipboard.text(), "external newer")
            XCTAssertEqual(e.clipboard.changeCount, changed ? 12 : 11)
            XCTAssertEqual(e.stages.last, .stabilityInterference)
        }
    }

    func testReadInterferenceRejectsChangedAndUnchangedTextWithoutWriting() async {
        for changed in [false, true] {
            let e = Environment()
            if changed { e.onCopy = { e.clipboard.write("selected") } }
            e.clipboard.onText = { e.clipboard.write("external newer") }
            let result = await e.capture()
            e.clipboard.onText = nil
            XCTAssertNil(result)
            XCTAssertEqual(e.clipboard.text(), "external newer")
            XCTAssertEqual(e.clipboard.changeCount, changed ? 12 : 11)
            XCTAssertEqual(e.stages.last, .readInterference)
        }
    }

    func testExternalMultiFormatWriteDuringWaitIsReadAndNeverOverwritten() async {
        let e = Environment()
        let external: SelectionClipboardContents = [
            [.string: Data("external current".utf8), .rtf: Data([1, 2, 3])],
            [.png: Data([4, 5, 6])]
        ]
        e.onCopy = { e.clipboard.write("selected") }
        e.onPause = {
            if e.time >= 0.3 {
                e.clipboard.contents = external
                e.clipboard.changeCount += 1
                e.onPause = nil
            }
        }
        let result = await e.capture()
        XCTAssertEqual(result, "external current") // Timing does not prove writer identity.
        XCTAssertEqual(e.clipboard.contents, external)
        XCTAssertEqual(e.clipboard.changeCount, 12)
    }

    func testFirstUnrelatedWriterCannotBeAttributedBestEffortLimitation() async {
        let e = Environment()
        // Cmd+C produces nothing, but an unrelated writer arrives first in-window.
        // This intentionally documents the accepted limitation, not perfect attribution.
        e.onPause = { e.clipboard.write("unrelated first writer"); e.onPause = nil }
        let result = await e.capture()
        XCTAssertEqual(result, "unrelated first writer")
        XCTAssertEqual(e.clipboard.text(), "unrelated first writer")
        XCTAssertEqual(e.clipboard.changeCount, 11)
    }

    func testNoFocusedApplicationNeverCopies() async {
        let e = Environment()
        e.focus = nil
        let result = await e.capture()
        XCTAssertNil(result)
        XCTAssertEqual(e.copies, 0)
        XCTAssertEqual(e.stages.last, .noFocus)
    }

    func testFocusChangeBeforeModifierReleaseNeverCopies() async {
        let e = Environment()
        e.flags = .maskCommand
        e.onPause = { e.focus = 99; e.flags = [] }
        let result = await e.capture()
        XCTAssertNil(result)
        XCTAssertEqual(e.copies, 0)
        XCTAssertEqual(e.clipboard.changeCount, 10)
        XCTAssertEqual(e.stages.last, .focusChanged)
    }

    func testFocusChangeWhileWaitingForCopyRejectsText() async {
        let e = Environment()
        e.onPause = { e.focus = 99; e.clipboard.write("other app") }
        let result = await e.capture()
        XCTAssertNil(result)
        XCTAssertEqual(e.clipboard.text(), "other app")
        XCTAssertEqual(e.stages.last, .focusChanged)
        XCTAssertEqual(e.clipboard.changeCount, 11)
    }

    func testFocusChangeDuringStabilityCheckDoesNotRestoreOrReturnText() async {
        let e = Environment()
        e.onCopy = { e.clipboard.write("selected") }
        e.onPause = { if e.time > 0.5 { e.focus = 99 } }
        let result = await e.capture()
        XCTAssertNil(result)
        XCTAssertEqual(e.clipboard.text(), "selected")
        XCTAssertEqual(e.clipboard.changeCount, 11)
    }

    func testOverlappingCaptureIsRejectedAndServiceCanBeReused() async {
        let e = Environment()
        e.onPause = {
            e.onPause = nil
            let overlapping = await e.capture()
            XCTAssertNil(overlapping)
            XCTAssertEqual(e.stages.last, .concurrent)
            XCTAssertEqual(e.copies, 1)
            e.clipboard.write("first selection")
        }
        let first = await e.capture()
        XCTAssertEqual(first, "first selection")
        e.onCopy = { e.clipboard.write("next selection") }
        let next = await e.capture()
        XCTAssertEqual(next, "next selection")
        XCTAssertEqual(e.copies, 2)
        XCTAssertEqual(e.clipboard.changeCount, 12)
    }

    func testSuccessDiagnosticsNeverContainSelectedOrOriginalPayload() async {
        let e = Environment()
        let sentinel = "PRIVATE_SELECTED_SENTINEL_917"
        let original = "PRIVATE_CLIPBOARD_SENTINEL_823"
        e.clipboard.contents = [[.string: Data(original.utf8)]]
        e.onCopy = { e.clipboard.write(sentinel) }
        let result = await e.capture()
        XCTAssertEqual(result, sentinel)
        XCTAssertEqual(e.stages, [.clipboardStart, .modifiersReleased, .snapshotReady,
                                  .copyPosted, .copyWaitComplete, .clipboardSuccess])
        let messages = e.diagnostics.map(\.message).joined(separator: "\n")
        XCTAssertFalse(messages.contains(sentinel))
        XCTAssertFalse(messages.contains(original))
        XCTAssertTrue(messages.contains("count=11 expectedCount=10"))
    }

    func testSnapshotMutationAndRepressedModifiersAreDiagnosed() async {
        let mutation = Environment()
        mutation.clipboard.onSnapshot = { mutation.clipboard.write("private mutation") }
        let mutationResult = await mutation.capture()
        XCTAssertNil(mutationResult)
        XCTAssertEqual(mutation.stages.last, .snapshotMutation)
        XCTAssertEqual(mutation.copies, 0)
        XCTAssertEqual(mutation.diagnostics.last?.count, 11)
        XCTAssertEqual(mutation.diagnostics.last?.expectedCount, 10)

        let repressed = Environment()
        repressed.clipboard.onSnapshot = { repressed.flags = .maskCommand }
        let repressedResult = await repressed.capture()
        XCTAssertNil(repressedResult)
        XCTAssertEqual(repressed.stages.last, .modifiersRepressed)
        XCTAssertEqual(repressed.copies, 0)
    }

    func testAlreadyCancelledCaptureIsDiagnosedWithoutCopy() async {
        let e = Environment()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await e.capture()
        }
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(e.stages, [.clipboardStart, .cancelled])
        XCTAssertEqual(e.copies, 0)
    }

    func testTaskCancellationDuringEachAsyncPhaseRejectsWithoutWriting() async {
        for phase in ["modifiers", "copy", "stability"] {
            let e = Environment()
            if phase == "modifiers" { e.flags = .maskCommand }
            e.onPause = {
                if phase != "stability" || e.time > 0.5 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            let task = Task { @MainActor in await e.capture() }
            let result = await task.value
            XCTAssertNil(result)
            XCTAssertEqual(e.stages.last, .cancelled)
            XCTAssertEqual(e.copies, phase == "modifiers" ? 0 : 1)
            XCTAssertEqual(e.clipboard.changeCount, 10)
            e.onPause = nil
            e.flags = []
            let retry = await e.capture()
            XCTAssertEqual(retry, "stale")
        }
    }

    func testPauseFailureDoesNotLogErrorContents() async {
        struct PrivateError: Error, CustomStringConvertible {
            var description: String { "PRIVATE_ERROR_SENTINEL" }
        }
        let e = Environment()
        e.onPause = { throw PrivateError() }
        let result = await e.capture()
        XCTAssertNil(result)
        XCTAssertEqual(e.stages.last, .pauseFailed)
        XCTAssertFalse(e.diagnostics.map(\.message).joined().contains("PRIVATE_ERROR_SENTINEL"))
    }

    func testAXStatusAndUnexpectedTypesAreDiagnosedOffline() {
        for stage: SelectionCaptureDiagnostic.Stage in [.axApplication, .axElement, .axText] {
            for value: AnyObject? in [nil, NSNumber(value: 123), "PRIVATE_AX_SENTINEL" as NSString] {
                let e = Environment()
                let element = AXUIElementCreateSystemWide()
                if stage != .axApplication { e.axValues.append((.success, element)) }
                if stage == .axText { e.axValues.append((.success, element)) }
                e.axValues.append((.attributeUnsupported, value))
                XCTAssertNil(e.service.getSelectedText())
                XCTAssertEqual(e.stages.last, .axUnavailable)
                let event = e.diagnostics.first { $0.stage == stage }
                XCTAssertEqual(event?.status, AXError.attributeUnsupported.rawValue)
                XCTAssertEqual(event?.present, value != nil)
                XCTAssertEqual(event?.typeID, value.map { CFGetTypeID($0 as CFTypeRef) })
                XCTAssertFalse(e.diagnostics.map(\.message).joined().contains("PRIVATE_AX_SENTINEL"))
            }
        }
    }

    func testAXSuccessEmptyAndWrongTypeOutcomesNeverEmitPayload() {
        for value: AnyObject in ["PRIVATE_AX_SENTINEL" as NSString, "" as NSString, NSNumber(value: 123)] {
            let e = Environment()
            let element = AXUIElementCreateSystemWide()
            e.axValues = [(.success, element), (.success, element), (.success, value)]
            let result = e.service.getSelectedText()
            XCTAssertEqual(result, (value as? String).flatMap { $0.isEmpty ? nil : $0 })
            XCTAssertEqual(e.stages.last, result == nil ? .axUnavailable : .axSuccess)
            XCTAssertEqual(e.diagnostics.first { $0.stage == .axText }?.empty, (value as? String).map { $0.isEmpty })
            XCTAssertFalse(e.diagnostics.map(\.message).joined().contains("PRIVATE_AX_SENTINEL"))
        }
        // Successful status with a wrong element type must not be cast or queried further.
        for prefix in [0, 1] {
            let e = Environment()
            if prefix == 1 { e.axValues = [(.success, AXUIElementCreateSystemWide())] }
            e.axValues.append((.success, NSNumber(value: 123)))
            XCTAssertNil(e.service.getSelectedText())
            XCTAssertEqual(e.stages.last, .axUnavailable)
            XCTAssertTrue(e.axValues.isEmpty)
        }
    }

    func testCancelledWaitDoesNotRestoreAndCaptureLockIsReleased() async {
        let e = Environment()
        e.onCopy = { e.clipboard.write("selected") }
        e.onPause = { throw CancellationError() }
        let result = await e.capture()
        XCTAssertNil(result)
        XCTAssertEqual(e.clipboard.text(), "selected")
        XCTAssertEqual(e.clipboard.changeCount, 11)
        XCTAssertEqual(e.stages.last, .cancelled)
        e.onPause = nil
        let retry = await e.capture()
        XCTAssertEqual(retry, "selected")
        XCTAssertEqual(e.copies, 2)
    }
}
