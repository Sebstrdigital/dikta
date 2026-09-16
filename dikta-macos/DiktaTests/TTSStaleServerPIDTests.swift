import XCTest
import Darwin
@testable import Dikta

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
