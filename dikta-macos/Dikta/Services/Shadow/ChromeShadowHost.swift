import Foundation
import Darwin

enum ChromiumLocator {
    /// Order matters: first installed browser wins.
    static let candidates = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    ]

    static func find(candidates: [String] = candidates,
                     isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// Asks the kernel for an unused loopback TCP port.
    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return got == 0 ? Int(UInt16(bigEndian: out.sin_port)) : nil
    }
}

/// Minimal Chrome DevTools Protocol client over URLSessionWebSocketTask.
actor CDPConnection {
    struct CDPError: Error, Equatable { let message: String }

    private let task: URLSessionWebSocketTask
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var receiver: Task<Void, Never>?

    init(webSocketURL: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: webSocketURL)
    }

    func connect() {
        task.resume()
        receiver = Task { [weak self] in
            while !Task.isCancelled, let self {
                do {
                    let message = try await self.task.receive()
                    var data: Data?
                    switch message {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        await self.deliver(obj)
                    }
                } catch {
                    await self.failAll(error)
                    return
                }
            }
        }
    }

    private func deliver(_ obj: [String: Any]) {
        guard let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) else { return }
        if let err = obj["error"] as? [String: Any] {
            cont.resume(throwing: CDPError(message: err["message"] as? String ?? "cdp error"))
        } else {
            cont.resume(returning: obj["result"] as? [String: Any] ?? [:])
        }
    }

    private func failAll(_ error: Error) {
        let all = pending
        pending = [:]
        all.values.forEach { $0.resume(throwing: error) }
    }

    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            task.send(.string(String(decoding: payload, as: UTF8.self))) { [weak self] error in
                if let error { Task { await self?.fail(id: id, error) } }
            }
        }
    }

    private func fail(id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// `Runtime.evaluate` returning the string value of the expression.
    func evaluate(_ expression: String) async throws -> String {
        let result = try await send("Runtime.evaluate",
                                    ["expression": expression, "returnByValue": true, "awaitPromise": true])
        return (result["result"] as? [String: Any])?["value"] as? String ?? ""
    }

    func close() {
        receiver?.cancel()
        task.cancel(with: .goingAway, reason: nil)
        failAll(CancellationError())
    }
}

/// Joins through an installed Chromium browser driven over CDP. Own profile directory so
/// the guest session never touches the user's real browser profile.
@MainActor
final class ChromeShadowHost: ShadowHost {
    let events: AsyncStream<ShadowEvent>
    private let continuation: AsyncStream<ShadowEvent>.Continuation
    private let profiles: [ShadowPlatformProfile]
    private let browser: () -> URL?
    private let profileDir: URL
    private let extraArguments: [String]
    private let driverTemplate: ShadowJoinDriver?

    private var process: Process?
    private var connection: CDPConnection?
    private var joinTask: Task<Void, Never>?
    private var finished = false

    nonisolated static var defaultProfileDir: URL {
        URL(fileURLWithPath: AppPaths.appSupport).appendingPathComponent("ShadowProfile")
    }

    /// `extraArguments` lets tests add `--headless=new`; `browser` lets tests simulate no browser.
    init(profiles: [ShadowPlatformProfile] = ShadowPlatform.table,
         browser: @escaping () -> URL? = { ChromiumLocator.find() },
         profileDir: URL = ChromeShadowHost.defaultProfileDir,
         extraArguments: [String] = [],
         driver: ShadowJoinDriver? = nil) {
        var cont: AsyncStream<ShadowEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
        self.profiles = profiles
        self.browser = browser
        self.profileDir = profileDir
        self.extraArguments = extraArguments
        self.driverTemplate = driver
    }

    var audioProcessIDs: [pid_t] {
        guard let process, process.isRunning else { return [] }
        return [process.processIdentifier]
    }

    func join(url: URL, displayName: String) async {
        guard process == nil, joinTask == nil else { return }
        emit(.state(.joining))
        guard let profile = ShadowPlatform.profile(for: url, in: profiles) else {
            report(.failed(.unsupportedPlatform)); return
        }
        guard let selectors = profile.selectors else {
            report(.failed(.platformNotImplemented(profile.platform.rawValue))); return
        }
        guard let exe = browser() else {
            report(.failed(.noBrowser)); return
        }
        guard let port = ChromiumLocator.freePort() else {
            report(.failed(.launchFailed("no free port"))); return
        }
        let target = profile.rewrite(url)

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = [
            "--user-data-dir=\(profileDir.path)",
            "--app=\(target.absoluteString)",
            "--remote-debugging-port=\(port)",
            "--no-first-run",
            "--no-default-browser-check",
        ] + extraArguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
            try proc.run()
        } catch {
            report(.failed(.launchFailed(error.localizedDescription))); return
        }
        process = proc

        let template = driverTemplate ?? ShadowJoinDriver(evaluate: { _ in "" })
        joinTask = Task { [weak self] in
            do {
                let conn = try await Self.attach(port: port)
                await self?.setConnection(conn)
                // Mic and camera stay off: deny both permissions for every origin.
                for name in ["audioCapture", "videoCapture"] {
                    _ = try? await conn.send("Browser.setPermission",
                                             ["permission": ["name": name], "setting": "denied"])
                }
                let driver = ShadowJoinDriver(
                    evaluate: { try await conn.evaluate($0) },
                    pollInterval: template.pollInterval,
                    controlsTimeout: template.controlsTimeout,
                    admissionTimeout: template.admissionTimeout)
                await driver.run(name: displayName, selectors: selectors) { state in
                    Task { @MainActor in self?.report(state) }
                }
            } catch {
                await self?.report(.failed(.launchFailed("devtools: \(error.localizedDescription)")))
            }
        }
    }

    func leave() async {
        joinTask?.cancel()
        joinTask = nil
        await connection?.close()
        connection = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        if !finished { emit(.state(.left)) }
        finished = true
        continuation.finish()
    }

    private func setConnection(_ conn: CDPConnection) { connection = conn }

    private func emit(_ event: ShadowEvent) { continuation.yield(event) }

    private func report(_ state: ShadowJoinState) {
        guard !finished else { return }
        if case .failed = state { finished = true }
        emit(.state(state))
    }

    /// Waits for the debugging endpoint, then connects to the first page target.
    nonisolated private static func attach(port: Int, timeout: TimeInterval = 20) async throws -> CDPConnection {
        let list = URL(string: "http://127.0.0.1:\(port)/json")!
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let (data, _) = try? await URLSession.shared.data(from: list),
               let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let page = targets.first(where: { $0["type"] as? String == "page" }),
               let ws = (page["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) {
                let conn = CDPConnection(webSocketURL: ws)
                await conn.connect()
                return conn
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw CDPConnection.CDPError(message: "devtools endpoint never came up on port \(port)")
    }
}
