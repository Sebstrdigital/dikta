import Foundation
import Darwin
#if canImport(NativeKokoroShared)
import NativeKokoroShared
#endif

// stdout is exclusively framed. SDK construction and work never run on this control owner.
do {
    try NKDescriptorSetup.nonblocking(STDIN_FILENO, noSIGPIPE: false)
    try NKDescriptorSetup.nonblocking(STDOUT_FILENO, noSIGPIPE: true)
} catch { exit(2) }
var decoder = NKDecoder()
var outbox = NKOutbox()
var gate: NKIdentityGate?
var session: UInt64 = 0
var activeRequest: UInt64 = 0
var outputSequence: UInt32 = 0
var usedRequests = Set<UInt64>()
var hello = false
var exiting = false
var exitDeadline: TimeInterval = 0
let workerGate = DispatchSemaphore(value: 0)
let mailbox = NKResultMailbox()
let workOwner = DispatchQueue(label: "com.duatalk.native-kokoro.sdk")
// Accessed exclusively by workOwner; at most one operation is submitted at a time.
var engine: NKVerifiedEngine?
let startupDeadline = ProcessInfo.processInfo.systemUptime + 5
var outputDeadline = startupDeadline

func pinnedManifest() throws -> Data {
    // The helper's sandbox cannot depend on access to its unsandboxed parent's bundle.
    // These bytes are part of the signed helper and remain pinned by decodePinned.
    let data = NKEmbeddedManifest.data
    _ = try NKAssetManifest.decodePinned(data)
    return data
}
func respond(_ kind: NKKind, request: UInt64 = 0, payload: Data = Data()) throws {
    guard outputSequence < UInt32.max else { throw NKError.sequence }
    try outbox.enqueue(NKFrame(kind, session: session, request: request, sequence: outputSequence, payload: payload))
    outputSequence += 1
    outputDeadline = ProcessInfo.processInfo.systemUptime + 1
}
func accept(_ frame: NKFrame) throws {
    try NKControl.validate(frame)
    if !hello {
        guard frame.kind == .hello, frame.session != 0, frame.request == 0, frame.sequence == 0 else { throw NKError.identity }
        session = frame.session; hello = true; gate = NKIdentityGate(session: session)
    } else if [.blockedWork, .describe, .initialize, .synthesize, .loopback].contains(frame.kind) {
        guard activeRequest == 0, outbox.bytes == 0, frame.session == session,
              frame.request != 0, usedRequests.count < 64, usedRequests.insert(frame.request).inserted else { throw NKError.identity }
        gate = NKIdentityGate(session: session, request: frame.request); outputSequence = 0
    }
    guard try gate!.accept(frame) else { throw NKError.identity }
    switch frame.kind {
    case .hello: try respond(.ready)
    case .describe:
        do {
            _ = try pinnedManifest()
            let layout = NKAssetLayout()
            let paths = [layout.home.path, layout.modelsRoot.path, layout.frontend.path, layout.chain.path]
            let data = try JSONSerialization.data(withJSONObject: paths)
            guard data.count <= 4096 else { throw NKRuntimeFailure.layout }
            try respond(.layout, request: frame.request, payload: data)
            try respond(.complete, request: frame.request)
        } catch { try respond(.failed, request: frame.request, payload: Data([NKRuntimeFailure.manifest.rawValue])) }
    case .blockedWork:
        activeRequest = frame.request
        workOwner.async { workerGate.wait() }
    case .initialize, .synthesize:
        activeRequest = frame.request
        let token = mailbox.begin(), request = frame.request, identity = session, operation = frame.kind
        let text = String(data: frame.payload, encoding: .utf8) ?? ""
        // This is a pre-invocation phase, NOT proof of active Core ML prediction.
        try respond(.phase, request: request, payload: Data([(operation == .initialize ? NKPhase.initializing : .synthesizing).rawValue]))
        workOwner.async {
            let settled = DispatchSemaphore(value: 0)
            Task {
                defer { settled.signal() }
                do {
                    if operation == .initialize {
                        let instance = try NativeKokoroEngine.qualificationEngine(manifestData: pinnedManifest())
                        try await instance.initialize(); engine = instance
                        mailbox.publish([NKFrame(.complete, session: identity, request: request, sequence: 1)], epoch: token)
                    } else {
                        guard let engine else { throw NKRuntimeFailure.notReady }
                        let audio = try await engine.synthesize(text: text)
                        mailbox.publish([NKFrame(.audio, session: identity, request: request, sequence: 1, payload: audio),
                                         NKFrame(.complete, session: identity, request: request, sequence: 2)], epoch: token)
                    }
                } catch {
                    let safe = (error as? NKRuntimeFailure) ?? .synthesis
                    mailbox.publish([NKFrame(.failed, session: identity, request: request, sequence: 1, payload: Data([safe.rawValue]))], epoch: token)
                }
            }
            settled.wait() // Dedicated serial SDK owner, never the control/output loop.
        }
    case .loopback:
        // Qualification-only direct socket attempt. Never accepts a host, URL or arbitrary port.
        let port = frame.payload.nkInteger(0, as: UInt16.self)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var outcome: Int32 = errno
        if fd >= 0 {
            defer { close(fd) }
            try NKDescriptorSetup.nonblocking(fd, noSIGPIPE: true)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            outcome = result == 0 ? 0 : errno
        }
        var data = Data(); data.nkAppend(UInt32(bitPattern: outcome))
        try respond(.layout, request: frame.request, payload: data)
        try respond(.complete, request: frame.request)
    case .cancel:
        mailbox.invalidate(); outbox.clear(); workerGate.signal()
        try respond(.cancelled, request: activeRequest)
        exiting = true; exitDeadline = ProcessInfo.processInfo.systemUptime + 1
    case .shutdown:
        mailbox.invalidate(); outbox.clear(); workerGate.signal()
        exiting = true; exitDeadline = ProcessInfo.processInfo.systemUptime + 1
    default: throw NKError.identity
    }
}
while true {
    do {
        var bytes = Data(count: 16_384)
        let n = bytes.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if n == 0 { try decoder.finish(); mailbox.invalidate(); workerGate.signal(); exit(0) }
        if n > 0 { bytes.count = n; try decoder.feed(bytes, consume: accept) }
        else if errno != EAGAIN && errno != EINTR { exit(2) }
        if !exiting {
            for frame in mailbox.take() {
                guard frame.session == session, frame.request == activeRequest else { continue }
                try outbox.enqueue(frame); outputSequence = frame.sequence + 1
                outputDeadline = ProcessInfo.processInfo.systemUptime + 1
                if frame.kind == .complete || frame.kind == .failed { activeRequest = 0 }
            }
        }
        try outbox.flush { data in
            let n = data.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EAGAIN || errno == EINTR { return 0 }; throw NKError.closed }
            return n
        }
        let now = ProcessInfo.processInfo.systemUptime
        if exiting && (outbox.bytes == 0 || now >= exitDeadline) { exit(0) }
        if (!hello && now >= startupDeadline) || (outbox.bytes > 0 && now >= outputDeadline) { exit(2) }
        usleep(10_000)
    } catch { mailbox.invalidate(); workerGate.signal(); exit(2) }
}
