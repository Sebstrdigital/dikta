import XCTest
import Darwin
import Security
import CryptoKit
import CoreAudio
@testable import Dikta
#if canImport(NativeKokoroShared)
import NativeKokoroShared
#endif

final class NativeKokoroAssetTests: XCTestCase {
    private func candidateData() throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "candidate-base-manifest", withExtension: "json"))
        return try Data(contentsOf: url)
    }
    func testSignedCandidateIdentityAndCompleteness() throws {
        let candidate = try candidateData()
        XCTAssertEqual(NKEmbeddedManifest.data, candidate)
        let manifest = try NKAssetManifest.decodePinned(NKEmbeddedManifest.data)
        XCTAssertEqual(manifest.files.count, 49)
        XCTAssertEqual(manifest.files.reduce(0) { $0 + $1.bytes }, 94_759_376)
        XCTAssertEqual(manifest.revision, NKAssetManifest.revision)
    }
    func testFixedBundledVoiceCatalogHasFourPinnedPacks() throws {
        XCTAssertEqual(NKVoiceCatalog.entries.map(\.id), ["af_heart", "af_nicole", "am_adam", "bm_george"])
        for voice in NKVoiceCatalog.entries {
            let url = try XCTUnwrap(Bundle.main.url(forResource: voice.id, withExtension: "bin", subdirectory: "Voices"))
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            XCTAssertEqual(data.count, voice.bytes, voice.id)
            XCTAssertEqual(NKAssetManifest.hash(data), voice.derivedSHA256, voice.id)
        }
    }
    func testTamperedOrOversizedCandidateRejected() throws {
        var data = try candidateData(); data.append(0)
        XCTAssertThrowsError(try NKAssetManifest.decodePinned(data))
        XCTAssertThrowsError(try NKAssetManifest.decodePinned(Data(count: 65537)))
    }
    func testDuplicateTraversalAndIncompleteFrontendRejected() throws {
        let data = try candidateData()
        for mutation in 0..<3 {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var files = try XCTUnwrap(object["files"] as? [[String: Any]])
            if mutation == 0 { files[1] = files[0] }
            if mutation == 1 { files[0]["localPath"] = "home/../escape" }
            if mutation == 2 { files.removeLast() }
            object["files"] = files
            let malformed = try JSONDecoder().decode(NKAssetManifest.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try malformed.validate())
        }
    }
    func testPathComponentsAndFixedFoundationLayout() {
        for path in ["/absolute", "../escape", "a/../b", "a//b", "a/./b", "a\\b", "a\0b", ""] {
            XCTAssertFalse(NKAssetManifest.safeRelative(path), path)
        }
        let layout = NKAssetLayout(home: URL(fileURLWithPath: "/private/tmp/nk-fake-home"))
        XCTAssertEqual(layout.frontend.path, "/private/tmp/nk-fake-home/.cache/fluidaudio/Models/kokoro")
        XCTAssertEqual(layout.chain.path, "/private/tmp/nk-fake-home/.cache/fluidaudio/Models/kokoro-82m-coreml/ANE")
    }
    func testMissingCandidateFailsReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = try NKAssetManifest.decodePinned(candidateData())
        XCTAssertThrowsError(try NKAssetVerifier.verify(manifest, layout: NKAssetLayout(home: root))) {
            XCTAssertEqual($0 as? NKRuntimeFailure, .missing)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testStreamingSizeAndHashChecksOnOwnedSyntheticFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = Data(repeating: 17, count: 131073)
        try content.write(to: root.appendingPathComponent("fixture"))
        func entry(size: Int, digest: String) throws -> NKAssetManifest.File {
            let object: [String: Any] = ["bytes": size, "sha256": digest, "localPath": "home/fixture", "sourcePath": "fixture"]
            return try JSONDecoder().decode(NKAssetManifest.File.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let layout = NKAssetLayout(home: root)
        try NKAssetVerifier.verifyFile(entry(size: content.count, digest: NKAssetManifest.hash(content)), layout: layout)
        XCTAssertThrowsError(try NKAssetVerifier.verifyFile(entry(size: 1, digest: NKAssetManifest.hash(content)), layout: layout)) {
            XCTAssertEqual($0 as? NKRuntimeFailure, .size)
        }
        XCTAssertThrowsError(try NKAssetVerifier.verifyFile(entry(size: content.count, digest: String(repeating: "0", count: 64)), layout: layout)) {
            XCTAssertEqual($0 as? NKRuntimeFailure, .digest)
        }
    }
    func testSymlinkComponentRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // only this newly owned test fixture
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/private/tmp")
        XCTAssertThrowsError(try NKAssetVerifier.checkPath(root.appendingPathComponent("link/file"), under: root)) {
            XCTAssertEqual($0 as? NKRuntimeFailure, .layout)
        }
    }
    func testNativeInstallerRejectsDiskPressureBeforeNetworkOrWrites() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var fetched = false
        let installer = NativeKokoroInstaller(home: root, manifestData: NKEmbeddedManifest.data,
            fetch: { _, _ in fetched = true; return Data() }, available: { _ in 1 })
        do { try await installer.installBase { _, _ in }; XCTFail("expected disk guard") }
        catch { XCTAssertEqual(error as? NativeKokoroInstaller.InstallError, .disk) }
        XCTAssertFalse(fetched)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    @MainActor
    func testSharedVerifiedAvailabilityPublishesOnlyVerifiedSelectablePacks() {
        let availability = NativeKokoroVoiceAvailability.shared
        availability.update(.init(baseInstalled: true, installedVoices: ["af_bella"]))
        XCTAssertTrue(availability.isSelectable(.af_heart))
        XCTAssertTrue(availability.isSelectable(.af_bella))
        XCTAssertFalse(availability.isSelectable(.bf_emma))

        // A failed or missing base never leaves a stale optimistic selection.
        availability.update(.init(baseInstalled: false, installedVoices: ["bf_emma"]))
        XCTAssertFalse(availability.isSelectable(.af_heart))
        XCTAssertFalse(availability.isSelectable(.bf_emma))
        if case .unavailable = availability.state {} else { XCTFail("missing base must be visible") }
    }
    func testFixedVoiceCatalogHasNoAdditionalOfferings() {
        XCTAssertEqual(KokoroVoice.allCases.map(\.rawValue), NKVoiceCatalog.entries.map(\.id))
        XCTAssertNil(NKVoiceCatalog.entry("af_bella"))
    }
    func testNativeInstallerRejectsUnsignedManifestBeforeNetworkOrWrites() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var fetched = false
        var bad = NKEmbeddedManifest.data; bad.append(0)
        let installer = NativeKokoroInstaller(home: root, manifestData: bad,
            fetch: { _, _ in fetched = true; return Data() }, available: { _ in Int64.max })
        do { try await installer.installBase { _, _ in }; XCTFail("expected manifest guard") }
        catch { XCTAssertEqual(error as? NKRuntimeFailure, .manifest) }
        XCTAssertFalse(fetched)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
@MainActor
final class NativeKokoroVoiceAvailabilityTests: XCTestCase {
    private enum FixtureError: LocalizedError { case unavailable }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "controlled availability refresh did not finish")
    }

    func testRefreshSuccessFailureCancellationAndNewerVerificationOrdering() async {
        let old = NativeKokoroInstaller.Readiness(baseInstalled: true, installedVoices: ["af_bella"])
        let newest = NativeKokoroInstaller.Readiness(baseInstalled: true, installedVoices: ["bf_emma"])
        let refresh = NativeKokoroVoiceAvailability(readinessProvider: {
            try await Task.sleep(nanoseconds: 100_000_000)
            return old
        })
        refresh.refresh()
        refresh.update(newest) // models post-install verification winning a stale menu probe
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(refresh.isSelectable(.bf_emma))
        XCTAssertFalse(refresh.isSelectable(.af_bella))

        let failed = NativeKokoroVoiceAvailability(readinessProvider: { throw FixtureError.unavailable })
        failed.refresh()
        await waitUntil { if case .unavailable = failed.state { return true }; return false }
        XCTAssertFalse(failed.isSelectable(.af_heart))

        let cancelled = NativeKokoroVoiceAvailability(readinessProvider: { throw CancellationError() })
        cancelled.refresh()
        await waitUntil { cancelled.state == .unknown }
        XCTAssertFalse(cancelled.isSelectable(.af_heart))
    }
}

private func nkRuntimeTestWAV() -> Data {
    var data = Data("RIFF".utf8)
    func le(_ n: UInt32, _ size: Int) { for shift in 0..<size { data.append(UInt8(truncatingIfNeeded: n >> (8 * shift))) } }
    le(38, 4); data.append(Data("WAVEfmt ".utf8)); le(16, 4); le(1, 2); le(1, 2)
    le(24000, 4); le(48000, 4); le(2, 2); le(16, 2); data.append(Data("data".utf8)); le(2, 4); le(0, 2)
    return data
}

private final class NKRuntimeTestChild: NKChild {
    private let lock = NSLock()
    private var decoder = NKDecoder()
    private var incoming: [Data] = []
    private var dead = false
    private var synthesisCountStorage = 0
    private var nextSynthesisFailure: NKRuntimeFailure?
    let synthesisStarted = DispatchSemaphore(value: 0)
    let completeSynthesis: Bool

    init(completeSynthesis: Bool) { self.completeSynthesis = completeSynthesis }

    func read() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return incoming.isEmpty ? Data() : incoming.removeFirst()
    }
    func write(_ data: Data) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try decoder.feed(data) { frame in
            func enqueue(_ response: NKFrame) throws { incoming.append(try response.encoded()) }
            switch frame.kind {
            case .hello:
                try enqueue(NKFrame(.ready, session: frame.session))
            case .initialize:
                try enqueue(NKFrame(.phase, session: frame.session, request: frame.request,
                                    payload: Data([NKPhase.initializing.rawValue])))
                try enqueue(NKFrame(.complete, session: frame.session, request: frame.request, sequence: 1))
            case .synthesize:
                synthesisCountStorage += 1
                synthesisStarted.signal()
                if let failure = nextSynthesisFailure {
                    nextSynthesisFailure = nil
                    try enqueue(NKFrame(.failed, session: frame.session, request: frame.request,
                                        payload: Data([failure.rawValue])))
                } else if completeSynthesis {
                    try enqueue(NKFrame(.audio, session: frame.session, request: frame.request,
                                        payload: nkRuntimeTestWAV()))
                    try enqueue(NKFrame(.complete, session: frame.session, request: frame.request, sequence: 1))
                }
            case .cancel:
                try enqueue(NKFrame(.cancelled, session: frame.session, request: frame.request))
            default: break
            }
        }
        return data.count
    }
    var synthesisCount: Int { lock.lock(); defer { lock.unlock() }; return synthesisCountStorage }
    func failNextSynthesis(_ failure: NKRuntimeFailure) { lock.lock(); nextSynthesisFailure = failure; lock.unlock() }
    func exited() -> Bool { lock.lock(); defer { lock.unlock() }; return dead }
    func crash() { lock.lock(); dead = true; lock.unlock() }
    func signal(force: Bool) { lock.lock(); dead = true; lock.unlock() }
    func closeControl() {}
    func closeResults() {}
}

@MainActor
private final class NKNoopTTSPlayer: NativeTTSPlayback {
    var eventHandler: ((NativeTTSPlaybackEvent) -> Void)?
    func play(wav: Data, tag: UUID) throws {}
    func stop() {}
}

@MainActor
private final class NKImmediateTTSPlayer: NativeTTSPlayback {
    var eventHandler: ((NativeTTSPlaybackEvent) -> Void)?
    private(set) var tags: [UUID] = []
    func play(wav: Data, tag: UUID) throws {
        tags.append(tag)
        eventHandler?(.started(tag))
        eventHandler?(.finished(tag))
    }
    func stop() {}
}

private final class NKLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    func withValue<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&storage) }
    var value: Value { withValue { $0 } }
}

final class NativeKokoroFinalSourceTests: XCTestCase {
    private let fixture = URL(fileURLWithPath: "/tmp/dikta-k1-assets-20261009-1")
    private let voiceFixture = URL(fileURLWithPath: "/tmp/dikta-k2-builder/voices")

    private func makeValidHome() throws -> (root: URL, home: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nk-final-\(UUID().uuidString)")
        let home = root.appendingPathComponent("Home")
        guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".cache/fluidaudio/Models").path) else {
            XCTFail("approved read-only 49-file fixture is missing at \(fixture.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent(".cache"), to: home.appendingPathComponent(".cache"))
        let layout = NKAssetLayout(home: home)
        for entry in NKVoiceCatalog.entries where entry.id != "af_heart" {
            let source = try XCTUnwrap(Bundle.main.url(forResource: entry.id, withExtension: "bin", subdirectory: "Voices"))
            try FileManager.default.copyItem(at: source, to: layout.chain.appendingPathComponent("\(entry.id).bin"))
        }
        try Data("revision=\(NKAssetManifest.revision)\n".utf8).write(to: layout.modelsRoot.appendingPathComponent("COMPLETE"))
        return (root, home)
    }

    func testHeartOnlyUpgradeStagesAllBundledPacksWithoutBaseFetch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nk-heart-only-\(UUID().uuidString)")
        let home = root.appendingPathComponent("Home")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent(".cache"), to: home.appendingPathComponent(".cache"))
        let layout = NKAssetLayout(home: home)
        try Data("revision=\(NKAssetManifest.revision)\n".utf8).write(to: layout.modelsRoot.appendingPathComponent("COMPLETE"))
        XCTAssertNoThrow(try NKVoiceCatalog.verify("af_heart", layout: layout))
        XCTAssertThrowsError(try NKVoiceCatalog.verify("af_nicole", layout: layout))
        let fetches = NKLockedBox(0)
        let installer = try fixtureInstaller(home: home, fetchCount: fetches)
        let outcome = try await installer.installBase { _, _ in }
        XCTAssertTrue(outcome.activated)
        XCTAssertEqual(fetches.value, 0, "valid Heart-only base must be upgraded entirely from signed bundled packs")
        let readiness = try await installer.readiness()
        XCTAssertTrue(readiness.baseInstalled)
        XCTAssertEqual(readiness.installedVoices, Set(NKVoiceCatalog.entries.map(\.id)))
        for entry in NKVoiceCatalog.entries { XCTAssertNoThrow(try NKVoiceCatalog.verify(entry.id, layout: layout), entry.id) }
    }

    private func fixtureInstaller(home: URL,
                                  fetchCount: NKLockedBox<Int> = .init(0),
                                  activation: NativeKokoroActivation = .init(),
                                  sharedProbe: @escaping @Sendable () -> Void = {},
                                  exclusiveProbe: @escaping @Sendable () -> Void = {}) throws -> NativeKokoroInstaller {
        let sources = try JSONDecoder().decode(NativeKokoroInstaller.SourceManifest.self, from: NKEmbeddedManifest.data)
        let locations = Dictionary(uniqueKeysWithValues: sources.files.map {
            ($0.sourceURL, fixture.appendingPathComponent(String($0.localPath.dropFirst(5))))
        })
        return NativeKokoroInstaller(home: home, manifestData: NKEmbeddedManifest.data,
            fetch: { [voiceFixture] url, expected in
                fetchCount.withValue { $0 += 1 }
                let input = url.path.contains("/voices/")
                    ? voiceFixture.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".json")
                    : locations[url]!
                let data = try Data(contentsOf: input, options: .mappedIfSafe)
                guard data.count == expected else { throw NativeKokoroInstaller.InstallError.transport }
                return data
            }, available: { _ in Int64.max }, activation: activation,
            willVerifyUnderSharedLease: sharedProbe, willCommitUnderExclusiveLease: exclusiveProbe)
    }

    func testFailedPreflightClosesEveryReadinessAndInstallPathWithoutLeaseNetworkOrWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nk-failclosed-\(UUID().uuidString)")
        let effects = NKLockedBox<[String]>([])
        let installer = NativeKokoroInstaller(home: root, manifestData: NKEmbeddedManifest.data,
            fetch: { _, _ in effects.withValue { $0.append("fetch") }; return Data() },
            available: { _ in effects.withValue { $0.append("capacity") }; return Int64.max },
            acquireShared: { effects.withValue { $0.append("shared") }; throw NKLeaseFailure.busy },
            acquireExclusive: { effects.withValue { $0.append("exclusive") }; throw NKLeaseFailure.busy },
            preflightFailure: .identity)
        do { _ = try await installer.readiness(); XCTFail("readiness accepted failed identity") }
        catch { XCTAssertEqual(error as? NativeKokoroInstaller.InstallError, .identity) }
        do { _ = try await installer.installBase { _, _ in }; XCTFail("base install accepted failed identity") }
        catch { XCTAssertEqual(error as? NativeKokoroInstaller.InstallError, .identity) }
        XCTAssertEqual(effects.value, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testParentCancellationAfterFull49FileStagingPreservesActiveThenRetryRepairsCorruptPartial() async throws {
        let owned = try makeValidHome(); defer { try? FileManager.default.removeItem(at: owned.root) }
        let manifest = try NKAssetManifest.decodePinned(NKEmbeddedManifest.data)
        let originalHashes = manifest.files.map(\.sha256)
        let reached = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let commits = NKLockedBox(0)
        var activation = NativeKokoroActivation()
        activation.swap = { staged, active in
            commits.withValue { $0 += 1 }
            return renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, active.path, UInt32(RENAME_SWAP)) == 0
        }
        let fetches = NKLockedBox(0)
        let installer = try fixtureInstaller(home: owned.home, fetchCount: fetches, activation: activation)
        let task = Task {
            try await installer.installBase { completed, total in
                if completed == total { reached.signal(); resume.wait() }
            }
        }
        await Task.detached { reached.wait() }.value
        task.cancel(); resume.signal()
        do { _ = try await task.value; XCTFail("cancelled parent committed") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(commits.value, 0)
        let preservedBase = try await installer.isBaseInstalled()
        XCTAssertTrue(preservedBase)
        let stage = owned.root.appendingPathComponent(".NativeKokoro-stage-\(NKAssetManifest.revision)")
        let corrupt = try NKAssetLayout(home: stage).fileURL(manifest.files[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
        try Data("corrupt".utf8).write(to: corrupt)
        let outcome = try await installer.installBase { _, _ in }
        XCTAssertTrue(outcome.activated)
        XCTAssertEqual(fetches.value, 0, "verified partials and corrupt entry must be repaired from the leased valid active tree")
        let repairedBase = try await installer.isBaseInstalled()
        XCTAssertTrue(repairedBase)
        XCTAssertEqual(try NKAssetManifest.decodePinned(NKEmbeddedManifest.data).files.map(\.sha256), originalHashes)
        XCTAssertNoThrow(try NKAssetLease(home: owned.home, mode: .shared))
    }

    func testInstallerRetainsActualSharedVerificationAndExclusiveCommitLeasesAndReleasesThem() async throws {
        let owned = try makeValidHome(); defer { try? FileManager.default.removeItem(at: owned.root) }
        let sharedBusy = NKLockedBox(false), exclusiveBusy = NKLockedBox(false)
        let installer = try fixtureInstaller(home: owned.home,
            sharedProbe: {
                do { _ = try NKAssetLease(home: owned.home, mode: .exclusive) }
                catch NKLeaseFailure.busy { sharedBusy.withValue { $0 = true } }
                catch { }
            },
            exclusiveProbe: {
                do { _ = try NKAssetLease(home: owned.home, mode: .shared) }
                catch NKLeaseFailure.busy { exclusiveBusy.withValue { $0 = true } }
                catch { }
            })
        let readiness = try await installer.readiness()
        XCTAssertTrue(readiness.baseInstalled)
        XCTAssertTrue(sharedBusy.value)
        XCTAssertNoThrow(try NKAssetLease(home: owned.home, mode: .exclusive))
        _ = try await installer.installBase { _, _ in }
        XCTAssertTrue(exclusiveBusy.value)
        XCTAssertNoThrow(try NKAssetLease(home: owned.home, mode: .shared))
    }

    @MainActor
    func testRealRuntimeReadinessUsesScopedLeaseOnOwnedPublicFixtureCopy() async throws {
        let owned = try makeValidHome(); defer { try? FileManager.default.removeItem(at: owned.root) }
        let runtime = NativeKokoroRuntimeClient(
            resolveHome: { owned.home },
            osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0) }
        )
        let snapshot = try await runtime.prepare(voiceID: "af_heart")
        XCTAssertEqual(snapshot.voiceID, "af_heart")
        XCTAssertNoThrow(try NKAssetLease(home: owned.home, mode: .exclusive),
                         "successful readiness must release its real shared lease immediately")

        let service = TextToSpeechService(runtime: runtime, player: NKNoopTTSPlayer())
        do { try await service.speak(String(repeating: "ordinary ", count: 40_000)); XCTFail("expected source-work guard") }
        catch { XCTAssertEqual(error as? TextToSpeechService.TTSError, .unsupportedText) }
        XCTAssertNoThrow(try NKAssetLease(home: owned.home, mode: .exclusive),
                         "oversize-input rejection must not acquire a runtime lease")
    }

    @MainActor
    func testCancelledRealRuntimeVerificationReleasesLeaseAfterWorkerFinishes() async throws {
        let owned = try makeValidHome(); defer { try? FileManager.default.removeItem(at: owned.root) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let runtime = NativeKokoroRuntimeClient(
            resolveHome: { owned.home },
            osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0) },
            verificationHook: { entered.signal(); release.wait() }
        )
        let task = Task { try await runtime.prepare(voiceID: "af_heart") }
        await Task.detached { entered.wait() }.value
        XCTAssertThrowsError(try NKAssetLease(home: owned.home, mode: .exclusive)) {
            XCTAssertEqual($0 as? NKLeaseFailure, .busy)
        }
        task.cancel()
        release.signal()
        do { _ = try await task.value; XCTFail("cancelled readiness returned success") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertNoThrow(try NKAssetLease(home: owned.home, mode: .exclusive),
                         "cancelled verification worker retained its real lease")
    }

    @MainActor
    func testRealRuntimeObsoleteOperationCannotRetireHealthyReplacementOrItsLease() async throws {
        let owned = try makeValidHome(); defer { try? FileManager.default.removeItem(at: owned.root) }
        let oldChild = NKRuntimeTestChild(completeSynthesis: false)
        let newChild = NKRuntimeTestChild(completeSynthesis: true)
        var children = [oldChild, newChild]
        var sessionID: UInt64 = 40
        let runtime = NativeKokoroRuntimeClient(
            resolveHome: { owned.home },
            osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0) },
            makeSession: {
                let child = children.removeFirst(); sessionID += 1
                return NativeKokoroSession(session: sessionID, factory: { child })
            }
        )
        let snapshot = try await runtime.prepare(voiceID: "af_heart")
        let old = Task { try await runtime.synthesize(text: "Old public fixture.", snapshot: snapshot) }
        await Task.detached { oldChild.synthesisStarted.wait() }.value
        runtime.stop()
        let replacement = Task { try await runtime.synthesize(text: "Fresh public fixture.", snapshot: snapshot) }
        let replacementWAV = try await replacement.value
        try NKAudio.validate(replacementWAV)
        do { _ = try await old.value; XCTFail("obsolete generation returned audio") }
        catch { XCTAssertTrue(error is CancellationError || error is NativeKokoroReadError, "\(error)") }
        XCTAssertThrowsError(try NKAssetLease(home: owned.home, mode: .exclusive)) {
            XCTAssertEqual($0 as? NKLeaseFailure, .busy)
        }
        runtime.stop()
        XCTAssertNoThrow(try NKAssetLease(home: owned.home, mode: .exclusive),
                         "replacement lease was not independently releasable")
    }

    @MainActor
    func testFullSessionHoldsOldPlaybackCreditBeforeRollover() async throws {
        let owned = try makeValidHome(); defer { try? FileManager.default.removeItem(at: owned.root) }
        var children: [NKRuntimeTestChild] = []
        var sessions: [NativeKokoroSession] = []
        let runtime = NativeKokoroRuntimeClient(resolveHome: { owned.home },
            osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0) },
            makeSession: {
                if let old = children.last { XCTAssertTrue(old.exited()) }
                let child = NKRuntimeTestChild(completeSynthesis: true)
                let session = NativeKokoroSession(factory: { child })
                children.append(child); sessions.append(session)
                return session
            })
        let player = K3QualificationPlayback()
        let service = TextToSpeechService(runtime: runtime, player: player)
        defer { service.stop(); runtime.stop() }
        let source = String(repeating: String(repeating: "bounded ", count: 48) + "sentence. ", count: 33)
        let count = try ProgressiveTextChunker().chunks(in: source).count
        XCTAssertGreaterThan(count, 63)
        XCTAssertLessThanOrEqual(count, 126)
        var result: Result<Void, Error>?
        let read = Task { @MainActor in
            do { try await service.speak(source); result = .success(()) }
            catch { result = .failure(error) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        func wait(_ condition: () -> Bool) async throws {
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw NKError.launch }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        for index in 0..<62 {
            try await wait { player.waves.count > index || result != nil }
            guard result == nil, player.waves.count > index else { throw NKError.identity }
            player.finish(player.waves[index].0)
        }
        try await wait { player.waves.count == 63 && sessions[0].requestAdmission() == .waitForDrain }
        XCTAssertEqual(children.count, 1, "a held old buffer forbids replacement launch")
        XCTAssertFalse(children[0].exited())
        XCTAssertThrowsError(try NKAssetLease(home: owned.home, mode: .exclusive))
        player.finish(player.waves[62].0)
        for index in 63..<count {
            try await wait { player.waves.count > index || result != nil }
            guard result == nil, player.waves.count > index else { throw NKError.identity }
            player.finish(player.waves[index].0)
        }
        try await wait { result != nil }
        await read.value
        guard case .success = result else { throw NKError.identity }
        XCTAssertEqual(children.count, 2)
        XCTAssertTrue(children[0].exited())
        runtime.stop()
        XCTAssertNoThrow(try NKAssetLease(home: owned.home, mode: .exclusive))
    }

    @MainActor
    func testRealRuntimeRollsBeforeCapacityAcrossMoreThan63ChunksAndWarmRead() async throws {
        let owned = try makeValidHome(); defer { try? FileManager.default.removeItem(at: owned.root) }
        var children: [NKRuntimeTestChild] = []
        let runtime = NativeKokoroRuntimeClient(
            resolveHome: { owned.home },
            osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0) },
            makeSession: {
                if let previous = children.last {
                    XCTAssertTrue(previous.exited(), "rollover must reap the old helper before launching another")
                }
                let child = NKRuntimeTestChild(completeSynthesis: true)
                children.append(child)
                return NativeKokoroSession(factory: { child })
            }
        )
        let player = NKImmediateTTSPlayer()
        let service = TextToSpeechService(runtime: runtime, player: player)
        let block = String(repeating: "bounded ", count: 48) + "sentence. "
        let source = String(repeating: block, count: 66)
        let expected = try ProgressiveTextChunker().chunks(in: source)
        XCTAssertGreaterThan(expected.count, 63)

        try await service.speak(source)
        try await service.speak("Subsequent warm read remains healthy.")
        XCTAssertEqual(player.tags.count, expected.count + 1)
        XCTAssertEqual(Set(player.tags).count, expected.count + 1)
        XCTAssertEqual(children.reduce(0) { $0 + $1.synthesisCount }, expected.count + 1)
        XCTAssertGreaterThanOrEqual(children.count, 2, "capacity must create a fresh owned helper session")
        XCTAssertThrowsError(try NKAssetLease(home: owned.home, mode: .exclusive)) {
            XCTAssertEqual($0 as? NKLeaseFailure, .busy)
        }
        runtime.stop()
        XCTAssertNoThrow(try NKAssetLease(home: owned.home, mode: .exclusive))
    }

    @MainActor
    func testOverlongLookaheadRetirementIgnoresOldDrainUntilNewBufferFinishes() async throws {
        let owned = try makeValidHome(); defer { try? FileManager.default.removeItem(at: owned.root) }
        let old = NKRuntimeTestChild(completeSynthesis: true)
        let replacement = NKRuntimeTestChild(completeSynthesis: true)
        var children = [old, replacement]
        var sessions: [NativeKokoroSession] = []
        let runtime = NativeKokoroRuntimeClient(
            resolveHome: { owned.home },
            osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0) },
            makeSession: {
                let session = NativeKokoroSession(factory: { children.removeFirst() })
                sessions.append(session)
                return session
            }
        )
        let snapshot = try await runtime.prepare(voiceID: "af_nicole", speed: 1.25)
        _ = try await runtime.synthesize(text: "Playing buffer.", snapshot: snapshot)
        let oldToken = try XCTUnwrap(runtime.capturePlaybackDrainToken())
        old.failNextSynthesis(.samplesTooLong)
        do { _ = try await runtime.synthesize(text: "Overlong lookahead.", snapshot: snapshot); XCTFail("expected overlong helper failure") }
        catch { XCTAssertEqual(error as? NativeKokoroReadError, .helperFailed(.samplesTooLong)) }

        _ = try await runtime.synthesize(text: "Replacement lookahead.", snapshot: snapshot)
        let newToken = try XCTUnwrap(runtime.capturePlaybackDrainToken())
        XCTAssertNotEqual(oldToken, newToken)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[1].retainedPlaybackBuffers, 1)
        runtime.playbackDrained(token: oldToken)
        XCTAssertEqual(sessions[1].retainedPlaybackBuffers, 1, "an old playback completion must not consume replacement audio credit")
        runtime.playbackDrained(token: newToken)
        XCTAssertEqual(sessions[1].retainedPlaybackBuffers, 0)
        runtime.stop()
    }

    @MainActor
    func testFinalPlaybackDrainReleasesCrashedSessionAndNextReadUsesHealthyEpoch() async throws {
        let owned = try makeValidHome(); defer { try? FileManager.default.removeItem(at: owned.root) }
        let crashed = NKRuntimeTestChild(completeSynthesis: true)
        let healthy = NKRuntimeTestChild(completeSynthesis: true)
        var children = [crashed, healthy]
        var sessions: [NativeKokoroSession] = []
        let runtime = NativeKokoroRuntimeClient(
            resolveHome: { owned.home },
            osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0) },
            makeSession: {
                let child = children.removeFirst()
                let session = NativeKokoroSession(factory: { child })
                sessions.append(session)
                return session
            }
        )
        let snapshot = try await runtime.prepare(voiceID: "af_heart")
        _ = try await runtime.synthesize(text: "Generated before helper crash.", snapshot: snapshot)
        crashed.crash()
        let deadline = Date().addingTimeInterval(2)
        while sessions[0].state != .failed && Date() < deadline { await Task.yield() }
        XCTAssertEqual(sessions[0].state, .failed)
        runtime.playbackDrained()
        XCTAssertNoThrow(try NKAssetLease(home: owned.home, mode: .exclusive),
                         "terminal helper state must not strand its runtime-use lease")

        _ = try await runtime.synthesize(text: "Healthy request after crash.", snapshot: snapshot)
        runtime.playbackDrained()
        XCTAssertEqual(sessions.count, 2)
        runtime.stop()
    }

    @MainActor
    func testSetupManagerBaseCancelPropagatesToDetachedWorkerBeforeAnyActivation() async throws {
        let ownedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("nk-manager-cancel-\(UUID().uuidString)")
        let root = ownedRoot.appendingPathComponent("Home")
        defer { try? FileManager.default.removeItem(at: ownedRoot) }
        let started = DispatchSemaphore(value: 0), workerCancelled = NKLockedBox(false)
        let installer = NativeKokoroInstaller(home: root, manifestData: NKEmbeddedManifest.data,
            fetch: { _, _ in
                started.signal()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { workerCancelled.withValue { $0 = error is CancellationError }; throw error }
                return Data()
            }, available: { _ in Int64.max })
        let manager = TTSSetupManager(installer: installer)
        await manager.prepare()
        manager.install()
        await Task.detached { started.wait() }.value
        manager.cancel()
        while manager.status.isInstalling { await Task.yield() }
        XCTAssertTrue(workerCancelled.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: NKAssetLayout(home: root).modelsRoot.path))
    }

    @MainActor
    func testSetupManagerDefersReadinessUntilExplicitPrepareAndIgnoresCancelledFactoryCallback() async throws {
        let calls = NKLockedBox(0)
        let manager = TTSSetupManager(productionFactory: {
            calls.withValue { $0 += 1 }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw NativeKokoroInstaller.InstallError.identity
        })
        XCTAssertEqual(manager.status, .checking)
        XCTAssertEqual(calls.value, 0)
        let task = Task { await manager.prepare() }
        while calls.value == 0 { await Task.yield() }
        task.cancel(); await task.value
        XCTAssertEqual(manager.status, .notInstalled)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(manager.status, .notInstalled)
    }
}

private final class NKFakeEngineBackend: NKEngineBackend {
    var calls: [String] = []
    var failure: Error?
    var output = NKEngineSamples(samples: [0.2], sampleRate: 24000)
    var resolved = "həloʊ"
    func initialize(modelsRoot: URL) async throws { calls.append("initialize"); if let failure { throw failure } }
    func phonemes(text: String) async throws -> String { calls.append("phonemes"); if let failure { throw failure }; return resolved }
    func synthesize(phonemes: String, voiceID: String, speed: Float) async throws -> NKEngineSamples { calls.append("synthesize:\(voiceID):\(speed)"); return output }
    func wav(samples: [Float]) throws -> Data {
        calls.append("wav")
        var data = Data("RIFF".utf8)
        func le(_ n: UInt32, _ size: Int) { for shift in 0..<size { data.append(UInt8(truncatingIfNeeded: n >> (8 * shift))) } }
        le(38,4); data.append(Data("WAVEfmt ".utf8)); le(16,4); le(1,2); le(1,2)
        le(24000,4); le(48000,4); le(2,2); le(16,2); data.append(Data("data".utf8)); le(2,4); le(1,2)
        return data
    }
}
final class NativeKokoroEngineTests: XCTestCase {
    private func engine(_ fake: NKFakeEngineBackend, minor: Int = 6,
                        verify: @escaping () throws -> Void = {},
                        verifyVoice: @escaping (String) throws -> Void = { _ in }) -> NKVerifiedEngine {
        NKVerifiedEngine(backend: fake, layout: NKAssetLayout(home: URL(fileURLWithPath: "/private/tmp/fake")),
                         os: OperatingSystemVersion(majorVersion: 26, minorVersion: minor, patchVersion: 0),
                         policy: { fake.calls.append("policy") }, verify: verify, verifyVoice: verifyVoice)
    }
    func testUnsupportedOSAndReadinessNeverEnterBackend() async {
        for minor in [4,5] {
            let fake = NKFakeEngineBackend(); let e = engine(fake, minor: minor)
            do { try await e.initialize(); XCTFail() } catch { XCTAssertEqual(error as? NKRuntimeFailure, .unsupportedOS) }
            XCTAssertTrue(fake.calls.isEmpty)
        }
        let fake = NKFakeEngineBackend(); let e = engine(fake)
        do { _ = try await e.synthesize(text: "Hello."); XCTFail() } catch { XCTAssertEqual(error as? NKRuntimeFailure, .notReady) }
        XCTAssertTrue(fake.calls.isEmpty)
    }
    func testAssetFailuresPreventSDKEntry() async {
        for failure in [NKRuntimeFailure.missing, .size, .digest, .layout, .migration, .manifest] {
            let fake = NKFakeEngineBackend(); let e = engine(fake, verify: { throw failure })
            do { try await e.initialize(); XCTFail() } catch { XCTAssertEqual(error as? NKRuntimeFailure, failure) }
            XCTAssertTrue(fake.calls.isEmpty)
        }
    }
    func testPolicyPrecedesEverySDKOperationAndValidAudio() async throws {
        let fake = NKFakeEngineBackend(); let e = engine(fake)
        try await e.initialize(); let data = try await e.synthesize(text: "Hello.")
        try NKAudio.validate(data)
        XCTAssertEqual(fake.calls, ["policy", "initialize", "policy", "phonemes", "synthesize:af_heart:1.0", "wav"])
    }
    func testEveryAllowedSpeedReachesBackendWithoutResampling() async throws {
        for speed: Float in [0.75, 1, 1.25, 1.75] {
            let fake = NKFakeEngineBackend(); let e = engine(fake)
            try await e.initialize()
            _ = try await e.synthesize(text: "Hello.", speed: speed)
            XCTAssertTrue(fake.calls.contains("synthesize:af_heart:\(speed)"))
        }
    }
    func testSelectedVoiceIsVerifiedAndLockedForBackendCall() async throws {
        let fake = NKFakeEngineBackend(); var verified: [String] = []
        let e = engine(fake, verifyVoice: { verified.append($0) })
        try await e.initialize()
        _ = try await e.synthesize(text: "Hello.", voiceID: "af_nicole")
        XCTAssertEqual(verified, ["af_nicole"])
        XCTAssertTrue(fake.calls.contains("synthesize:af_nicole:1.0"))
        do { _ = try await e.synthesize(text: "Hello.", voiceID: "not-installed") ; XCTFail() }
        catch { XCTAssertEqual(error as? NKRuntimeFailure, .input) }
        XCTAssertEqual(verified, ["af_nicole"])
    }
    func testPrivateSDKErrorMapsToFixedCode() async {
        let fake = NKFakeEngineBackend(); fake.failure = NSError(domain: "PRIVATE synthetic content", code: 42, userInfo: [NSLocalizedDescriptionKey: "PRIVATE"])
        do { try await engine(fake).initialize(); XCTFail() } catch { XCTAssertEqual(error as? NKRuntimeFailure, .synthesis) }
    }
    func testBoundedInputAndPhonemesDoNotReachSynthesis() async throws {
        let fake = NKFakeEngineBackend(); let e = engine(fake); try await e.initialize()
        for text in ["", String(repeating: "a", count: 63), String(repeating: "a ", count: 65), String(repeating: "abc ", count: 300)] {
            do { _ = try await e.synthesize(text: text); XCTFail() } catch { XCTAssertEqual(error as? NKRuntimeFailure, .input) }
        }
        fake.resolved = String(repeating: "a", count: 511)
        do { _ = try await e.synthesize(text: "Hello."); XCTFail() } catch { XCTAssertEqual(error as? NKRuntimeFailure, .input) }
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("synthesize:") })
    }
    func testInvalidSamplesNeverReachPCMConversionAndOverlongAudioIsDistinguished() async throws {
        for output in [NKEngineSamples(samples: [], sampleRate: 24000), NKEngineSamples(samples: [.nan], sampleRate: 24000),
                       NKEngineSamples(samples: [.infinity], sampleRate: 24000), NKEngineSamples(samples: [0], sampleRate: 24000),
                       NKEngineSamples(samples: [1], sampleRate: 16000)] {
            let fake = NKFakeEngineBackend(); fake.output = output; let e = engine(fake); try await e.initialize()
            do { _ = try await e.synthesize(text: "Hello."); XCTFail() } catch { XCTAssertEqual(error as? NKRuntimeFailure, .samples) }
            XCTAssertFalse(fake.calls.contains("wav"))
        }
        let fake = NKFakeEngineBackend()
        fake.output = NKEngineSamples(samples: Array(repeating: 1, count: 480_001), sampleRate: 24_000)
        let e = engine(fake); try await e.initialize()
        do { _ = try await e.synthesize(text: "Hello."); XCTFail() } catch { XCTAssertEqual(error as? NKRuntimeFailure, .samplesTooLong) }
        XCTAssertFalse(fake.calls.contains("wav"))
    }
    func testSelectedAssetFailureAfterInitializationPreventsFurtherSDKEntry() async throws {
        let fake = NKFakeEngineBackend(); var valid = true
        let e = engine(fake, verify: { if !valid { throw NKRuntimeFailure.digest } }); try await e.initialize(); valid = false
        do { _ = try await e.synthesize(text: "Hello."); XCTFail() } catch { XCTAssertEqual(error as? NKRuntimeFailure, .digest) }
        XCTAssertEqual(fake.calls, ["policy", "initialize"])
    }
}
final class NativeKokoroSetupTests: XCTestCase {
    func testSharedRuntimeLeaseBlocksExclusiveActivationAndUnsafeLockSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nk-lease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var shared: NKAssetLease? = try NKAssetLease(home: root, mode: .shared)
        XCTAssertThrowsError(try NKAssetLease(home: root, mode: .exclusive)) {
            XCTAssertEqual($0 as? NKLeaseFailure, .busy)
        }
        shared = nil
        _ = try NKAssetLease(home: root, mode: .exclusive)
        XCTAssertNil(shared)

        let unsafe = FileManager.default.temporaryDirectory.appendingPathComponent("nk-lease-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unsafe.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unsafe) }
        try FileManager.default.createSymbolicLink(at: unsafe.appendingPathComponent(".cache/fluidaudio"), withDestinationURL: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try NKAssetLease(home: unsafe, mode: .shared)) {
            XCTAssertEqual($0 as? NKLeaseFailure, .unsafePath)
        }
    }
    func testAtomicActivationPreservesOldTreeAndReportsPostCommitRetentionTruthfully() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nk-activate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("active"), staged = root.appendingPathComponent("staged")
        let retained = root.appendingPathComponent("retained")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: active.appendingPathComponent("version"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("version"))
        let result = try NativeKokoroActivation().commit(staged: staged, active: active, retained: retained)
        XCTAssertEqual(result, .init(activated: true, retainedPrevious: true, retentionWarning: false))
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("version")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("version")), Data("old".utf8))

        let next = root.appendingPathComponent("next")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try Data("newer".utf8).write(to: next.appendingPathComponent("version"))
        var activation = NativeKokoroActivation()
        activation.move = { _, _ in throw CocoaError(.fileWriteUnknown) }
        let warning = try activation.commit(staged: next, active: active, retained: root.appendingPathComponent("never"))
        XCTAssertTrue(warning.activated); XCTAssertTrue(warning.retentionWarning)
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("version")), Data("newer".utf8))
        XCTAssertEqual(try Data(contentsOf: next.appendingPathComponent("version")), Data("new".utf8))
    }
    func testDescriptorFailuresAndFlagsPreservation() throws {
        for failAt in 0..<3 {
            var count = 0
            XCTAssertThrowsError(try NKDescriptorSetup.nonblocking(123, noSIGPIPE: true, call: { _, _, _ in
                defer { count += 1 }; return count == failAt ? -1 : (count == 0 ? O_APPEND : 0)
            }))
            XCTAssertEqual(count, failAt + 1)
        }
        var operations: [(Int32, Int32)] = []
        try NKDescriptorSetup.nonblocking(123, noSIGPIPE: true, call: { _, operation, value in
            operations.append((operation, value)); return operation == F_GETFL ? O_APPEND : 0
        })
        XCTAssertEqual(operations.map { $0.0 }, [F_GETFL, F_SETFL, F_SETNOSIGPIPE])
        XCTAssertEqual(operations[1].1, O_APPEND | O_NONBLOCK)
    }
    func testCheckedSpawnSetupFailuresOccurBeforeLaunch() {
        for stage in NativeKokoroChild.SetupStage.allCases {
            XCTAssertThrowsError(try NativeKokoroChild(executable: URL(fileURLWithPath: "/not-a-helper"), setupStatus: { current, status in current == stage ? EINVAL : status })) {
                XCTAssertEqual($0 as? NKError, .launch)
            }
        }
    }
    func testSpawnFailureLeavesNoOwnedChild() {
        XCTAssertThrowsError(try NativeKokoroChild(executable: URL(fileURLWithPath: "/not-a-helper"))) {
            XCTAssertEqual($0 as? NKError, .launch)
        }
    }
}

private final class K3QualificationChildren: @unchecked Sendable {
    private let lock = NSLock()
    private var children: [NativeKokoroChild] = []
    func launch(_ executable: URL) throws -> NKChild {
        let child = try NativeKokoroChild(executable: executable)
        lock.lock(); children.append(child); lock.unlock()
        return child
    }
    var snapshot: [NativeKokoroChild] {
        lock.lock(); defer { lock.unlock() }; return children
    }
    func cleanup() {
        for child in snapshot { child.closeControl(); child.signal(force: true); child.closeResults() }
    }
}

@MainActor
private final class K3QualificationPlayback: NativeTTSPlayback {
    var eventHandler: ((NativeTTSPlaybackEvent) -> Void)?
    private(set) var waves: [(UUID, Data)] = []
    private(set) var stops = 0
    func play(wav: Data, tag: UUID) throws {
        try NKAudio.validate(wav)
        waves.append((tag, wav))
        eventHandler?(.started(tag))
    }
    func stop() { stops += 1 }
    func finish(_ tag: UUID) { eventHandler?(.finished(tag)) }
}

/// Explicitly gated, public-only SDK qualification. Never part of ordinary unit
/// execution; its launcher verifies the signed export/copy and actual host inputs.
@MainActor
final class NativeKokoroServiceQualificationTests: XCTestCase {
    private static func ownedTemporaryRoot(_ path: String) throws -> URL {
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix("dikta-k3-service-qualification-") else { throw NKError.identity }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              attributes[.type] as? FileAttributeType == .typeDirectory else { throw NKError.identity }
        return root
    }

    func testOwnedTemporaryRootNormalizesAliasesAndRejectsForeignParents() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("dikta-k3-service-qualification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) } // This test's newly owned empty directory only.
        let alternate = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(root.lastPathComponent, isDirectory: true)
        XCTAssertEqual(try Self.ownedTemporaryRoot(root.path).path,
                       try Self.ownedTemporaryRoot(alternate.path).path)
        XCTAssertThrowsError(try Self.ownedTemporaryRoot(root.appendingPathComponent("nested").path))
        XCTAssertThrowsError(try Self.ownedTemporaryRoot("/tmp/not-qualified-\(UUID().uuidString)"))
    }

    func testSignedPackagedNativeShortServiceWithFakePlayback() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DIKTA_K3_SERVICE_QUALIFICATION"] == "1" else {
            throw XCTSkip("K3 packaged service qualification requires separate approval")
        }
        XCTAssertEqual(ConfigService.shared.storageURLForTesting.path,
                       "/tmp/dikta-parakeet-ultra-isolated-config/config.json")
        XCTAssertEqual(env["DIKTA_REAL_SESSIONS_DIR"], "/tmp/dikta-parakeet-ultra-isolated-empty-sessions")
        guard ConfigService.shared.storageURLForTesting.path == "/tmp/dikta-parakeet-ultra-isolated-config/config.json",
              env["DIKTA_REAL_SESSIONS_DIR"] == "/tmp/dikta-parakeet-ultra-isolated-empty-sessions" else {
            throw NKError.identity
        }
        let root = try Self.ownedTemporaryRoot(try XCTUnwrap(env["DIKTA_K3_QUAL_OUTPUT"]))
        let executable = URL(fileURLWithPath: try XCTUnwrap(env["DIKTA_K3_QUAL_HELPER"])).resolvingSymlinksInPath()
        guard executable.path.hasPrefix(root.path + "/") else { throw NKError.identity }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.duatalk.k2-corrective.NativeKokoroHelper/Data")
        guard env["DIKTA_K3_QUAL_HOME"] == home.path else { throw NKError.identity }
        let requirementText = "anchor apple generic and identifier \"com.duatalk.k2-corrective.NativeKokoroHelper\" and certificate leaf[subject.OU] = \"UUM29335B4\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw NKError.identity
        }
        print("K3_EFFECTIVE_XCTEST_HOST_ISOLATED")
        let registry = K3QualificationChildren()
        let runtime = NativeKokoroRuntimeClient(executable: { executable }, resolveHome: { home },
            makeSession: { NativeKokoroSession(factory: { try registry.launch(executable) }) })
        let playback = K3QualificationPlayback()
        let service = TextToSpeechService(runtime: runtime, player: playback)
        defer { service.stop(); runtime.stop(); registry.cleanup() }
        let request = TextToSpeechRequest(voice: .af_heart)
        guard await service.checkAvailable(for: request) else { throw NKError.identity }
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        func wait(_ condition: () -> Bool) async throws {
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw NKError.launch }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        var firstResult: Result<Void, Error>?
        let first = Task { @MainActor in
            do { try await service.speak("Public synthetic native Read Aloud service check.", request: request); firstResult = .success(()) }
            catch { firstResult = .failure(error) }
        }
        try await wait { !playback.waves.isEmpty || firstResult != nil }
        guard playback.waves.count == 1 else { throw NKError.audio }
        XCTAssertTrue(service.speaking)
        XCTAssertNil(firstResult, "generation cannot finish a request before playback drains")
        let stoppedTag = playback.waves[0].0
        service.stop()
        playback.finish(stoppedTag)
        await first.value
        guard case .failure(let stoppedError) = firstResult, stoppedError is CancellationError else { throw NKError.identity }
        XCTAssertFalse(service.speaking)
        try await wait { registry.snapshot.allSatisfy { $0.exited() } }
        var secondResult: Result<Void, Error>?
        let second = Task { @MainActor in
            do { try await service.speak("Public synthetic native Read Aloud service check.", request: request); secondResult = .success(()) }
            catch { secondResult = .failure(error) }
        }
        try await wait { playback.waves.count == 2 || secondResult != nil }
        guard playback.waves.count == 2 else { throw NKError.audio }
        playback.finish(stoppedTag) // An old completion cannot finish this replacement.
        XCTAssertTrue(service.speaking)
        XCTAssertNil(secondResult)
        playback.finish(playback.waves[1].0)
        await second.value
        guard case .success = secondResult else { throw NKError.identity }
        XCTAssertFalse(service.speaking)
        runtime.stop()
        try await wait { registry.snapshot.allSatisfy { $0.exited() } }
        XCTAssertEqual(registry.snapshot.count, 2)
        let lease = try NKAssetLease(home: home, mode: .exclusive)
        withExtendedLifetime(lease) {}
        var receipts: [[String: Any]] = []
        for (index, wave) in playback.waves.enumerated() {
            try NKAudio.validate(wave.1)
            guard wave.1.count <= 960_044, wave.1.dropFirst(44).contains(where: { $0 != 0 }) else { throw NKError.audio }
            let name = "service-read-\(index + 1).wav"
            try wave.1.write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
            receipts.append(["name": name, "bytes": wave.1.count,
                "seconds": Double(wave.1.count - 44) / 48000,
                "sha256": SHA256.hash(data: wave.1).map { String(format: "%02x", $0) }.joined()])
        }
        let receipt: [String: Any] = ["executed_non_skipped": true, "voice": "af_heart",
            "reads": receipts, "generation_waited_for_drain": true, "stop_was_cancellation": true,
            "stale_completion_rejected": true, "healthy_replacement_completed": true,
            "owned_children": registry.snapshot.count, "all_reaped": true, "exclusive_lease_after_cleanup": true]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("service-receipt.json"), options: .withoutOverwriting)
        print("K3_SERVICE_QUALIFICATION_PASS_TWO_READS_REAPED")
    }
}

/// Metadata-only observer around the real production runtime. It never substitutes
/// generation: each of the five fixed public SDK results is saved immediately.
@MainActor
private final class K4QualificationRuntime: NativeKokoroRuntimeServing {
    let base: NativeKokoroRuntimeClient
    let root: URL
    private(set) var sources: [String] = []
    private(set) var receipts: [[String: Any]] = []
    init(base: NativeKokoroRuntimeClient, root: URL) { self.base = base; self.root = root }
    func prepare(voiceID: String, speed: Float) async throws -> NativeKokoroAssetSnapshot { try await base.prepare(voiceID: voiceID, speed: speed) }
    func synthesize(text: String, snapshot: NativeKokoroAssetSnapshot) async throws -> Data {
        guard sources.count < 5 else { throw NKError.identity }
        let ordinal = sources.count + 1
        sources.append(text)
        let wav = try await base.synthesize(text: text, snapshot: snapshot)
        try NKAudio.validate(wav)
        guard wav.count <= 960_044, wav.dropFirst(44).contains(where: { $0 != 0 }) else { throw NKError.audio }
        let name = "synthesis-\(ordinal).wav"
        try wav.write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
        receipts.append(["ordinal": ordinal, "name": name, "bytes": wav.count,
            "seconds": Double(wav.count - 44) / 48000,
            "sha256": SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined(),
            "source_sha256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()])
        return wav
    }
    func playbackDrained() { base.playbackDrained() }
    func stop() { base.stop() }
}

@MainActor
final class NativeKokoroProgressiveQualificationTests: XCTestCase {
    static let publicText = [
        "First public passage describes a quiet garden where bright flowers grow beside a stone path under gentle morning sunlight.",
        "Next public passage describes a quiet river where small birds rest beside a wooden bridge under clear evening skies.",
        "Second public passage describes a peaceful meadow where gentle breezes move beside a narrow trail under warm afternoon sunshine.",
        "Next public passage describes a quiet river where small birds rest beside a wooden bridge under clear evening skies.",
        "Third public passage describes a calm forest where green leaves shine beside a shallow stream under soft daylight today.",
        "Final public passage describes a quiet garden where bright flowers grow beside a stone path under gentle morning sunlight."
    ].joined(separator: " ")

    func testPublicFixtureHasExactlyThreePreservedChunks() throws {
        let chunks = try ProgressiveTextChunker().chunks(in: Self.publicText)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertGreaterThan(Self.publicText.utf8.count, 600)
        XCTAssertEqual(chunks.map { String(Self.publicText[$0.range]) }.joined(), Self.publicText)
    }

    func testSignedPackagedProgressiveServiceStopAndHealthyThreeChunks() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DIKTA_K4_SERVICE_QUALIFICATION"] == "1" else {
            throw XCTSkip("K4 progressive SDK qualification requires separate approval")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        guard ConfigService.shared.storageURLForTesting.path == "/tmp/dikta-parakeet-ultra-isolated-config/config.json",
              env["DIKTA_REAL_SESSIONS_DIR"] == "/tmp/dikta-parakeet-ultra-isolated-empty-sessions",
              env["DIKTA_K2_QUALIFICATION"] == "0", env["DIKTA_K3_SERVICE_QUALIFICATION"] == "0" else { throw NKError.identity }
        let root = URL(fileURLWithPath: try XCTUnwrap(env["DIKTA_K4_QUAL_OUTPUT"])).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix("dikta-k4-service-qualification-"),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              attributes[.type] as? FileAttributeType == .typeDirectory else { throw NKError.identity }
        let executable = URL(fileURLWithPath: try XCTUnwrap(env["DIKTA_K4_QUAL_HELPER"])).resolvingSymlinksInPath()
        guard executable.path.hasPrefix(root.path + "/") else { throw NKError.identity }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.duatalk.k2-corrective.NativeKokoroHelper/Data")
        guard env["DIKTA_K4_QUAL_HOME"] == home.path else { throw NKError.identity }
        let requirementText = "anchor apple generic and identifier \"com.duatalk.k2-corrective.NativeKokoroHelper\" and certificate leaf[subject.OU] = \"UUM29335B4\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else { throw NKError.identity }
        let chunks = try ProgressiveTextChunker().chunks(in: Self.publicText)
        guard chunks.count == 3, Self.publicText.utf8.count > 600 else { throw NKError.identity }
        let expected = chunks.map { String(Self.publicText[$0.range]) }
        guard expected.joined() == Self.publicText else { throw NKError.identity }
        print("K4_EFFECTIVE_XCTEST_HOST_ISOLATED")
        let registry = K3QualificationChildren()
        let base = NativeKokoroRuntimeClient(executable: { executable }, resolveHome: { home },
            makeSession: { NativeKokoroSession(factory: { try registry.launch(executable) }) })
        let runtime = K4QualificationRuntime(base: base, root: root)
        let playback = K3QualificationPlayback()
        let service = TextToSpeechService(runtime: runtime, player: playback)
        defer { service.stop(); runtime.stop(); registry.cleanup() }
        func wait(_ condition: () -> Bool) async throws {
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw NKError.launch }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let request = TextToSpeechRequest(voice: .af_heart)
        var firstResult: Result<Void, Error>?
        let first = Task { @MainActor in
            do { try await service.speak(Self.publicText, request: request); firstResult = .success(()) }
            catch { firstResult = .failure(error) }
        }
        try await wait { runtime.receipts.count == 2 || firstResult != nil }
        guard firstResult == nil, runtime.sources.count == 2, runtime.receipts.count == 2,
              playback.waves.count == 1, service.speaking else { throw NKError.identity }
        let staleTag = playback.waves[0].0
        service.stop(); playback.finish(staleTag)
        try await wait { firstResult != nil }
        await first.value
        guard case .failure(let error) = firstResult, error is CancellationError else { throw NKError.identity }
        try await wait { registry.snapshot.allSatisfy { $0.exited() } }
        var secondResult: Result<Void, Error>?
        let second = Task { @MainActor in
            do { try await service.speak(Self.publicText, request: request); secondResult = .success(()) }
            catch { secondResult = .failure(error) }
        }
        for index in 0..<3 {
            try await wait { playback.waves.count == index + 2 || secondResult != nil }
            guard secondResult == nil, playback.waves.count == index + 2 else { throw NKError.audio }
            if index == 0 {
                try await wait { runtime.receipts.count == 4 || secondResult != nil }
                guard secondResult == nil, runtime.sources.count == 4, playback.waves.count == 2 else { throw NKError.identity }
            }
            playback.finish(staleTag)
            guard secondResult == nil, service.speaking else { throw NKError.identity }
            playback.finish(playback.waves[index + 1].0)
        }
        try await wait { secondResult != nil }
        await second.value
        guard case .success = secondResult, runtime.sources == Array(expected.prefix(2)) + expected,
              runtime.receipts.count == 5, playback.waves.count == 4, !service.speaking else { throw NKError.identity }
        runtime.stop()
        try await wait { registry.snapshot.allSatisfy { $0.exited() } }
        guard registry.snapshot.count == 2 else { throw NKError.identity }
        let lease = try NKAssetLease(home: home, mode: .exclusive)
        withExtendedLifetime(lease) {}
        let receipt: [String: Any] = ["executed_non_skipped": true, "voice": "af_heart", "chunks": 3,
            "sdk_calls": 5, "reads": runtime.receipts, "source_order_preserved": true,
            "generation_waited_for_final_drain": true, "one_playing_one_lookahead": true,
            "stop_was_cancellation": true, "stale_completion_rejected": true,
            "healthy_replacement_completed": true, "owned_children": 2, "all_reaped": true,
            "exclusive_lease_after_cleanup": true,
            "public_source_sha256": SHA256.hash(data: Data(Self.publicText.utf8)).map { String(format: "%02x", $0) }.joined()]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("service-receipt.json"), options: .withoutOverwriting)
        print("K4_SERVICE_QUALIFICATION_PASS_FIVE_SYNTHESIS_TWO_CHILDREN_REAPED")
    }
}

/// Saved public SDK audio only: no helper, model preparation or inference.
@MainActor
private final class K4SavedWaveRuntime: NativeKokoroRuntimeServing {
    static let hashes = [
        "721705efea9d0f097bcfa354c07af7f380f3d0acca1d6e543101669ce56243b8",
        "0dc38620071cf7da32d96cd5b3c008e13643280410940e04840d88c886493668",
        "6ea51b692b61065fbbb406aed53c25e3d232ec9848312cb547be28f8d8aa0574"
    ]
    let sources: [String]
    private(set) var generated = 0
    private(set) var drained = 0
    init() throws {
        let text = NativeKokoroProgressiveQualificationTests.publicText
        sources = try ProgressiveTextChunker().chunks(in: text).map { String(text[$0.range]) }
        guard sources.count == 3 else { throw NKError.identity }
    }
    func prepare(voiceID: String, speed: Float) async throws -> NativeKokoroAssetSnapshot {
        guard voiceID == "af_heart" else { throw NKError.identity }
        return NativeKokoroAssetSnapshot(revision: "saved-public-qualification", voiceID: voiceID,
            voiceDigest: "e236b2bbd688e7945804e98977e99144ffe7c74292025e4e2c29e09736885612", speed: speed)
    }
    func synthesize(text: String, snapshot: NativeKokoroAssetSnapshot) async throws -> Data {
        guard generated < 3, text == sources[generated], snapshot.voiceID == "af_heart" else { throw NKError.identity }
        let data = try Data(contentsOf: URL(fileURLWithPath:
            "/tmp/dikta-k4-service-qualification-orv9970c/synthesis-\(generated + 3).wav"))
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.hashes[generated] else {
            throw NKError.audio
        }
        try NKAudio.validate(data)
        generated += 1
        return data
    }
    func playbackDrained() { drained += 1 }
    func stop() {}
}

@MainActor
private final class K4ObservedNativePlayer: NativeTTSPlayback {
    let base = AVNativeTTSPlayer()
    var eventHandler: ((NativeTTSPlaybackEvent) -> Void)?
    private(set) var tags: [UUID] = []
    private(set) var naturalFinishes = 0
    init() {
        base.eventHandler = { [weak self] event in
            if case .finished = event { self?.naturalFinishes += 1 }
            self?.eventHandler?(event)
        }
    }
    func play(wav: Data, tag: UUID) throws { tags.append(tag); try base.play(wav: wav, tag: tag) }
    func stop() { base.stop() }
}

@MainActor
final class NativeKokoroLongHumanPlaybackTests: XCTestCase {
    func testSavedQualifiedLongReadWithFakePlayback() async throws {
        guard ProcessInfo.processInfo.environment["DIKTA_K4_HUMAN_FIXTURE_CHECK"] == "1" else {
            throw XCTSkip("Saved public qualification inputs are an explicit local-only check")
        }
        let runtime = try K4SavedWaveRuntime()
        let player = K3QualificationPlayback()
        let service = TextToSpeechService(runtime: runtime, player: player)
        defer { service.stop() }
        var result: Result<Void, Error>?
        let read = Task { @MainActor in
            do { try await service.speak(NativeKokoroProgressiveQualificationTests.publicText,
                                        request: TextToSpeechRequest(voice: .af_heart)); result = .success(()) }
            catch { result = .failure(error) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        for index in 0..<3 {
            while player.waves.count <= index, result == nil, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard result == nil, player.waves.count == index + 1 else { throw NKError.identity }
            player.finish(player.waves[index].0)
        }
        while result == nil, ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
        guard case .success = result else { throw NKError.identity }
        await read.value
        XCTAssertEqual(runtime.generated, 3); XCTAssertEqual(runtime.drained, 3)
    }

    private func currentOutput() throws -> (AudioObjectID, String, String) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == kAudioHardwareNoError else { throw NKError.identity }
        address.mSelector = kAudioObjectPropertyName
        var name: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == kAudioHardwareNoError,
              let name else { throw NKError.identity }
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "set s to get volume settings\nreturn (output volume of s as string) & \",\" & (output muted of s as string)"]
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0,
              let volume = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { throw NKError.identity }
        return (device, name as String, volume.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testQualifiedPublicLongReadThroughActualProductionPlayer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DIKTA_K4_HUMAN_PLAYBACK"] == "1" else {
            throw XCTSkip("SOUND requires separately announced human readiness")
        }
        guard env["DIKTA_K2_QUALIFICATION"] == "0", env["DIKTA_K3_SERVICE_QUALIFICATION"] == "0",
              env["DIKTA_K4_SERVICE_QUALIFICATION"] == "0",
              ConfigService.shared.storageURLForTesting.path == "/tmp/dikta-parakeet-ultra-isolated-config/config.json",
              env["DIKTA_REAL_SESSIONS_DIR"] == "/tmp/dikta-parakeet-ultra-isolated-empty-sessions" else { throw NKError.identity }
        let root = URL(fileURLWithPath: try XCTUnwrap(env["DIKTA_K4_HUMAN_OUTPUT"])).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix("dikta-k4-human-player-"),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              attributes[.type] as? FileAttributeType == .typeDirectory else { throw NKError.identity }
        let output = try currentOutput()
        let level = output.2.split(separator: ",")
        guard output.1 == "Sebastian’s AirPods Pro", env["DIKTA_K4_EXPECTED_OUTPUT_ID"] == String(output.0),
              level.count == 2, level[1] == "false", let volume = Int(level[0]), (1...55).contains(volume) else { throw NKError.identity }
        let runtime = try K4SavedWaveRuntime()
        let player = K4ObservedNativePlayer()
        let service = TextToSpeechService(runtime: runtime, player: player)
        defer { service.stop(); player.stop() }
        let start = ProcessInfo.processInfo.systemUptime
        var result: Result<Void, Error>?
        let read = Task { @MainActor in
            do { try await service.speak(NativeKokoroProgressiveQualificationTests.publicText,
                                        request: TextToSpeechRequest(voice: .af_heart)); result = .success(()) }
            catch { result = .failure(error) }
        }
        while result == nil, ProcessInfo.processInfo.systemUptime - start < 65 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if result == nil { service.stop(); read.cancel(); throw NKError.launch }
        await read.value
        guard case .success = result, runtime.generated == 3, runtime.drained == 3,
              player.naturalFinishes == 3, Set(player.tags).count == 3, !service.speaking else { throw NKError.identity }
        let receipt: [String: Any] = ["public_source_sha256": "e236b2bbd688e7945804e98977e99144ffe7c74292025e4e2c29e09736885612",
            "wave_hashes": K4SavedWaveRuntime.hashes, "route": output.1, "volume_mute": output.2,
            "chunks": 3, "natural_finishes": 3, "drains": 3, "generation_complete": true,
            "whole_request_complete": true, "audio_seconds": 48.75,
            "observed_wall_seconds": ProcessInfo.processInfo.systemUptime - start, "sdk_calls": 0,
            "player": "production AVNativeTTSPlayer", "coordinator": "production TextToSpeechService"]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("playback-receipt.json"), options: .withoutOverwriting)
        print("K4_HUMAN_ACTUAL_PLAYER_THREE_NATURAL_DRAINS_COMPLETE")
    }
}
