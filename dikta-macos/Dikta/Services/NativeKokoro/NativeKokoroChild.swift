import Foundation
import Darwin
#if canImport(NativeKokoroShared)
import NativeKokoroShared
#endif

protocol NKChild: AnyObject {
    func read() throws -> Data? // nil = EOF; empty = would block
    func write(_ data: Data) throws -> Int // zero = would block
    func exited() -> Bool
    func signal(force: Bool)
    func closeControl()
    func closeResults()
}

// Owns the unreaped direct child, not a discovered PID or Foundation Process snapshot.
// waitpid and signalling are serialized; an exited child is never signalled after reap.
final class NativeKokoroChild: NKChild {
    private let lock = NSLock()
    private var pid: pid_t?
    private var input: Int32 = -1
    private var output: Int32 = -1

    enum SetupStage: CaseIterable { case actions, attributes, input, output, stderr, flags }
    init(executable: URL, setupStatus: (SetupStage, Int32) -> Int32 = { _, status in status }) throws {
        var control: [Int32] = [-1, -1], result: [Int32] = [-1, -1]
        guard pipe(&control) == 0 else { throw NKError.launch }
        guard pipe(&result) == 0 else { close(control[0]); close(control[1]); throw NKError.launch }
        // All fallible descriptor configuration precedes spawn and ownership publication.
        defer { for fd in control + result where fd >= 0 { close(fd) } }
        try NKDescriptorSetup.nonblocking(control[1], noSIGPIPE: true)
        try NKDescriptorSetup.nonblocking(result[0], noSIGPIPE: false)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let actionsStatus = posix_spawn_file_actions_init(&actions)
        defer { if actionsStatus == 0 { posix_spawn_file_actions_destroy(&actions) } }
        guard actionsStatus == 0, setupStatus(.actions, actionsStatus) == 0 else { throw NKError.launch }
        let attributesStatus = posix_spawnattr_init(&attributes)
        defer { if attributesStatus == 0 { posix_spawnattr_destroy(&attributes) } }
        guard attributesStatus == 0, setupStatus(.attributes, attributesStatus) == 0 else { throw NKError.launch }
        func check(_ stage: SetupStage, _ status: Int32) throws {
            guard status == 0, setupStatus(stage, status) == 0 else { throw NKError.launch }
        }
        try check(.input, posix_spawn_file_actions_adddup2(&actions, control[0], STDIN_FILENO))
        try check(.output, posix_spawn_file_actions_adddup2(&actions, result[1], STDOUT_FILENO))
        try check(.stderr, posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
        try check(.flags, posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)))
        guard let path = strdup(executable.path) else { throw NKError.launch }
        defer { free(path) }
        var argv: [UnsafeMutablePointer<CChar>?] = [path, nil]
        var child: pid_t = 0
        let status = posix_spawn(&child, path, &actions, &attributes, &argv, environ)
        guard status == 0 else { throw NKError.launch }
        pid = child; input = control[1]; output = result[0]
        control[1] = -1; result[0] = -1 // parent ends transferred; defer closes only unowned ends
        // No fallible setup remains after spawn. No global SIGPIPE disposition change.
    }
    func read() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard output >= 0 else { return nil }
        var data = Data(count: 16_384)
        let n = data.withUnsafeMutableBytes { Darwin.read(output, $0.baseAddress, $0.count) }
        if n == 0 { return nil }
        if n < 0 { if errno == EAGAIN || errno == EINTR { return Data() }; throw NKError.closed }
        data.count = n; return data
    }
    func write(_ data: Data) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard input >= 0 else { throw NKError.closed }
        let n = data.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
        if n < 0 { if errno == EAGAIN || errno == EINTR { return 0 }; throw NKError.closed }
        return n
    }
    private func reapLocked() -> Bool {
        guard let child = pid else { return true }
        var status: Int32 = 0
        let result = waitpid(child, &status, WNOHANG)
        if result == child || (result < 0 && errno == ECHILD) { pid = nil; return true }
        return false
    }
    func exited() -> Bool { lock.lock(); defer { lock.unlock() }; return reapLocked() }
    func signal(force: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !reapLocked(), let child = pid else { return }
        _ = kill(child, force ? SIGKILL : SIGTERM)
    }
    func closeControl() { lock.lock(); defer { lock.unlock() }; if input >= 0 { close(input); input = -1 } }
    func closeResults() { lock.lock(); defer { lock.unlock() }; if output >= 0 { close(output); output = -1 } }
    deinit {
        closeControl(); closeResults(); signal(force: true)
        // Retain exclusive unreaped-child ownership in a reaper, never rediscover it.
        if let child = pid {
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            }
        }
    }
}
