import Foundation
#if canImport(NativeKokoroShared)
import NativeKokoroShared
#endif

enum NativeKokoroReadError: LocalizedError, Equatable {
    case unsupportedOS
    case notInstalled
    case selectedVoiceNotInstalled(String)
    case installerBusy
    case corruptAssets
    case helperUnavailable
    case helperFailed(NKRuntimeFailure?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Native Read Aloud is unavailable on macOS 26.4–26.5. Update macOS, then try again."
        case .notInstalled:
            return "Open Setup to install the native Text-to-Speech engine."
        case .selectedVoiceNotInstalled(let voice):
            return "The selected bundled voice (\(voice)) is unavailable. Run Read Aloud Setup again; Dikta will not substitute another voice."
        case .installerBusy:
            return "Text-to-Speech Setup is updating voice assets. Wait for Setup to finish, then try again."
        case .corruptAssets:
            return "Native Text-to-Speech assets are incomplete or corrupt. Open Setup and retry the installation."
        case .helperUnavailable:
            return "The signed native voice helper could not be verified or started. Reinstall Dikta or retry Setup."
        case .helperFailed(let failure):
            switch failure {
            case .unsupportedOS: return NativeKokoroReadError.unsupportedOS.errorDescription
            case .missing, .size, .digest, .migration, .manifest, .layout:
                return NativeKokoroReadError.corruptAssets.errorDescription
            case .input:
                return "This selection is not supported by the native voice engine."
            default:
                return "The native voice engine failed. Stop Read Aloud and try again."
            }
        case .invalidResponse:
            return "The native voice helper returned invalid audio and was stopped."
        }
    }
}

struct NativeKokoroAssetSnapshot: Equatable, Sendable {
    let revision: String
    let voiceID: String
    let voiceDigest: String
    let speed: Float
    init(revision: String, voiceID: String, voiceDigest: String, speed: Float = 1) {
        self.revision = revision; self.voiceID = voiceID; self.voiceDigest = voiceDigest; self.speed = speed
    }
}

@MainActor
protocol NativeKokoroRuntimeServing: AnyObject {
    /// A scoped readiness probe. No lease, helper, or runtime state survives return.
    func prepare(voiceID: String, speed: Float) async throws -> NativeKokoroAssetSnapshot
    /// Acquires and owns a use lease for generation through playback drain/idle.
    func synthesize(text: String, snapshot: NativeKokoroAssetSnapshot) async throws -> Data
    /// Returns the identity of the helper session that produced the last audio.
    /// The service captures it immediately after synthesis and returns it only
    /// when that exact buffer finishes playback.
    func capturePlaybackDrainToken() -> UUID?
    func playbackDrained(token: UUID?)
    func playbackDrained()
    func stop()
}

extension NativeKokoroRuntimeServing {
    func capturePlaybackDrainToken() -> UUID? { nil }
    func playbackDrained(token: UUID?) { playbackDrained() }
}

@MainActor
final class NativeKokoroRuntimeClient: NativeKokoroRuntimeServing {
    private struct Prepared: @unchecked Sendable {
        let snapshot: NativeKokoroAssetSnapshot
        let lease: NKAssetLease
    }

    /// One immutable ownership epoch. All post-await writes and cleanup are
    /// accepted only while this exact object is current.
    private final class Context {
        let epoch: UInt64
        let snapshot: NativeKokoroAssetSnapshot
        let lease: NKAssetLease
        var session: NativeKokoroSession?
        var sessionID: UUID?
        var idleTask: Task<Void, Never>?

        init(epoch: UInt64, prepared: Prepared) {
            self.epoch = epoch
            snapshot = prepared.snapshot
            lease = prepared.lease
        }
    }

    private var context: Context?
    private var epoch: UInt64 = 0
    private var nextRequest: UInt64 = 1
    private var lastPlaybackDrainToken: UUID?
    private let executable: () -> URL
    private let resolveHome: @Sendable () throws -> URL
    private let osVersion: () -> OperatingSystemVersion
    private let idleNanoseconds: UInt64
    private let makeSession: (() -> NativeKokoroSession)?
    private let verificationHook: @Sendable () throws -> Void
    private let timing: (String, TimeInterval) -> Void

    init(
        executable: @escaping () -> URL = { NativeKokoroSession.packagedURL() },
        resolveHome: @escaping @Sendable () throws -> URL = { try NativeKokoroLayoutDescriptor.productionHome() },
        osVersion: @escaping () -> OperatingSystemVersion = { ProcessInfo.processInfo.operatingSystemVersion },
        idleNanoseconds: UInt64 = 120_000_000_000,
        makeSession: (() -> NativeKokoroSession)? = nil,
        verificationHook: @escaping @Sendable () throws -> Void = {},
        timing: @escaping (String, TimeInterval) -> Void = ReadAloudTiming.log
    ) {
        self.executable = executable
        self.resolveHome = resolveHome
        self.osVersion = osVersion
        self.idleNanoseconds = idleNanoseconds
        self.makeSession = makeSession
        self.verificationHook = verificationHook
        self.timing = timing
    }

    func prepare(voiceID: String, speed: Float = 1) async throws -> NativeKokoroAssetSnapshot {
        let start = ReadAloudTiming.now
        let worker = try verificationWorker(voiceID: voiceID, speed: speed)
        let prepared = try await withTaskCancellationHandler(
            operation: { try await worker.value },
            onCancel: { worker.cancel() }
        )
        try Task.checkCancellation()
        // `prepared.lease` is intentionally scoped to this function. ARC releases
        // it on every success, error, and cancellation return.
        timing("runtime.verify_probe", ReadAloudTiming.now - start)
        return prepared.snapshot
    }

    func synthesize(text: String, snapshot: NativeKokoroAssetSnapshot) async throws -> Data {
        try Task.checkCancellation()
        epoch &+= 1
        let operationEpoch = epoch
        let verificationStart = ReadAloudTiming.now
        let worker = try verificationWorker(voiceID: snapshot.voiceID, speed: snapshot.speed)
        let prepared = try await withTaskCancellationHandler(
            operation: { try await worker.value },
            onCancel: { worker.cancel() }
        )
        try Task.checkCancellation()
        guard epoch == operationEpoch, prepared.snapshot == snapshot else {
            throw CancellationError()
        }

        timing("runtime.verify_generation", ReadAloudTiming.now - verificationStart)
        let owned: Context
        if let existing = context, existing.snapshot == snapshot {
            // Move the warm session into a new immutable operation context. The
            // newly verified lease is acquired before the old context releases
            // its lease, so Setup never observes an unsafe ownership gap.
            existing.idleTask?.cancel()
            existing.idleTask = nil
            let created = Context(epoch: operationEpoch, prepared: prepared)
            created.session = existing.session
            created.sessionID = existing.sessionID
            existing.session = nil
            existing.sessionID = nil
            context = created
            owned = created
        } else {
            retireCurrent()
            let created = Context(epoch: operationEpoch, prepared: prepared)
            context = created
            owned = created
        }

        do {
            let session = try await synthesisSession(for: owned)
            try requireCurrent(owned)
            let payload = try NKSynthesisRequest(voiceID: snapshot.voiceID, speed: snapshot.speed, text: text).encoded()
            let request = takeRequestID()
            let synthesisStart = ReadAloudTiming.now
            try session.begin(.synthesize, request: request, payload: payload, cold: false)
            try await waitUntilReady(session, context: owned, deadline: NativeKokoroSession.workDeadline + 1)
            try requireCurrent(owned)
            let frames = session.takeResults()
            guard frames.count == 2, frames[0].kind == .audio, frames[1].kind == .complete,
                  frames[0].request == request, frames[1].request == request else {
                throw NativeKokoroReadError.invalidResponse
            }
            try NKAudio.validate(frames[0].payload)
            timing("helper.first_buffer", ReadAloudTiming.now - synthesisStart)
            lastPlaybackDrainToken = owned.sessionID
            return frames[0].payload
        } catch is CancellationError {
            retire(owned)
            throw CancellationError()
        } catch let error as NativeKokoroReadError {
            retire(owned)
            throw error
        } catch {
            let failure = owned.session?.runtimeFailure
            retire(owned)
            throw NativeKokoroReadError.helperFailed(failure)
        }
    }

    func capturePlaybackDrainToken() -> UUID? {
        defer { lastPlaybackDrainToken = nil }
        return lastPlaybackDrainToken
    }

    /// Legacy callers do not carry an audio identity. Read Aloud always uses
    /// the tokenized overload; this remains only for existing direct tests.
    func playbackDrained() {
        playbackDrained(token: context?.sessionID)
    }

    func playbackDrained(token: UUID?) {
        guard let token, let owned = context, owned.sessionID == token, let session = owned.session else { return }
        switch session.markPlaybackDrained() {
        case .terminal:
            retire(owned)
        case .pending:
            owned.idleTask?.cancel()
            owned.idleTask = nil
        case .drained:
            owned.idleTask?.cancel()
            let delay = idleNanoseconds
            owned.idleTask = Task { @MainActor [weak self, weak owned] in
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self, let owned, self.context === owned else { return }
                self.retire(owned)
            }
        }
    }

    func stop() {
        // Invalidate the epoch and detach ownership before any cancellation can
        // resume an older suspended operation.
        epoch &+= 1
        retireCurrent()
    }

    private func verificationWorker(voiceID: String, speed: Float) throws -> Task<Prepared, Error> {
        let os = osVersion()
        guard !(os.majorVersion == 26 && (4...5).contains(os.minorVersion)) else {
            throw NativeKokoroReadError.unsupportedOS
        }
        guard [0.75, 1, 1.25, 1.75].contains(Double(speed)), let voice = NKVoiceCatalog.entry(voiceID) else {
            throw NativeKokoroReadError.selectedVoiceNotInstalled(voiceID)
        }
        let resolver = resolveHome
        let verificationHook = verificationHook
        return Task.detached(priority: .userInitiated) {
            let home: URL
            do { home = try resolver() }
            catch { throw NativeKokoroReadError.helperUnavailable }
            try Task.checkCancellation()
            let lease: NKAssetLease
            do { lease = try NKAssetLease(home: home, mode: .shared) }
            catch NKLeaseFailure.busy { throw NativeKokoroReadError.installerBusy }
            catch { throw NativeKokoroReadError.corruptAssets }
            try verificationHook()
            try Task.checkCancellation()
            let layout = NKAssetLayout(home: home)
            let complete = try? Data(contentsOf: layout.modelsRoot.appendingPathComponent("COMPLETE"))
            guard complete == Data("revision=\(NKAssetManifest.revision)\n".utf8) else {
                throw NativeKokoroReadError.notInstalled
            }
            let manifest: NKAssetManifest
            do {
                manifest = try NKAssetManifest.decodePinned(NKEmbeddedManifest.data)
                try NKAssetVerifier.verify(manifest, layout: layout)
            } catch {
                throw NativeKokoroReadError.corruptAssets
            }
            do { try NKVoiceCatalog.verify(voiceID, layout: layout) }
            catch {
                throw NativeKokoroReadError.selectedVoiceNotInstalled(voiceID)
            }
            try Task.checkCancellation()
            return Prepared(
                snapshot: NativeKokoroAssetSnapshot(
                    revision: NKAssetManifest.revision,
                    voiceID: voiceID,
                    voiceDigest: voice.derivedSHA256,
                    speed: speed
                ),
                lease: lease
            )
        }
    }

    private func synthesisSession(for owned: Context) async throws -> NativeKokoroSession {
        var session = try await readySession(for: owned)
        while true {
            try requireCurrent(owned)
            switch session.requestAdmission() {
            case .available:
                return session
            case .waitForDrain:
                // A full warm helper may still own the currently playing buffer.
                // Keep that exact session/credit alive until tagged playback drain;
                // no replacement helper is launched concurrently.
                try await Task.sleep(nanoseconds: 1_000_000)
            case .rollover:
                owned.idleTask?.cancel()
                owned.idleTask = nil
                session.shutdown()
                try await waitUntilRetired(session, context: owned)
                guard context === owned, owned.session === session else { throw CancellationError() }
                owned.session = nil
                owned.sessionID = nil
                session = try await readySession(for: owned)
            case .terminal:
                throw NativeKokoroReadError.helperFailed(session.runtimeFailure)
            }
        }
    }

    private func readySession(for owned: Context) async throws -> NativeKokoroSession {
        try requireCurrent(owned)
        if let session = owned.session, session.state == .ready, session.isEngineReady { return session }
        if let stale = owned.session { stale.shutdown(); owned.session = nil }
        let created = makeSession?() ?? NativeKokoroSession(factory: { [executable] in
            try NativeKokoroChild(executable: executable())
        })
        owned.session = created
        owned.sessionID = UUID()
        do {
            let launchStart = ReadAloudTiming.now
            try created.startAsync()
            try await waitUntilReady(created, context: owned, deadline: NativeKokoroSession.startupDeadline + 1)
            try requireCurrent(owned)
            timing("helper.launch", ReadAloudTiming.now - launchStart)
            let request = takeRequestID()
            let initializationStart = ReadAloudTiming.now
            try created.begin(.initialize, request: request, cold: true)
            try await waitUntilReady(created, context: owned, deadline: NativeKokoroSession.coldInitializationDeadline + 1)
            try requireCurrent(owned)
            guard created.isEngineReady, created.takeResults().map(\.kind) == [.complete] else {
                throw NativeKokoroReadError.helperFailed(created.runtimeFailure)
            }
            timing("helper.initialize", ReadAloudTiming.now - initializationStart)
            return created
        } catch {
            created.shutdown()
            if context === owned, owned.session === created {
                owned.session = nil
                owned.sessionID = nil
            }
            throw error
        }
    }

    private func waitUntilRetired(_ session: NativeKokoroSession, context owned: Context) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + NativeKokoroSession.reconciliationDeadline + 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            try requireCurrent(owned)
            switch session.state {
            case .stopped, .failed:
                return
            case .retiring, .cancelling:
                try await Task.sleep(nanoseconds: 10_000_000)
            case .starting, .ready, .working:
                throw NativeKokoroReadError.helperUnavailable
            }
        }
        throw NativeKokoroReadError.helperUnavailable
    }

    private func waitUntilReady(_ session: NativeKokoroSession, context owned: Context, deadline seconds: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            try requireCurrent(owned)
            switch session.state {
            case .ready: return
            case .failed, .stopped, .retiring:
                throw NativeKokoroReadError.helperFailed(session.runtimeFailure)
            case .starting, .working, .cancelling:
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        throw NativeKokoroReadError.helperUnavailable
    }

    private func requireCurrent(_ owned: Context) throws {
        try Task.checkCancellation()
        guard context === owned, epoch == owned.epoch else { throw CancellationError() }
    }

    private func retireCurrent() {
        guard let owned = context else { return }
        context = nil
        owned.idleTask?.cancel()
        owned.idleTask = nil
        owned.session?.cancel()
        owned.session?.shutdown()
        owned.session = nil
        owned.sessionID = nil
        lastPlaybackDrainToken = nil
    }

    private func retire(_ owned: Context) {
        guard context === owned else { return }
        retireCurrent()
    }

    private func takeRequestID() -> UInt64 {
        defer { nextRequest &+= 1 }
        if nextRequest == 0 { nextRequest = 1 }
        return nextRequest
    }

    deinit {
        context?.idleTask?.cancel()
        context?.session?.shutdown()
    }
}
