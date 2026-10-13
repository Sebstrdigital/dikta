import XCTest
import CoreGraphics
@testable import Dikta

/// Covers the wait-for-modifier-release gate in front of auto-paste. A fast
/// engine can finish transcribing while the user is still holding a
/// modifier-only toggle hotkey (e.g. ⌥⌘); posting keystrokes then would turn
/// every character into a shortcut.
final class ClipboardManagerModifierReleaseTests: XCTestCase {

    /// Returns `held` for the first `heldPolls` reads, then no modifiers.
    private final class ScriptedFlags {
        private let held: CGEventFlags
        private var remaining: Int
        private(set) var reads = 0

        init(held: CGEventFlags, heldPolls: Int) {
            self.held = held
            self.remaining = heldPolls
        }

        func read() -> CGEventFlags {
            reads += 1
            if remaining > 0 {
                remaining -= 1
                return held
            }
            return []
        }
    }

    func test_runsImmediately_whenNoModifierHeld() {
        let flags = ScriptedFlags(held: [], heldPolls: 0)
        let manager = ClipboardManager(modifierFlags: flags.read)
        let ran = expectation(description: "body ran")

        manager.whenModifiersReleased(pollInterval: 0.01) { ran.fulfill() }

        wait(for: [ran], timeout: 1)
        XCTAssertEqual(flags.reads, 1)
    }

    func test_waitsUntilHotkeyModifiersReleased() {
        let flags = ScriptedFlags(held: [.maskCommand, .maskAlternate], heldPolls: 3)
        let manager = ClipboardManager(modifierFlags: flags.read)
        let ran = expectation(description: "body ran")

        manager.whenModifiersReleased(pollInterval: 0.01) { ran.fulfill() }

        wait(for: [ran], timeout: 1)
        XCTAssertEqual(flags.reads, 4, "body must run on the first poll that sees no modifiers")
    }

    func test_runsAfterTimeout_whenModifiersStayHeld() {
        let flags = ScriptedFlags(held: .maskCommand, heldPolls: .max)
        let manager = ClipboardManager(modifierFlags: flags.read)
        let ran = expectation(description: "body ran")
        let start = Date()

        manager.whenModifiersReleased(timeout: 0.1, pollInterval: 0.01) { ran.fulfill() }

        wait(for: [ran], timeout: 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.1)
    }

    func test_ignoresNonModifierFlags() {
        // Caps Lock and numeric-pad bits are not held shortcut modifiers.
        let flags = ScriptedFlags(held: [.maskAlphaShift, .maskNumericPad], heldPolls: .max)
        let manager = ClipboardManager(modifierFlags: flags.read)
        let ran = expectation(description: "body ran")

        manager.whenModifiersReleased(timeout: 5, pollInterval: 0.01) { ran.fulfill() }

        wait(for: [ran], timeout: 1)
        XCTAssertEqual(flags.reads, 1)
    }

    func test_eachShortcutModifierBlocksOutput() {
        for modifier: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn] {
            let flags = ScriptedFlags(held: modifier, heldPolls: 2)
            let manager = ClipboardManager(modifierFlags: flags.read)
            let ran = expectation(description: "body ran for \(modifier.rawValue)")

            manager.whenModifiersReleased(pollInterval: 0.01) { ran.fulfill() }

            wait(for: [ran], timeout: 1)
            XCTAssertEqual(flags.reads, 3, "modifier \(modifier.rawValue) should delay output")
        }
    }
}

private final class SyntheticPasteboard: MultilinePasteboard {
    var generation = 0
    var contents: ClipboardSnapshot
    var snapshotUnavailable = false
    var onSnapshot: (() -> Void)?
    var failNextWrite = false
    var failAfterClear = false
    var writes = 0

    init(_ contents: ClipboardSnapshot) { self.contents = contents }
    func snapshot() -> ClipboardSnapshot? {
        let result = snapshotUnavailable ? nil : contents
        onSnapshot?()
        return result
    }
    func copyElsewhere(_ snapshot: ClipboardSnapshot) {
        contents = snapshot
        generation += 1
    }
    func replace(with snapshot: ClipboardSnapshot, ifGeneration expected: Int) -> ClipboardWriteResult {
        guard expected == generation else { return .ownershipLost }
        if failNextWrite {
            failNextWrite = false
            if failAfterClear {
                copyElsewhere(ClipboardSnapshot(items: []))
                return .failed(ownedGeneration: generation)
            }
            return .failed(ownedGeneration: nil)
        }
        writes += 1
        copyElsewhere(snapshot)
        return .written(generation: generation)
    }
}

private final class PasteScheduler {
    var callbacks: [() -> Void] = []
    var delays: [TimeInterval] = []
    func schedule(_ delay: TimeInterval, _ callback: @escaping () -> Void) {
        delays.append(delay)
        callbacks.append(callback)
    }
    @discardableResult func runNext() -> (() -> Void)? {
        guard !callbacks.isEmpty else { return nil }
        let callback = callbacks.removeFirst()
        callback()
        return callback
    }
}

private final class ImmediateClipboardManager: ClipboardManager {
    override func whenModifiersReleased(timeout: TimeInterval = 1.5, pollInterval: TimeInterval = 0.02, _ body: @escaping () -> Void) {
        body()
    }
}

final class ClipboardManagerMultilineTests: XCTestCase {
    private let output = "Heading\nUseful synthetic output"
    private var pasteRequests = 0
    private var board: SyntheticPasteboard!
    private var scheduler: PasteScheduler!
    private var manager: ClipboardManager!
    private var results: [MultilinePasteResult] = []

    override func setUp() {
        super.setUp()
        pasteRequests = 0
        results = []
        configure(.text("Original"))
    }
    private func configure(_ original: ClipboardSnapshot) {
        board = SyntheticPasteboard(original)
        scheduler = PasteScheduler()
        manager = ImmediateClipboardManager(modifierFlags: { [] }, multilineBoard: board,
            schedule: scheduler.schedule, postPaste: { [weak self] in self?.pasteRequests += 1 })
    }
    private func paste(_ text: String? = nil) {
        manager.pasteMultiline(text ?? output) { [weak self] in self?.results.append($0) }
    }
    private func assertRoundTrip(_ original: ClipboardSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        configure(original)
        paste()
        XCTAssertEqual(board.contents, .text(output), file: file, line: line)
        scheduler.runNext()
        XCTAssertEqual(pasteRequests, 1, file: file, line: line)
        XCTAssertEqual(results, [.pasteRequested], file: file, line: line)
        scheduler.runNext()
        XCTAssertEqual(board.contents, original, file: file, line: line)
        XCTAssertEqual(scheduler.delays, [0.05, 0.5], file: file, line: line)
    }
    func test_emptyOriginalIsRestored() { assertRoundTrip(ClipboardSnapshot(items: [])) }
    func test_textOriginalIsRestoredAndNewlinesPreserved() { assertRoundTrip(.text("Before\nAfter")) }
    func test_imageAndFileRepresentationsAreRestored() {
        assertRoundTrip(ClipboardSnapshot(items: [["public.png": Data([0, 1, 2]), "public.file-url": Data("file:///synthetic.png".utf8)]]))
    }
    func test_richTextAndMultipleItemsAreRestored() {
        assertRoundTrip(ClipboardSnapshot(items: [["public.rtf": Data("{synthetic rich text}".utf8), "public.utf8-plain-text": Data("plain".utf8)], ["public.tiff": Data([4, 5, 6])]]))
    }
    func test_interveningCopyBeforePasteSkipsRatherThanPastingOtherContent() {
        paste()
        board.copyElsewhere(.text("New writer"))
        scheduler.runNext()
        XCTAssertEqual(results, [.skippedBecauseClipboardChanged])
        XCTAssertEqual(pasteRequests, 0)
        XCTAssertEqual(board.contents, .text("New writer"))
        XCTAssertTrue(scheduler.callbacks.isEmpty)
    }
    func test_identicalTextWithDifferentGenerationBeforePasteStillSkips() {
        paste()
        board.copyElsewhere(.text(output))
        scheduler.runNext()
        XCTAssertEqual(results, [.skippedBecauseClipboardChanged])
        XCTAssertEqual(pasteRequests, 0)
    }
    func test_interveningCopyBeforeRestoreIsNeverOverwritten() {
        paste()
        scheduler.runNext()
        board.copyElsewhere(.text("New writer"))
        scheduler.runNext()
        XCTAssertEqual(board.contents, .text("New writer"))
        XCTAssertEqual(results, [.pasteRequested])
    }
    func test_identicalOutputWithDifferentGenerationBeforeRestoreIsNotRestored() {
        paste()
        scheduler.runNext()
        board.copyElsewhere(.text(output))
        scheduler.runNext()
        XCTAssertEqual(board.contents, .text(output))
        XCTAssertEqual(board.writes, 1)
    }
    func test_unavailableSnapshotDoesNotMutateOrPostPaste() {
        board.snapshotUnavailable = true
        paste()
        XCTAssertEqual(results, [.skippedBecauseOriginalFormatCouldNotBeSafelySnapshotted])
        XCTAssertEqual(board.contents, .text("Original"))
        XCTAssertEqual(board.writes, 0)
        XCTAssertEqual(pasteRequests, 0)
    }
    func test_snapshotOwnershipChangeSkipsBeforeWriting() {
        board.onSnapshot = { [weak self] in self?.board.copyElsewhere(.text("During materialization")) }
        paste()
        XCTAssertEqual(results, [.skippedBecauseClipboardChanged])
        XCTAssertEqual(board.writes, 0)
        XCTAssertEqual(board.contents, .text("During materialization"))
    }
    func test_failedWriteDoesNotAnnounceOrSchedulePaste() {
        board.failNextWrite = true
        paste()
        XCTAssertEqual(results, [.skippedBecausePasteboardWriteFailed])
        XCTAssertEqual(board.contents, .text("Original"))
        XCTAssertTrue(scheduler.callbacks.isEmpty)
    }
    func test_failedWriteAfterClearRollsBackOnlyOwnedClipboard() {
        board.failNextWrite = true
        board.failAfterClear = true
        paste()
        XCTAssertEqual(results, [.skippedBecausePasteboardWriteFailed])
        XCTAssertEqual(board.contents, .text("Original"))
        XCTAssertEqual(pasteRequests, 0)
    }
    func test_overlappingRequestsSerializeAndRestoreOriginalNotGeneratedOutput() {
        paste("First\noutput")
        paste("Second\noutput")
        XCTAssertEqual(board.contents, .text("First\noutput"))
        scheduler.runNext() // first paste
        scheduler.runNext() // first restore, second write
        XCTAssertEqual(board.contents, .text("Second\noutput"))
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(board.contents, .text("Original"))
        XCTAssertEqual(results, [.pasteRequested, .pasteRequested])
        XCTAssertEqual(pasteRequests, 2)
    }
    func test_repeatedOperationsSnapshotLatestExternalOriginal() {
        paste(); scheduler.runNext(); scheduler.runNext()
        board.copyElsewhere(.text("Next original"))
        paste(); scheduler.runNext(); scheduler.runNext()
        XCTAssertEqual(board.contents, .text("Next original"))
    }
    func test_staleAndRepeatedCallbacksCannotPasteOrRestoreNewOperation() {
        paste()
        let oldPaste = scheduler.runNext()
        oldPaste?() // repeated before restore must not post twice
        let oldRestore = scheduler.runNext()
        paste("Next\noutput")
        oldPaste?(); oldRestore?()
        XCTAssertEqual(board.contents, .text("Next\noutput"))
        scheduler.runNext(); scheduler.runNext()
        XCTAssertEqual(pasteRequests, 2)
        XCTAssertEqual(results, [.pasteRequested, .pasteRequested])
        XCTAssertEqual(board.contents, .text("Original"))
    }
    func test_queuedPasteAfterInterruptedOperationUsesExternalOriginal() {
        paste(); paste("Next\noutput")
        board.copyElsewhere(.text("Copied meanwhile"))
        scheduler.runNext()
        scheduler.runNext(); scheduler.runNext()
        XCTAssertEqual(board.contents, .text("Copied meanwhile"))
        XCTAssertEqual(results, [.skippedBecauseClipboardChanged, .pasteRequested])
    }
    func test_materializationRejectsAnyUnavailableFormatWithoutDroppingItems() {
        XCTAssertNil(ClipboardSnapshot.materialize([[ ("public.png", Data([1])), ("public.rtf", nil) ]]))
        XCTAssertNil(ClipboardSnapshot.materialize([[ ("public.png", Data([1])) ], [("public.file-url", nil)]]))
        XCTAssertNil(ClipboardSnapshot.materialize([[]]))
    }
    func test_filePromisesAreRejectedEvenWhenDescriptorBytesMaterialize() {
        for type in ["com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-file-content-type", "NSFilesPromisePboardType"] {
            XCTAssertNil(ClipboardSnapshot.materialize([[(type, Data([1, 2]))]]))
        }
    }
    func test_materializationPreservesAllDataAndEmptyBoard() {
        XCTAssertEqual(ClipboardSnapshot.materialize([]), ClipboardSnapshot(items: []))
        XCTAssertEqual(ClipboardSnapshot.materialize([[ ("public.rtf", Data([1])), ("public.png", Data([2])) ], [("public.file-url", Data([3]))]]), ClipboardSnapshot(items: [["public.rtf": Data([1]), "public.png": Data([2])], ["public.file-url": Data([3])]]))
    }
}
