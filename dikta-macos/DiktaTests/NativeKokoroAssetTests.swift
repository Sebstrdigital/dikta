import XCTest
import Darwin
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
}
private final class NKFakeEngineBackend: NKEngineBackend {
    var calls: [String] = []
    var failure: Error?
    var output = NKEngineSamples(samples: [0.2], sampleRate: 24000)
    var resolved = "həloʊ"
    func initialize(modelsRoot: URL) async throws { calls.append("initialize"); if let failure { throw failure } }
    func phonemes(text: String) async throws -> String { calls.append("phonemes"); if let failure { throw failure }; return resolved }
    func synthesize(phonemes: String) async throws -> NKEngineSamples { calls.append("synthesize"); return output }
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
                        verify: @escaping () throws -> Void = {}) -> NKVerifiedEngine {
        NKVerifiedEngine(backend: fake, layout: NKAssetLayout(home: URL(fileURLWithPath: "/private/tmp/fake")),
                         os: OperatingSystemVersion(majorVersion: 26, minorVersion: minor, patchVersion: 0),
                         policy: { fake.calls.append("policy") }, verify: verify)
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
        XCTAssertEqual(fake.calls, ["policy", "initialize", "policy", "phonemes", "synthesize", "wav"])
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
        XCTAssertFalse(fake.calls.contains("synthesize"))
    }
    func testInvalidSamplesNeverReachPCMConversion() async throws {
        for output in [NKEngineSamples(samples: [], sampleRate: 24000), NKEngineSamples(samples: [.nan], sampleRate: 24000),
                       NKEngineSamples(samples: [.infinity], sampleRate: 24000), NKEngineSamples(samples: [0], sampleRate: 24000),
                       NKEngineSamples(samples: [1], sampleRate: 16000), NKEngineSamples(samples: Array(repeating: 1, count: 480001), sampleRate: 24000)] {
            let fake = NKFakeEngineBackend(); fake.output = output; let e = engine(fake); try await e.initialize()
            do { _ = try await e.synthesize(text: "Hello."); XCTFail() } catch { XCTAssertEqual(error as? NKRuntimeFailure, .samples) }
            XCTAssertFalse(fake.calls.contains("wav"))
        }
    }
    func testSelectedAssetFailureAfterInitializationPreventsFurtherSDKEntry() async throws {
        let fake = NKFakeEngineBackend(); var valid = true
        let e = engine(fake, verify: { if !valid { throw NKRuntimeFailure.digest } }); try await e.initialize(); valid = false
        do { _ = try await e.synthesize(text: "Hello."); XCTFail() } catch { XCTAssertEqual(error as? NKRuntimeFailure, .digest) }
        XCTAssertEqual(fake.calls, ["policy", "initialize"])
    }
}
final class NativeKokoroSetupTests: XCTestCase {
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
