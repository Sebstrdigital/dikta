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
