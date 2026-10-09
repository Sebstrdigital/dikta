import XCTest
@testable import Dikta
#if canImport(NativeKokoroShared)
import NativeKokoroShared
#endif

final class NativeKokoroProtocolTests: XCTestCase {
    func testFragmentedAndCoalescedFrames() throws {
        let frames = [NKFrame(.hello, session: 1), NKFrame(.cancel, session: 1, request: 2, sequence: 1)]
        let bytes = try frames.reduce(into: Data()) { $0.append(try $1.encoded()) }
        var decoder = NKDecoder(), found: [NKFrame] = []
        for byte in bytes { try decoder.feed(Data([byte])) { found.append($0) } }
        XCTAssertEqual(found, frames); try decoder.finish()
        found = []; try decoder.feed(bytes) { found.append($0) }; XCTAssertEqual(found, frames)
    }
    func testRejectsOversizeBeforeBodyAllocation() throws {
        var bytes = try NKFrame(.audio, session: 1).encoded()
        bytes.replaceSubrange(8..<12, with: [0xff, 0xff, 0xff, 0xff])
        var decoder = NKDecoder()
        XCTAssertThrowsError(try decoder.feed(bytes) { _ in }) { XCTAssertEqual($0 as? NKError, .oversized) }
        XCTAssertEqual(decoder.bufferedBytes, 32)
    }
    func testRejectsMagicVersionAndKind() throws {
        for index in [0, 5, 7] {
            var bytes = try NKFrame(.hello, session: 1).encoded(); bytes[index] = 99
            var decoder = NKDecoder(); XCTAssertThrowsError(try decoder.feed(bytes) { _ in })
        }
    }
    func testControlSizeBound() {
        XCTAssertThrowsError(try NKFrame(.hello, session: 1, payload: Data(count: 4097)).encoded())
    }
    func testTruncatedEOF() throws {
        var decoder = NKDecoder(); try decoder.feed(Data([0x4e])) { _ in }
        XCTAssertThrowsError(try decoder.finish())
    }
    func testIdentityAndSequenceRejectStaleWithoutAdvancing() throws {
        var gate = NKIdentityGate(session: 1, request: 2)
        XCTAssertFalse(try gate.accept(NKFrame(.audio, session: 9, request: 2)))
        XCTAssertFalse(try gate.accept(NKFrame(.audio, session: 1, request: 9)))
        XCTAssertThrowsError(try gate.accept(NKFrame(.audio, session: 1, request: 2, sequence: 1)))
        XCTAssertTrue(try gate.accept(NKFrame(.audio, session: 1, request: 2)))
        XCTAssertThrowsError(try gate.accept(NKFrame(.audio, session: 1, request: 2)))
    }
    func testBoundedBlockedOutputAndPartialWrites() throws {
        var box = NKOutbox()
        for _ in 0..<4 { try box.enqueue(NKFrame(.hello, session: 1)) }
        XCTAssertThrowsError(try box.enqueue(NKFrame(.cancel, session: 1)))
        let before = box.bytes
        for _ in 0..<100 { try box.flush { _ in 0 } }
        XCTAssertEqual(box.bytes, before)
        var written = Data()
        while box.bytes > 0 { try box.flush { data in written.append(data.prefix(1)); return 1 } }
        XCTAssertEqual(written.count, before)
    }
    func testByteBackpressure() throws {
        var box = NKOutbox()
        try box.enqueue(NKFrame(.audio, session: 1, payload: Data(count: NKFrame.maxPayload)))
        try box.enqueue(NKFrame(.audio, session: 1, payload: Data(count: NKFrame.maxPayload)))
        XCTAssertThrowsError(try box.enqueue(NKFrame(.hello, session: 1)))
    }
    func testMalformedBinaryAudio() throws {
        for data in [Data(), Data(count: 46), Data(count: NKFrame.maxPayload + 1)] { XCTAssertThrowsError(try NKAudio.validate(data)) }
        let valid = wav(); try NKAudio.validate(valid)
        var bad = valid; bad[24] = 0; XCTAssertThrowsError(try NKAudio.validate(bad))
    }
}

private func wav() -> Data {
    var d = Data("RIFF".utf8)
    func le(_ n: UInt32, _ size: Int) { for shift in 0..<size { d.append(UInt8(truncatingIfNeeded: n >> (8 * shift))) } }
    le(38,4); d.append(Data("WAVEfmt ".utf8)); le(16,4); le(1,2); le(1,2)
    le(24000,4); le(48000,4); le(2,2); le(16,2); d.append(Data("data".utf8)); le(2,4); le(0,2)
    return d
}
private final class NativeKokoroFakeChild: NKChild {
    var incoming: [Data?] = []
    var dead = false
    var blocked = false
    var broken = false
    var signals: [Bool] = []
    var controlCloses = 0
    var resultCloses = 0
    var written = Data()
    func read() throws -> Data? { incoming.isEmpty ? Data() : incoming.removeFirst() }
    func write(_ data: Data) throws -> Int { if broken { throw NKError.closed }; if blocked { return 0 }; written.append(data); return data.count }
    func exited() -> Bool { dead }
    func signal(force: Bool) { signals.append(force) }
    func closeControl() { controlCloses += 1 }
    func closeResults() { resultCloses += 1 }
    func frame(_ frame: NKFrame) throws { incoming.append(try frame.encoded()) }
}
final class NativeKokoroLifecycleTests: XCTestCase {
    private var now: TimeInterval = 0
    private func owner(_ child: NativeKokoroFakeChild) -> NativeKokoroSession { NativeKokoroSession(session: 1, clock: { self.now }, factory: { child }) }
    private func ready(_ session: NativeKokoroSession, _ child: NativeKokoroFakeChild) throws {
        try session.start(automatic: false); try child.frame(NKFrame(.ready, session: 1)); session.tick(); XCTAssertEqual(session.state, .ready)
    }
    func testLaunchFailureAndNoForeignSignal() {
        let foreign = NativeKokoroFakeChild()
        let session = NativeKokoroSession(factory: { throw NKError.launch })
        XCTAssertThrowsError(try session.start(automatic: false)); session.shutdown(); session.tick()
        XCTAssertEqual(session.state, .failed); XCTAssertTrue(foreign.signals.isEmpty)
    }
    func testNeverStartedCleanupPreservesStoppedAndDoesNotLaunch() {
        let foreign = NativeKokoroFakeChild()
        var launches = 0
        let s = NativeKokoroSession(factory: { launches += 1; return foreign })
        for _ in 0..<3 { s.shutdown(); s.cancel(); s.tick(); XCTAssertEqual(s.state, .stopped) }
        XCTAssertEqual(launches, 0); XCTAssertTrue(foreign.signals.isEmpty)
        XCTAssertEqual(foreign.controlCloses, 0); XCTAssertEqual(foreign.resultCloses, 0)
    }
    func testRepeatedCleanupAfterReapPreservesStoppedAndClosedCounts() throws {
        let child = NativeKokoroFakeChild(), s = owner(child)
        try ready(s, child); s.shutdown(); child.dead = true; s.tick()
        XCTAssertEqual(s.state, .stopped)
        let signals = child.signals, controlCloses = child.controlCloses, resultCloses = child.resultCloses
        for _ in 0..<3 { s.shutdown(); s.cancel(); s.tick(); XCTAssertEqual(s.state, .stopped) }
        XCTAssertEqual(child.signals, signals); XCTAssertEqual(child.controlCloses, controlCloses)
        XCTAssertEqual(child.resultCloses, resultCloses)
    }
    func testFailedTerminalCleanupPreservesFailureWithoutResignalling() throws {
        let child = NativeKokoroFakeChild(), s = owner(child)
        try ready(s, child); child.dead = true; s.tick()
        XCTAssertEqual(s.state, .failed)
        let controlCloses = child.controlCloses, resultCloses = child.resultCloses
        for _ in 0..<3 { s.shutdown(); s.cancel(); s.tick(); XCTAssertEqual(s.state, .failed) }
        XCTAssertTrue(child.signals.isEmpty); XCTAssertEqual(child.controlCloses, controlCloses)
        XCTAssertEqual(child.resultCloses, resultCloses)
    }
    func testBlockedWorkerCancellationForcedCleanupAndRepeatedShutdown() throws {
        let child = NativeKokoroFakeChild(), session = owner(NativeKokoroFakeChild())
        _ = session // independent never-launched owner must not signal child
        let s = owner(child); try ready(s, child); try s.beginBlockedWork(request: 2)
        s.cancel(); XCTAssertEqual(s.state, .cancelling)
        now = 0.3; s.tick(); XCTAssertEqual(s.state, .retiring); XCTAssertEqual(child.signals, [false])
        s.shutdown(); now = 1.4; s.tick(); XCTAssertEqual(child.signals, [false, true])
        child.dead = true; s.tick(); s.shutdown(); s.tick(); XCTAssertEqual(s.state, .stopped)
        XCTAssertEqual(child.controlCloses, 2); XCTAssertEqual(child.signals, [false, true])
    }
    func testBlockedOutputDoesNotBlockStartupWatchdog() throws {
        let child = NativeKokoroFakeChild(); child.blocked = true; let s = owner(child)
        try s.start(automatic: false); s.tick(); now = 6; s.tick()
        XCTAssertEqual(s.state, .retiring); XCTAssertEqual(child.signals, [false])
    }
    func testBrokenPipeRetires() throws {
        let child = NativeKokoroFakeChild(); child.broken = true; let s = owner(child)
        try s.start(automatic: false); s.tick(); XCTAssertEqual(s.state, .retiring)
    }
    func testEOFAndTruncatedEOF() throws {
        for truncated in [false, true] {
            let child = NativeKokoroFakeChild(), s = owner(NativeKokoroFakeChild()); _ = s
            let owned = owner(child); try ready(owned, child)
            if truncated { child.incoming.append(Data([0x4e])); owned.tick() }
            child.incoming.append(nil); owned.tick(); XCTAssertEqual(owned.state, .retiring)
        }
    }
    func testUnexpectedChildExit() throws {
        let child = NativeKokoroFakeChild(), s = owner(NativeKokoroFakeChild()); _ = s
        let owned = owner(child); try ready(owned, child); child.dead = true; owned.tick()
        XCTAssertEqual(owned.state, .failed); XCTAssertTrue(child.signals.isEmpty)
    }
    func testStaleResultsAndCancelRejectAudio() throws {
        let child = NativeKokoroFakeChild(); let s = owner(child); try ready(s, child); try s.beginBlockedWork(request: 2)
        try child.frame(NKFrame(.audio, session: 9, request: 2, payload: wav())); s.tick(); XCTAssertTrue(s.takeResults().isEmpty)
        s.cancel(); try child.frame(NKFrame(.audio, session: 1, request: 2, payload: wav())); s.tick(); XCTAssertTrue(s.takeResults().isEmpty)
        try child.frame(NKFrame(.cancelled, session: 1, request: 2, sequence: 1)); s.tick(); XCTAssertEqual(s.state, .retiring)
    }
    func testResultQueueBoundAndMalformedAudio() throws {
        for invalid in [false, true] {
            let child = NativeKokoroFakeChild(); let s = owner(child); try ready(s, child); try s.beginBlockedWork(request: 2)
            for seq in 0..<3 { try child.frame(NKFrame(.audio, session: 1, request: 2, sequence: UInt32(seq), payload: invalid ? Data() : wav())); s.tick() }
            XCTAssertEqual(s.state, .retiring); XCTAssertTrue(s.takeResults().isEmpty)
        }
    }
    func testOwnerShutdownAndHealthySubsequentSession() throws {
        let child = NativeKokoroFakeChild(); var s: NativeKokoroSession? = owner(child)
        try ready(s!, child); s = nil; XCTAssertEqual(child.signals, [true])
        let next = NativeKokoroFakeChild(); let healthy = owner(next); try ready(healthy, next)
        healthy.shutdown(); next.dead = true; healthy.tick(); XCTAssertEqual(healthy.state, .stopped)
    }
    func testWorkAndIdleDeadlines() throws {
        for work in [false, true] {
            now = 0; let child = NativeKokoroFakeChild(); let s = owner(child); try ready(s, child)
            if work { try s.beginBlockedWork(request: 2) }
            now = work ? 31 : 121; s.tick(); XCTAssertEqual(s.state, .retiring)
        }
    }
}
final class NativeKokoroRuntimeControlTests: XCTestCase {
    func testMalformedRuntimeControls() throws {
        for kind in [NKKind.describe, .initialize, .shutdown, .cancel] {
            XCTAssertThrowsError(try NKControl.validate(NKFrame(kind, session: 1, payload: Data([1]))))
        }
        for text in ["", String(repeating: "x", count: 63), String(repeating: "a ", count: 65), "hello\u{0}world"] {
            XCTAssertThrowsError(try NKControl.validate(NKFrame(.synthesize, session: 1, payload: Data(text.utf8))))
        }
        for data in [Data(), Data([255]), Data([1,2])] {
            XCTAssertThrowsError(try NKControl.failure(data)); XCTAssertThrowsError(try NKControl.phase(data))
        }
        try NKControl.validate(NKFrame(.synthesize, session: 1, payload: Data("Hello.".utf8)))
        for port in [UInt16(0), 80, 49151] {
            var data = Data(); data.nkAppend(port)
            XCTAssertThrowsError(try NKControl.validate(NKFrame(.loopback, session: 1, payload: data)))
        }
        var data = Data(); data.nkAppend(UInt16(49152))
        try NKControl.validate(NKFrame(.loopback, session: 1, payload: data)) // validation only, never a network call
    }
    func testMailboxBoundedAndEpochInvalidation() {
        let mailbox = NKResultMailbox(), old = mailbox.begin()
        mailbox.invalidate()
        XCTAssertFalse(mailbox.publish([NKFrame(.complete, session: 1)], epoch: old))
        let fresh = mailbox.begin()
        XCTAssertFalse(mailbox.publish(Array(repeating: NKFrame(.complete, session: 1), count: 4), epoch: fresh))
        XCTAssertFalse(mailbox.publish([NKFrame(.audio, session: 1, payload: Data(count: NKFrame.maxPayload + 4097))], epoch: fresh))
        XCTAssertTrue(mailbox.publish([NKFrame(.complete, session: 2)], epoch: fresh))
        XCTAssertFalse(mailbox.publish([NKFrame(.failed, session: 2)], epoch: fresh))
        XCTAssertEqual(mailbox.take(), [NKFrame(.complete, session: 2)])
        XCTAssertTrue(mailbox.take().isEmpty)
        XCTAssertFalse(mailbox.publish([NKFrame(.complete, session: 2)], epoch: fresh))
    }
    func testInitializationCompletionAndFreshWorkDeadline() throws {
        var now: TimeInterval = 0
        let child = NativeKokoroFakeChild()
        let s = NativeKokoroSession(session: 11, clock: { now }, factory: { child })
        try s.start(automatic: false); try child.frame(NKFrame(.ready, session: 11)); s.tick()
        XCTAssertFalse(s.isEngineReady)
        try s.begin(.initialize, request: 1)
        try child.frame(NKFrame(.phase, session: 11, request: 1, payload: Data([NKPhase.initializing.rawValue]))); s.tick()
        now = 89; s.tick(); XCTAssertEqual(s.state, .working)
        try child.frame(NKFrame(.complete, session: 11, request: 1, sequence: 1)); s.tick()
        XCTAssertTrue(s.isEngineReady); XCTAssertEqual(s.state, .ready)
        XCTAssertEqual(s.takeResults().map { $0.kind }, [.complete])
        try s.begin(.synthesize, request: 2, payload: Data("Hello.".utf8))
        try child.frame(NKFrame(.complete, session: 10, request: 2)); s.tick()
        XCTAssertEqual(s.state, .working)
        now = 120; s.tick(); XCTAssertEqual(s.state, .retiring)
    }
    func testTerminalFailureAndDuplicateCompletionRetire() throws {
        for failure in [false, true] {
            let child = NativeKokoroFakeChild(), s = NativeKokoroSession(session: 1, factory: { child })
            try s.start(automatic: false); try child.frame(NKFrame(.ready, session: 1)); s.tick()
            try s.begin(.initialize, request: 2)
            if failure {
                try child.frame(NKFrame(.failed, session: 1, request: 2, payload: Data([NKRuntimeFailure.digest.rawValue]))); s.tick()
                XCTAssertEqual(s.runtimeFailure, .digest)
            } else {
                try child.frame(NKFrame(.complete, session: 1, request: 2)); s.tick()
                try child.frame(NKFrame(.complete, session: 1, request: 2, sequence: 1)); s.tick()
            }
            XCTAssertEqual(s.state, .retiring)
        }
    }
    func testCancelledCompletionCannotBecomeReady() throws {
        let child = NativeKokoroFakeChild(), s = NativeKokoroSession(session: 1, factory: { child })
        try s.start(automatic: false); try child.frame(NKFrame(.ready, session: 1)); s.tick()
        try s.begin(.initialize, request: 2); s.cancel()
        try child.frame(NKFrame(.complete, session: 1, request: 2)); s.tick()
        XCTAssertEqual(s.state, .cancelling); XCTAssertFalse(s.isEngineReady); XCTAssertTrue(s.takeResults().isEmpty)
    }
    func testNonblockingFactoryWatchdogAndStaleOwnedCleanup() throws {
        let entered = expectation(description: "factory entered"), reconciled = expectation(description: "stale child retired")
        let release = DispatchSemaphore(value: 0)
        let child = NativeKokoroFakeChild()
        var now: TimeInterval = 0
        let s = NativeKokoroSession(session: 7, clock: { now }, factory: {
            entered.fulfill(); release.wait(); return child
        })
        try s.startAsync(automatic: false)
        wait(for: [entered], timeout: 1)
        now = 6; s.tick(); XCTAssertEqual(s.state, .failed)
        release.signal()
        // Barrier through the owner state accessor after the result has reached its queue.
        DispatchQueue.global().async {
            for _ in 0..<100 { _ = s.state; usleep(1000) }
            reconciled.fulfill()
        }
        wait(for: [reconciled], timeout: 2)
        XCTAssertEqual(child.signals, [true]); XCTAssertEqual(child.controlCloses, 1)
        XCTAssertThrowsError(try s.start(automatic: false)) // one-shot instance; next read must use a fresh epoch
        let next = NativeKokoroFakeChild(), healthy = NativeKokoroSession(session: 8, factory: { next })
        try healthy.start(automatic: false); try next.frame(NKFrame(.ready, session: 8)); healthy.tick()
        XCTAssertEqual(healthy.state, .ready)
    }
    func testReconciliationBoundIsReportedWhileOwnershipRetained() throws {
        var now: TimeInterval = 0
        let child = NativeKokoroFakeChild(), s = NativeKokoroSession(clock: { now }, factory: { child })
        try s.start(automatic: false); s.shutdown(); now = 4; s.tick()
        XCTAssertTrue(s.exceededReconciliation); XCTAssertEqual(s.state, .retiring)
        child.dead = true; s.tick(); XCTAssertEqual(s.state, .stopped)
    }
}

final class NativeKokoroPackagedTests: XCTestCase {
    func testSignedEmbeddedHelperHandshakeBlockedWorkerCancelAndExit() throws {
        let url = NativeKokoroSession.packagedURL()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), url.path)
        let child = try NativeKokoroChild(executable: url)
        defer { child.closeControl(); child.signal(force: true); child.closeResults() }
        func send(_ frame: NKFrame) throws {
            var box = NKOutbox(); try box.enqueue(frame)
            let deadline = Date().addingTimeInterval(2)
            while box.bytes > 0 && Date() < deadline { try box.flush { try child.write($0) }; usleep(1000) }
            XCTAssertEqual(box.bytes, 0)
        }
        var decoder = NKDecoder(), received: [NKFrame] = []
        func receive() throws -> NKFrame? {
            let deadline = Date().addingTimeInterval(5)
            while received.isEmpty && Date() < deadline {
                guard let data = try child.read() else { break }
                try decoder.feed(data) { received.append($0) }; usleep(1000)
            }
            return received.isEmpty ? nil : received.removeFirst()
        }
        try send(NKFrame(.hello, session: 123))
        XCTAssertEqual(try receive(), NKFrame(.ready, session: 123))
        try send(NKFrame(.describe, session: 123, request: 7))
        let layoutFrame = try XCTUnwrap(receive())
        XCTAssertEqual(layoutFrame.kind, .layout)
        XCTAssertEqual(layoutFrame.session, 123)
        XCTAssertEqual(layoutFrame.request, 7)
        let paths = try XCTUnwrap(JSONSerialization.jsonObject(with: layoutFrame.payload) as? [String])
        XCTAssertEqual(paths.count, 4)
        XCTAssertTrue(paths[0].contains("/Library/Containers/com.duatalk.app.NativeKokoroHelper/Data"), paths[0])
        XCTAssertEqual(paths[1], paths[0] + "/.cache/fluidaudio/Models")
        XCTAssertEqual(paths[2], paths[1] + "/kokoro")
        XCTAssertEqual(paths[3], paths[1] + "/kokoro-82m-coreml/ANE")
        XCTAssertEqual(try receive(), NKFrame(.complete, session: 123, request: 7, sequence: 1))
        try send(NKFrame(.blockedWork, session: 123, request: 8))
        try send(NKFrame(.cancel, session: 123, request: 8, sequence: 1))
        XCTAssertEqual(try receive(), NKFrame(.cancelled, session: 123, request: 8))
        let deadline = Date().addingTimeInterval(3)
        while !child.exited() && Date() < deadline { usleep(1000) }
        XCTAssertTrue(child.exited(), "Owned helper did not reconcile")
    }
    func testControlClosureExitsOwnedHelper() throws {
        let child = try NativeKokoroChild(executable: NativeKokoroSession.packagedURL())
        defer { child.signal(force: true); child.closeResults() }
        child.closeControl()
        let deadline = Date().addingTimeInterval(3)
        while !child.exited() && Date() < deadline { usleep(1000) }
        XCTAssertTrue(child.exited())
    }
}
