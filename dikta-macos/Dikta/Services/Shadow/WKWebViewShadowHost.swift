import AppKit
import WebKit
import Darwin

/// One running process as seen by the scanner.
struct ShadowProcessInfo: Equatable {
    let pid: pid_t
    let path: String
    /// The process macOS attributes this one to (WebKit XPC helpers are attributed to the app).
    let responsiblePID: pid_t
    /// BSD parent PID (`pbi_ppid`); -1 when unknown. Chromium helpers are children of the
    /// main browser process.
    var parentPID: pid_t = -1
}

enum WebKitProcessScanner {
    /// The WebKit helper that owns page audio output. A live spike (macOS 26) showed the GPU
    /// process is the only WebKit process with a running CoreAudio process object while a
    /// page plays audio (media and WebRTC alike); the WebContent process never gets one.
    /// `gpuPID` is the web view's own GPU process identifier (WebKit SPI) when available and
    /// is unioned with the responsibility scan. Never the app's own PID.
    static func audioProcessIDs(in processes: [ShadowProcessInfo], ownPID: pid_t, gpuPID: pid_t? = nil) -> [pid_t] {
        var pids = Set(processes
            .filter { $0.pid != ownPID && $0.responsiblePID == ownPID }
            .filter { $0.path.contains("com.apple.WebKit.GPU") }
            .map(\.pid))
        if let gpuPID, gpuPID > 0, gpuPID != ownPID { pids.insert(gpuPID) }
        return pids.sorted()
    }

    /// `root` plus every live descendant of it (by BSD parent PID), sorted. Empty when
    /// `root` is not in `processes`.
    static func processTree(rootedAt root: pid_t, in processes: [ShadowProcessInfo]) -> [pid_t] {
        guard processes.contains(where: { $0.pid == root }) else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for process in processes where process.pid != process.parentPID {
            children[process.parentPID, default: []].append(process.pid)
        }
        var found: Set<pid_t> = [root]
        var queue = [root]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where found.insert(child).inserted {
                queue.append(child)
            }
        }
        return found.sorted()
    }

    /// Live process list via libproc; responsibility via the (unexported-in-headers) libSystem call.
    static func liveProcesses() -> [ShadowProcessInfo] {
        typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
        let responsible = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: ResponsibleFn.self) }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).compactMap { pid in
            guard pid > 0 else { return nil }
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let parent: pid_t = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : -1
            return ShadowProcessInfo(pid: pid, path: String(cString: buf),
                                     responsiblePID: responsible?(pid) ?? -1, parentPID: parent)
        }
    }

    /// The web view's GPU process PID via WebKit SPI (`_gpuProcessIdentifier`), guarded by
    /// `responds(to:)` so a WebKit without it yields nil. 0 means "no GPU process yet".
    static func gpuProcessIdentifier(of webView: NSObject) -> pid_t? {
        let selector = NSSelectorFromString("_gpuProcessIdentifier")
        guard webView.responds(to: selector),
              let number = webView.value(forKey: "_gpuProcessIdentifier") as? NSNumber else { return nil }
        let pid = number.int32Value
        return pid > 0 ? pid : nil
    }
}

/// Joins through an off-screen WKWebView. Mic and camera stay off because every media
/// capture request is denied in the UI delegate.
@MainActor
final class WKWebViewShadowHost: NSObject, ShadowHost, WKUIDelegate, WKNavigationDelegate {
    let events: AsyncStream<ShadowEvent>
    private let continuation: AsyncStream<ShadowEvent>.Continuation
    private let profiles: [ShadowPlatformProfile]
    private let driverTemplate: ShadowJoinDriver?
    private let processLister: () -> [ShadowProcessInfo]

    private var window: NSWindow?
    private var webView: WKWebView?
    private var joinTask: Task<Void, Never>?
    private var finished = false

    /// `driver` is injectable so tests can shorten the poll interval and timeouts; its
    /// `evaluate` is replaced by the web view's.
    init(profiles: [ShadowPlatformProfile] = ShadowPlatform.table,
         driver: ShadowJoinDriver? = nil,
         processLister: @escaping () -> [ShadowProcessInfo] = WebKitProcessScanner.liveProcesses) {
        var cont: AsyncStream<ShadowEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
        self.profiles = profiles
        self.driverTemplate = driver
        self.processLister = processLister
        super.init()
    }

    var audioProcessIDs: [pid_t] {
        let gpuPID = webView.flatMap { WebKitProcessScanner.gpuProcessIdentifier(of: $0) }
        return WebKitProcessScanner.audioProcessIDs(in: processLister(), ownPID: getpid(), gpuPID: gpuPID)
    }

    func join(url: URL, displayName: String) async {
        guard webView == nil else { return }
        emit(.state(.joining))
        guard let profile = ShadowPlatform.profile(for: url, in: profiles) else {
            fail(.unsupportedPlatform); return
        }
        guard let selectors = profile.selectors else {
            fail(.platformNotImplemented(profile.platform.rawValue)); return
        }

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        view.uiDelegate = self
        view.navigationDelegate = self
        // Borderless, fully transparent and click-through: never seen, but on screen so the page counts as
        // visible. Far off-screen the page is "hidden" and WebKit parks getUserMedia without asking the delegate.
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.contentView = view
        win.orderFrontRegardless()
        window = win
        webView = view

        let target = profile.rewrite(url)
        if target.isFileURL {
            view.loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: target))
        }

        var driver = driverTemplate ?? ShadowJoinDriver(evaluate: { _ in "" })
        driver = ShadowJoinDriver(
            evaluate: { [weak view] js in
                guard let view else { throw CancellationError() }
                return try await view.evaluateJavaScript(js) as? String ?? ""
            },
            pollInterval: driver.pollInterval,
            controlsTimeout: driver.controlsTimeout,
            admissionTimeout: driver.admissionTimeout)
        joinTask = Task { [weak self] in
            var admitted = false
            await driver.run(name: displayName, selectors: selectors) { state in
                if state == .admitted { admitted = true }
                self?.report(state)
            }
            guard admitted, !Task.isCancelled else { return }
            let poller = ShadowSpeakerPoller(evaluate: driver.evaluate, pollInterval: driver.pollInterval)
            await poller.run(selectors: selectors) { self?.emit($0) }
        }
    }

    /// Runs JS in the hosted page; lets tests read what the page observed.
    func evaluate(_ js: String) async -> String {
        (try? await webView?.evaluateJavaScript(js) as? String) ?? ""
    }

    func leave() async {
        joinTask?.cancel()
        joinTask = nil
        webView?.stopLoading()
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
        webView?.uiDelegate = nil
        webView?.navigationDelegate = nil
        window?.close()
        window = nil
        webView = nil
        if !finished { emit(.state(.left)) }
        finished = true
        continuation.finish()
    }

    // MARK: - Events

    private func emit(_ event: ShadowEvent) { continuation.yield(event) }

    private func report(_ state: ShadowJoinState) {
        guard !finished else { return }
        if case .failed = state { finished = true }
        emit(.state(state))
    }

    private func fail(_ reason: ShadowFailure) {
        report(.failed(reason))
    }

    // MARK: - WKUIDelegate

    /// Mic and camera must stay off: deny every capture request.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        emit(.pageWarning("media capture denied"))
        decisionHandler(.deny)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        joinTask?.cancel()
        fail(.pageLoadFailed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        joinTask?.cancel()
        fail(.pageLoadFailed(error.localizedDescription))
    }
}
