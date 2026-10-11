import XCTest
import Darwin
import CryptoKit
@testable import Dikta

// Retained as K5 legacy history. K3 removes the production loopback/PID path,
// so these Python-process tests intentionally do not compile into the native gate.
#if false
/// Pins the two invariants `TextToSpeechService.killStaleServer()` must never
/// break: it must never SIGTERM this process, and it must never SIGTERM a
/// program that merely happens to hold port 59123.
///
/// It used to do both. `killStaleServer` ran `lsof -ti :59123`, and `-i :<port>`
/// matches a port in either endpoint of a socket, so it reported every *client*
/// with an open connection to 59123 as well as whatever was listening on it.
/// Dikta pings `127.0.0.1:59123` itself on every `TextToSpeechService` init
/// (`ensureServerRunning` → `checkAvailable`), so whenever one of those sockets
/// was still open when `lsof` sampled, the app read its own PID back and sent
/// itself SIGTERM — a silent exit with no crash report that killed the whole
/// XCTest host mid-suite. 59123 is also in the ephemeral range (49152–65535),
/// so an unrelated process holding it was killed too.
///
/// The listener therefore lives in a **child process**: if it lived in the test
/// process, filtering on `getpid()` alone would make these tests pass and the
/// broken `lsof` arguments would go unnoticed.
final class TTSStaleServerPIDTests: XCTestCase {

    private static let python = "/usr/bin/python3"
    private static let lsof = "/usr/sbin/lsof"

    /// A listening socket in another process, plus a client connection to it
    /// owned by *this* process — the exact shape that made `lsof -ti :<port>`
    /// report the test host.
    ///
    /// The child binds port 0 and prints the port the kernel gave it, so there
    /// is no window in which the test holds the port before the child does.
    /// `scriptName` becomes the child's script file name, which is what shows
    /// up in `ps -o command=` and therefore what the Kokoro identity check
    /// matches on.
    ///
    /// A second child is attached as a pure *client* on the same port. Without
    /// it, dropping `-sTCP:LISTEN` would still look correct here: `lsof -ti
    /// :<port>` would report the listener and this process, and the `getpid()`
    /// filter would quietly hide the second one. The foreign client is the only
    /// witness that survives that filter, so it is what actually pins the
    /// `lsof` arguments.
    private func withForeignListener(
        scriptName: String,
        _ body: (_ port: Int, _ childPID: Int32) throws -> Void
    ) throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: Self.python),
            "\(Self.python) is required to host a listener outside this process"
        )
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: Self.lsof),
            "\(Self.lsof) is required — listeningServerPIDs shells out to it"
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent(scriptName)
        try """
        import socket, sys
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen(8)
        print(s.getsockname()[1], flush=True)
        keep = []
        while True:
            c, _ = s.accept()
            keep.append(c)
        """.write(to: script, atomically: true, encoding: .utf8)

        let stdout = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: Self.python)
        child.arguments = [script.path]
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }

        // First line of the child's stdout is the port it bound. Bounded: a
        // child that never prints must fail the test, not hang the host.
        let portLine: String
        switch readLine(from: stdout.fileHandleForReading, timeout: 10) {
        case .line(let text):
            portLine = text
        case .timedOut:
            child.terminate()
            XCTFail("child listener printed no port within 10s; terminated it")
            return
        case .endOfFile:
            child.terminate()
            XCTFail("child listener closed its pipe without printing a port; terminated it")
            return
        }
        let port = try XCTUnwrap(Int(portLine), "child printed a non-numeric port: \(portLine)")

        let clientFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(clientFD < 0, "could not create a client socket")
        defer { Darwin.close(clientFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = Darwin.inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(clientFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "could not connect to the child listener on \(port)")

        // A second, foreign client on the same port. `-i :<port>` reports it;
        // `-sTCP:LISTEN` does not, and no PID filter can hide it.
        let foreignClient = Process()
        foreignClient.executableURL = URL(fileURLWithPath: Self.python)
        foreignClient.arguments = [
            "-c",
            "import socket,time; s=socket.socket(); s.connect(('127.0.0.1',\(port))); time.sleep(300)"
        ]
        foreignClient.standardOutput = FileHandle.nullDevice
        foreignClient.standardError = FileHandle.nullDevice
        try foreignClient.run()
        defer {
            if foreignClient.isRunning { foreignClient.terminate() }
            foreignClient.waitUntilExit()
        }
        // Wait until the kernel actually shows all three parties — the child
        // listener, this process and the foreign client — otherwise the witness
        // is not yet in place when the assertions run.
        let clientDeadline = Date().addingTimeInterval(10)
        while Date() < clientDeadline && !pidsOnPort(port).contains(foreignClient.processIdentifier) {
            usleep(50_000)
        }
        XCTAssertTrue(
            pidsOnPort(port).contains(foreignClient.processIdentifier),
            "the foreign client never showed up on port \(port); the test would not pin the lsof arguments"
        )

        // Both client sockets stay open across `body`, so this process and the
        // foreign child are live clients on `port` for every lookup the test makes.
        try body(port, child.processIdentifier)
    }

    /// Every PID with a socket on `port`, listeners and clients alike. Used
    /// only to wait for the foreign client to appear; the code under test is
    /// deliberately not involved in setting up its own witness.
    private func pidsOnPort(_ port: Int) -> [Int32] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.lsof)
        process.arguments = ["-ti", ":\(port)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Outcome of `readLine(from:timeout:)`, so the caller can tell a child that
    /// said nothing apart from one that closed its pipe.
    private enum LineRead: Equatable {
        case line(String)
        case timedOut
        case endOfFile
    }

    /// Reads one newline-terminated line, giving up after `timeout` seconds.
    ///
    /// The fd is switched to non-blocking first. `FileHandle.availableData`
    /// blocks until data or EOF, so a child that starts but never prints would
    /// hang the test host forever, and at EOF it returns empty immediately,
    /// which busy-spins. Polling a non-blocking fd bounds both cases.
    private func readLine(from handle: FileHandle, timeout: TimeInterval) -> LineRead {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        if flags != -1 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 512)

        while Date() < deadline {
            let n = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: scratch[0..<n])
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let text = String(data: buffer[..<newline], encoding: .utf8)?
                        .trimmingCharacters(in: .whitespaces)
                    return text.map { LineRead.line($0) } ?? .endOfFile
                }
                continue
            }
            if n == 0 { return .endOfFile } // child closed the pipe without a line
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                usleep(20_000) // 20ms — nothing to read yet
                continue
            }
            return .endOfFile // genuine read error
        }
        return .timedOut
    }

    /// The regression. The child IS the listener and must be found; this
    /// process is only a client on the same port and must not be.
    ///
    /// Asserting the exact set covers both halves at once: an implementation
    /// that returns nothing fails just as loudly as one that returns us.
    func test_listeningServerPIDs_findsForeignListenerAndNeverThisProcess() throws {
        try withForeignListener(scriptName: "listener.py") { port, childPID in
            let pids = TextToSpeechService.listeningServerPIDs(onPort: port)

            XCTAssertEqual(
                pids, [childPID],
                "expected exactly the child listener; got \(pids) (this process is \(getpid()))"
            )
            XCTAssertFalse(
                pids.contains(getpid()),
                "killStaleServer would SIGTERM Dikta itself"
            )
        }
    }

    /// A listener that is not ours must survive `killStaleServer`. Port 59123
    /// is in the ephemeral range, so anything could be holding it.
    func test_terminateStaleKokoroServers_leavesAForeignListenerAlive() throws {
        try withForeignListener(scriptName: "not_kokoro.py") { port, childPID in
            let signalled = TextToSpeechService.terminateStaleKokoroServers(onPort: port)

            XCTAssertEqual(signalled, [], "a process that is not a Kokoro server must not be signalled")
            // 0 probes for existence without sending anything.
            XCTAssertEqual(
                Darwin.kill(childPID, 0), 0,
                "the foreign listener was killed; errno \(errno)"
            )
        }
    }

    /// The identity check must not be vacuous: a listener whose command line
    /// does carry the Kokoro marker is still cleaned up.
    func test_terminateStaleKokoroServers_killsAMatchingKokoroServer() throws {
        try withForeignListener(scriptName: "kokoro_server.py") { port, childPID in
            let signalled = TextToSpeechService.terminateStaleKokoroServers(
                onPort: port,
                commandMarker: "kokoro_server.py"
            )

            XCTAssertEqual(signalled, [childPID], "a stale Kokoro server must be signalled")

            // SIGTERM is asynchronous; give the child a moment to go away.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline && Darwin.kill(childPID, 0) == 0 {
                usleep(50_000)
            }
            XCTAssertNotEqual(Darwin.kill(childPID, 0), 0, "stale Kokoro server was not terminated")
        }
    }

    /// Covers the `getpid()` filter specifically, which the foreign-listener
    /// tests cannot reach: with correct `lsof` arguments this process is only
    /// ever a client, so it never appears in the output to begin with. Here the
    /// test process IS the listener, which is the one case where the filter is
    /// the only thing standing between Dikta and `kill(getpid(), SIGTERM)`.
    func test_listeningServerPIDs_excludesThisProcessWhenItIsTheListener() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: Self.lsof),
            "\(Self.lsof) is required — listeningServerPIDs shells out to it"
        )

        let listenFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(listenFD < 0, "could not create a listening socket")
        defer { Darwin.close(listenFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // kernel picks a free port
        addr.sin_addr.s_addr = Darwin.inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipIf(bound != 0, "could not bind a loopback port")
        try XCTSkipIf(Darwin.listen(listenFD, 8) != 0, "could not listen")

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listenFD, $0, &len)
            }
        }
        try XCTSkipIf(named != 0, "could not read back the bound port")
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))

        // Sanity: this process really is the listener lsof would report.
        XCTAssertTrue(
            pidsOnPort(port).contains(getpid()),
            "this process is not visible on port \(port); the test proves nothing"
        )

        let pids = TextToSpeechService.listeningServerPIDs(onPort: port)
        XCTAssertFalse(
            pids.contains(getpid()),
            "killStaleServer would SIGTERM Dikta itself (pids: \(pids))"
        )
    }

    // MARK: - The harness's own bounds

    /// A child that starts but never prints must time out, not hang the host.
    func test_readLine_timesOutOnASilentChild() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.python), "python3 required")

        let stdout = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: Self.python)
        child.arguments = ["-c", "import time; time.sleep(30)"]
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }

        let started = Date()
        let result = readLine(from: stdout.fileHandleForReading, timeout: 1)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(elapsed, 5, "readLine did not honour its own deadline")
    }

    /// A child that exits without printing must report EOF promptly rather than
    /// busy-spinning until the deadline.
    func test_readLine_reportsEndOfFileWhenTheChildPrintsNothing() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.python), "python3 required")

        let stdout = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: Self.python)
        child.arguments = ["-c", "pass"]
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()

        let started = Date()
        let result = readLine(from: stdout.fileHandleForReading, timeout: 10)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result, .endOfFile)
        XCTAssertLessThan(elapsed, 5, "readLine spun until the deadline instead of noticing EOF")
    }

    // MARK: - Not covered here
    //
    // `startServer()` calls `killStaleServer()` only after the "is Kokoro
    // installed" guard, so a user who never installed TTS never runs `lsof`/`ps`
    // or touches port 59123. That ordering is NOT unit-tested: `startServer()`
    // is private, and reaching it means constructing a `TextToSpeechService`,
    // whose `init` immediately fires `ensureServerRunning()` and starts real
    // network work. Testing it needs an injection seam wider than this fix.

    /// A port nobody is listening on yields nothing, so the common path (no
    /// Kokoro server running) sends no signals at all.
    func test_listeningServerPIDs_unusedPortYieldsNothing() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: Self.lsof),
            "\(Self.lsof) is required — listeningServerPIDs shells out to it"
        )
        // 0 is never a listening port.
        XCTAssertTrue(TextToSpeechService.listeningServerPIDs(onPort: 0).isEmpty)
    }
}
#endif

/// Offline installer regressions: no pip, Kokoro import, model or network.
/// Test-only copy of the retired Python setup process harness. These six active
/// regressions continue to pin its bounded process behavior for downgrade/source
/// compatibility without compiling Python setup into the Dikta application.
private enum LegacyTTSSetupCommandError: LocalizedError {
    case pythonNotFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound: return "Python 3.11 was not found."
        case .commandFailed(let message): return message
        }
    }
}

private enum TTSSetupCommands {
    static func findPython(candidates: [String]) async throws -> String {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if let version = try? await run(
                path,
                arguments: ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"],
                timeout: 5
            ), version.trimmingCharacters(in: .whitespacesAndNewlines) == "3.11" {
                return path
            }
        }
        throw LegacyTTSSetupCommandError.pythonNotFound
    }

    @discardableResult
    static func preserveVenv(at path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let backup = path + ".backup-" + UUID().uuidString
        try FileManager.default.moveItem(atPath: path, toPath: backup)
        return backup
    }

    static func run(_ path: String, arguments: [String], timeout: TimeInterval = 600) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let log = FileManager.default.temporaryDirectory
                        .appendingPathComponent("dikta-legacy-tts-setup-test-\(UUID().uuidString).log")
                    guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
                        throw LegacyTTSSetupCommandError.commandFailed("Cannot create installer log.")
                    }
                    let output = try FileHandle(forWritingTo: log)
                    defer { try? output.close() }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = arguments
                    process.standardOutput = output
                    process.standardError = output
                    try process.run()
                    let deadline = ProcessInfo.processInfo.systemUptime + timeout
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    let timedOut = process.isRunning
                    if timedOut {
                        process.terminate()
                        let grace = ProcessInfo.processInfo.systemUptime + 2
                        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                    process.waitUntilExit()
                    let input = try FileHandle(forReadingFrom: log)
                    defer { try? input.close() }
                    let end = try input.seekToEnd()
                    try input.seek(toOffset: end > 8192 ? end - 8192 : 0)
                    let text = String(decoding: try input.readToEnd() ?? Data(), as: UTF8.self)
                    if timedOut || process.terminationStatus != 0 {
                        let reason = timedOut ? "Timed out after \(Int(timeout))s" : "Exit code \(process.terminationStatus)"
                        throw LegacyTTSSetupCommandError.commandFailed(
                            "\(reason): \(text.suffix(1000))\nLog: \(log.path)"
                        )
                    }
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

final class TTSSetupCommandTests: XCTestCase {
    func testVerboseChildCannotDeadlockAndReturnsDiagnosticTail() async throws {
        let output = try await TTSSetupCommands.run("/usr/bin/python3", arguments: [
            "-c", "import sys; sys.stdout.write('o'*1048576); sys.stderr.write('e'*1048576 + 'DIAGNOSTIC'); sys.stderr.flush()"
        ], timeout: 10)
        XCTAssertTrue(output.hasSuffix("DIAGNOSTIC"))
        XCTAssertLessThanOrEqual(output.utf8.count, 8192)
    }

    func testFailureIncludesExitStatusAndStderr() async {
        do {
            _ = try await TTSSetupCommands.run("/bin/sh", arguments: ["-c", "echo useful-diagnostic >&2; exit 7"], timeout: 5)
            XCTFail("Expected installer failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Exit code 7"))
            XCTAssertTrue(error.localizedDescription.contains("useful-diagnostic"))
            XCTAssertTrue(error.localizedDescription.contains("Log:"))
        }
    }

    func testSilentChildTimesOutEvenWhenItIgnoresTermination() async {
        let started = Date()
        do {
            _ = try await TTSSetupCommands.run("/usr/bin/python3", arguments: [
                "-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"
            ], timeout: 0.5)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Timed out"))
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        }
    }

    func testMissingExecutableFailsPromptly() async {
        do {
            _ = try await TTSSetupCommands.run("/nonexistent/dikta-python", arguments: [], timeout: 1)
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testPythonSelectionSkipsIncompatibleAndMissingCandidates() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func fake(_ name: String, _ version: String) throws -> String {
            let url = dir.appendingPathComponent(name)
            try "#!/bin/sh\necho \(version)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        let old = try fake("old", "3.9")
        let future = try fake("future", "3.14")
        let good = try fake("good", "3.11")
        let selected = try await TTSSetupCommands.findPython(candidates: ["/nonexistent/python", old, future, good])
        XCTAssertEqual(selected, good)
        do {
            _ = try await TTSSetupCommands.findPython(candidates: [old, future])
            XCTFail("Expected actionable prerequisite failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Python 3.11"))
        }
    }

    func testExistingVenvIsPreservedRatherThanReusedOrDeleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let venv = dir.appendingPathComponent("venv")
        try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("seed".utf8).write(to: venv.appendingPathComponent("marker"))
        let backup = try XCTUnwrap(TTSSetupCommands.preserveVenv(at: venv.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: venv.path))
        XCTAssertEqual(try String(contentsOfFile: backup + "/marker", encoding: .utf8), "seed")
        XCTAssertNil(try TTSSetupCommands.preserveVenv(at: venv.path))
    }
}

/// K5 candidate-composition and source-only downgrade fixtures. No live config,
/// recordings, installed assets, or legacy environment are read by these tests.
final class K5NativeCandidateCompatibilityTests: XCTestCase {
    func testCandidateBundlesCompleteNativeNoticeAndDependencyLicensePacket() throws {
        let expectedHashes = [
            "ThirdPartyNotices": "9ff24052a3c2886e5fccdf3d6f74fd616bbd00483d79209786208a437f86ca3c",
            "NativeKokoroNemo-NOTICE": "886143044515319a91f4447f9b447bb89089b4c9af847300f4b8de830c805852",
            "NativeKokoroNemo-ThirdParty-Licenses": "14d21dbb0deb74aa7775f5803c36609aa6ef0c38c94fb03dbc95efb3645f7678",
            "NativeKokoroNemo-Apache-2.0": "ac84752611bfcb8e2f472b17f9cb18f5321c9a75c2a5445b766725b1de67790b",
            "NativeKokoroNemo-Dependency-Licenses": "9c2464f94695806d43711b9e60c87b4b109a0bd38f131be334a28b2d66a003df"
        ]
        var texts: [String: String] = [:]
        for (name, expectedHash) in expectedHashes {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "txt"), name)
            let data = try Data(contentsOf: url)
            let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actualHash, expectedHash, name)
            texts[name] = try XCTUnwrap(String(data: data, encoding: .utf8), name)
        }
        XCTAssertNotNil(Bundle.main.url(forResource: "Apache-2.0", withExtension: "txt"))
        XCTAssertNil(Bundle.main.url(forResource: "kokoro_server", withExtension: "py"))
        XCTAssertNil(Bundle.main.url(forResource: "setup", withExtension: "sh"))

        let notices = try XCTUnwrap(texts["ThirdPartyNotices"])
        for required in ["FluidAudio 0.17.4", "NemoTextProcessing", "Kokoro-82M", "Misaki"] {
            XCTAssertTrue(notices.contains(required), required)
        }

        let expectedCrates = [
            "adler2 2.0.1", "anyhow 1.0.103", "autocfg 1.5.1", "bimap 0.6.3",
            "bitflags 2.13.0", "cfg-if 1.0.4", "crc32fast 1.5.0", "either 1.16.0",
            "flate2 1.1.9", "generic-array 1.4.3", "getrandom 0.3.4", "itertools 0.14.0",
            "lazy_static 1.5.0", "libc 0.2.186", "memchr 2.8.3", "minimal-lexical 0.2.1",
            "miniz_oxide 0.8.9", "nom 7.1.3", "num-traits 0.2.19", "ordered-float 5.3.0",
            "ppv-lite86 0.2.21", "proc-macro2 1.0.106", "quote 1.0.46", "r-efi 5.3.0",
            "rand 0.9.4", "rand_chacha 0.9.0", "rand_core 0.9.5", "rustfst 1.3.1",
            "rustversion 1.0.23", "serde 1.0.228", "serde_core 1.0.228", "serde_derive 1.0.228",
            "simd-adler32 0.3.9", "superslice 1.0.0", "syn 2.0.118", "typenum 1.20.1",
            "unicode-ident 1.0.24", "wasip2 1.0.4+wasi-0.2.12", "wit-bindgen 0.57.1",
            "zerocopy 0.8.53", "zerocopy-derive 0.8.53"
        ]
        let dependencyLicenses = try XCTUnwrap(texts["NativeKokoroNemo-Dependency-Licenses"])
        let actualCrates = dependencyLicenses.split(separator: "\n").compactMap { line -> String? in
            let prefix = "===== CRATE "
            guard line.hasPrefix(prefix), line.hasSuffix(" =====") else { return nil }
            return String(line.dropFirst(prefix.count).dropLast(" =====".count))
        }
        XCTAssertEqual(actualCrates, expectedCrates)
        XCTAssertEqual(dependencyLicenses.components(separatedBy: "Selected license: MIT").count - 1, 39)
        XCTAssertEqual(dependencyLicenses.components(separatedBy: "Selected license: Apache-2.0").count - 1, 2)
        XCTAssertTrue(dependencyLicenses.contains("Additional required full license text (Unicode-3.0):"))
        XCTAssertTrue(dependencyLicenses.contains("Copyright (C) 2017-2023 Red Hat, Inc."))
        XCTAssertFalse(dependencyLicenses.contains("===== CRATE getrandom 0.4.3 ====="))
        XCTAssertFalse(dependencyLicenses.contains("===== CRATE r-efi 6.0.0 ====="))
    }

    func testSourceOnlyLegacyCompatibilityFixturesRemainByteExact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures: [String: Data] = [
            "config.json": Data("""
            {"version":2,"hotkeys":{"toggle":{"modifiers":["shift","ctrl"]},"push_to_talk":{"modifiers":["cmd","shift"]}},"output_mode":"general","history":[],"whisper_model":"small","llm_model":"gemma3","engine":"whisper"}
            """.utf8),
            "venv/bin/python": Data("legacy-python-placeholder".utf8),
            "kokoro_server.py": Data("# legacy rollback fixture".utf8),
            "models/native-valid-asset.marker": Data("immutable-native-asset".utf8),
            "preferences/tts-voice": Data("bm_lewis".utf8),
            "sessions/older/transcript.txt": Data("Public synthetic transcript fixture.".utf8)
        ]
        for (relative, data) in fixtures {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        let config = try JSONDecoder().decode(AppConfig.self, from: XCTUnwrap(fixtures["config.json"]))
        XCTAssertEqual(config.engine, .whisper)
        XCTAssertEqual(KokoroVoice(rawValue: String(decoding: try XCTUnwrap(fixtures["preferences/tts-voice"]), as: UTF8.self)), .bm_lewis)

        for (relative, expected) in fixtures {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(relative)), expected, relative)
        }
    }
}
