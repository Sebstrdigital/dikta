import Foundation
#if canImport(NativeKokoroShared)
import NativeKokoroShared
#endif

// Qualification lifecycle seam. Not constructed by DiktaApp or production TTS.
final class NativeKokoroSession {
    enum State: Equatable { case stopped, starting, ready, working, cancelling, retiring, failed }
    static let startupDeadline: TimeInterval = 5
    static let coldInitializationDeadline: TimeInterval = 90
    static let laterInitializationDeadline: TimeInterval = 30
    static let workDeadline: TimeInterval = 30
    static let cancelDeadline: TimeInterval = 0.25
    static let forceDeadline: TimeInterval = 1
    static let reconciliationDeadline: TimeInterval = 3
    static let idleDeadline: TimeInterval = 120
    private let queue = DispatchQueue(label: "com.duatalk.native-kokoro.owner")
    private let clock: () -> TimeInterval
    private let factory: () throws -> NKChild
    private var child: NKChild?
    private var timer: DispatchSourceTimer?
    private var decoder = NKDecoder()
    private var outbox = NKOutbox()
    private var gate: NKIdentityGate
    private var request: UInt64 = 0
    private var nextSequence: UInt32 = 0
    private var deadline: TimeInterval = 0
    private var retirementStart: TimeInterval = 0
    private var forced = false
    private var resultFrames: [NKFrame] = []
    private var resultBytes = 0
    private var current: State = .stopped
    private var started = false
    private var usedRequests = Set<UInt64>()
    private var launchEpoch: UInt64 = 0
    private let launchQueue = DispatchQueue(label: "com.duatalk.native-kokoro.launch")
    private var operation: NKKind = .blockedWork
    private var engineReady = false
    private var lastFailure: NKRuntimeFailure?
    private var lastPhase: NKPhase?
    private var reconciliationExceeded = false
    var runtimeFailure: NKRuntimeFailure? { queue.sync { lastFailure } }
    var phase: NKPhase? { queue.sync { lastPhase } }
    var isEngineReady: Bool { queue.sync { engineReady } }
    var exceededReconciliation: Bool { queue.sync { reconciliationExceeded } }
    private(set) var session: UInt64
    var state: State { queue.sync { current } }
    init(session: UInt64 = UInt64.random(in: 1...UInt64.max), clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, factory: @escaping () throws -> NKChild) {
        self.session = session; self.clock = clock; self.factory = factory; gate = NKIdentityGate(session: session)
    }
    static func packagedURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/Helpers/NativeKokoroHelper")
    }
    func start(automatic: Bool = true) throws {
        if automatic { try startAsync(); return }
        // Synchronous mode is reserved for deterministic inert/fake tests.
        try queue.sync {
            guard child == nil, current == .stopped, !started else { throw NKError.identity }
            started = true
            do {
                child = try factory(); current = .starting; deadline = clock() + Self.startupDeadline
                try send(.hello)
                if automatic {
                    let source = DispatchSource.makeTimerSource(queue: queue)
                    source.schedule(deadline: .now(), repeating: .milliseconds(10))
                    source.setEventHandler { [weak self] in self?.pumpLocked() }
                    timer = source; source.resume()
                }
            } catch { current = .failed; retireLocked(); throw error }
        }
    }
    // Qualification callers use this nonblocking launch seam: a stuck factory cannot
    // hold the deadline/control owner. Legacy inert tests retain synchronous start.
    func startAsync(automatic: Bool = true) throws {
        try queue.sync {
            guard child == nil, current == .stopped, !started else { throw NKError.identity }
            started = true; launchEpoch &+= 1
            let token = launchEpoch
            current = .starting; deadline = clock() + Self.startupDeadline
            if automatic {
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now(), repeating: .milliseconds(10))
                source.setEventHandler { [weak self] in self?.pumpLocked() }
                timer = source; source.resume()
            }
            let make = factory
            launchQueue.async { [weak self] in
                let result = Result { try make() }
                guard let self else {
                    if case .success(let orphan) = result { orphan.closeControl(); orphan.signal(force: true); orphan.closeResults() }
                    return
                }
                self.queue.async {
                    guard self.launchEpoch == token, self.current == .starting else {
                        if case .success(let stale) = result { stale.closeControl(); stale.signal(force: true); stale.closeResults() }
                        return
                    }
                    switch result {
                    case .success(let owned):
                        self.child = owned
                        do { try self.send(.hello) } catch { self.retireLocked() }
                    case .failure: self.current = .failed; self.timer?.cancel(); self.timer = nil
                    }
                }
            }
        }
    }
    func begin(_ kind: NKKind, request id: UInt64, payload: Data = Data(), cold: Bool = true) throws {
        try queue.sync {
            guard current == .ready, id != 0, [.describe, .initialize, .synthesize, .loopback].contains(kind),
                  resultFrames.isEmpty else { throw NKError.identity }
            try NKControl.validate(NKFrame(kind, session: session, request: id, payload: payload))
            guard usedRequests.count < 64, usedRequests.insert(id).inserted else { throw NKError.identity }
            request = id; nextSequence = 0; gate = NKIdentityGate(session: session, request: id)
            operation = kind; lastFailure = nil; lastPhase = nil
            try send(kind, payload: payload); current = .working
            deadline = clock() + (kind == .initialize ? (cold ? Self.coldInitializationDeadline : Self.laterInitializationDeadline) : Self.workDeadline)
        }
    }
    func beginBlockedWork(request id: UInt64) throws {
        try queue.sync {
            guard current == .ready, id != 0 else { throw NKError.identity }
            request = id; nextSequence = 0; gate = NKIdentityGate(session: session, request: id)
            try send(.blockedWork); current = .working; deadline = clock() + Self.workDeadline
        }
    }
    func cancel() {
        queue.sync {
            guard current == .working || current == .starting else { return }
            // Invalidate result ownership before sending cancellation; no stale audio is exposed.
            resultFrames.removeAll(); resultBytes = 0
            if child == nil { retireLocked(); return }
            current = .cancelling; deadline = clock() + Self.cancelDeadline
            do { try send(.cancel) } catch { retireLocked() }
        }
    }
    func shutdown() { queue.sync { retireLocked() } }
    func tick() { queue.sync { pumpLocked() } }
    func takeResults() -> [NKFrame] { queue.sync { let frames = resultFrames; resultFrames.removeAll(); resultBytes = 0; return frames } }
    private func send(_ kind: NKKind, payload: Data = Data()) throws {
        guard nextSequence < UInt32.max else { throw NKError.sequence }
        try outbox.enqueue(NKFrame(kind, session: session, request: request, sequence: nextSequence, payload: payload)); nextSequence += 1
    }
    private func retireLocked() {
        guard current != .retiring else { return }
        guard let child else {
            // Terminal cleanup is idempotent, but pending launch/work still loses
            // ownership so a late factory result cannot revive this instance.
            launchEpoch &+= 1
            if current != .stopped && current != .failed { current = .failed }
            timer?.cancel(); timer = nil
            return
        }
        current = .retiring; retirementStart = clock(); forced = false
        resultFrames.removeAll(); resultBytes = 0; outbox.clear()
        child.closeControl(); child.signal(force: false)
    }
    private func pumpLocked() {
        guard let child else {
            if current == .starting && clock() >= deadline { retireLocked() }
            return
        }
        if child.exited() {
            child.closeControl(); child.closeResults(); self.child = nil; timer?.cancel(); timer = nil
            resultFrames.removeAll(); resultBytes = 0; outbox.clear()
            current = current == .retiring ? .stopped : .failed
            return
        }
        let now = clock()
        if current == .retiring {
            if !forced && now - retirementStart >= Self.forceDeadline { child.signal(force: true); forced = true }
            // Ownership remains retained and polled if an OS-level exit is delayed.
            if now - retirementStart >= Self.reconciliationDeadline { reconciliationExceeded = true; child.closeResults() }
            return
        }
        do {
            try outbox.flush { try child.write($0) }
            guard let bytes = try child.read() else { try decoder.finish(); retireLocked(); return }
            try decoder.feed(bytes) { frame in
                guard try gate.accept(frame) else { return }
                switch (current, frame.kind) {
                case (.starting, .ready): current = .ready; deadline = now + Self.idleDeadline
                case (.cancelling, .cancelled): retireLocked()
                case (.working, .phase):
                    let phase = try NKControl.phase(frame.payload)
                    guard lastPhase == nil, (operation == .initialize && phase == .initializing) ||
                          (operation == .synthesize && phase == .synthesizing) else { throw NKError.identity }
                    lastPhase = phase
                case (.working, .layout):
                    guard operation == .describe || operation == .loopback, frame.payload.count <= 4096,
                          resultFrames.count < 2 else { throw NKError.identity }
                    resultFrames.append(frame); resultBytes += frame.payload.count
                case (.working, .complete):
                    guard frame.payload.isEmpty, resultFrames.count < 3 else { throw NKError.framing }
                    if operation == .initialize { engineReady = true }
                    resultFrames.append(frame); current = .ready; deadline = now + Self.idleDeadline
                case (.working, .failed):
                    lastFailure = try NKControl.failure(frame.payload); engineReady = false; retireLocked()
                case (.cancelling, .phase), (.cancelling, .complete), (.cancelling, .failed), (.cancelling, .layout): break
                case (.working, .audio):
                    try NKAudio.validate(frame.payload)
                    guard resultFrames.count < 2, resultBytes + frame.payload.count <= NKOutbox.maxBytes else { throw NKError.backpressure }
                    resultFrames.append(frame); resultBytes += frame.payload.count
                case (.cancelling, .audio): break // no stale playback after Stop
                default: throw NKError.identity
                }
            }
            if now >= deadline { retireLocked() }
        } catch { retireLocked() }
    }
    deinit {
        timer?.cancel()
        child?.closeControl(); child?.signal(force: true); child?.closeResults()
        // The concrete child retains unreaped ownership through its private reaper.
    }
}
