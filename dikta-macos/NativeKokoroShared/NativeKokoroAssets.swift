import Foundation
import CryptoKit
import Darwin

// Qualification candidate only, not a production installation/readiness claim.
public enum NKRuntimeFailure: UInt8, Error, Equatable {
    case manifest = 1, layout, missing, size, digest, migration, unsupportedOS, notReady, input, synthesis, samples
}
public struct NKAssetManifest: Decodable {
    public struct File: Decodable {
        public let bytes: Int
        public let localPath: String
        public let sha256: String
        public let sourcePath: String
    }
    public let files: [File]
    public let repository: String
    public let revision: String
    public static let revision = "006395f65025af251858b1ab0a7178a6a1e73f9f"
    public static let candidateDigest = "60d0c706f25cc00ac2932ca00169778b5a7d9efca2c67af66d13040b86c7b71f"
    public static func decodePinned(_ data: Data) throws -> Self {
        guard data.count <= 65536, hash(data) == candidateDigest else { throw NKRuntimeFailure.manifest }
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            try value.validate(); return value
        } catch { throw NKRuntimeFailure.manifest }
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public func validate() throws {
        guard repository == "FluidInference/kokoro-82m-coreml", revision == Self.revision,
              files.count == 49, files.reduce(0, { $0 + min(max($1.bytes, 0), 50_000_001) }) == 94_759_376 else { throw NKRuntimeFailure.manifest }
        var seen = Set<String>()
        for file in files {
            guard file.bytes > 0, file.bytes <= 50_000_000, file.sha256.count == 64,
                  file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  Self.safeRelative(file.sourcePath), Self.safeRelative(file.localPath),
                  seen.insert(file.localPath).inserted else { throw NKRuntimeFailure.manifest }
            let expected = file.sourcePath.hasPrefix("ANE/")
                ? "home/.cache/fluidaudio/Models/kokoro-82m-coreml/" + file.sourcePath
                : "home/.cache/fluidaudio/Models/kokoro/" + file.sourcePath
            guard file.localPath == expected else { throw NKRuntimeFailure.manifest }
        }
        let required = ["ANE/af_heart.bin", "ANE/vocab.json", "g2p_vocab.json", "us_lexicon_cache.json",
                        "G2PEncoder.mlmodelc/model.mil", "G2PDecoder.mlmodelc/model.mil"]
            + Self.bundles.map { "ANE/" + $0 + "/model.mil" }
        guard required.allSatisfy({ path in files.contains { $0.sourcePath == path } }) else { throw NKRuntimeFailure.manifest }
    }
    public static let bundles = ["KokoroAlbert.mlmodelc", "KokoroPostAlbert.mlmodelc", "KokoroAlignment.mlmodelc",
                                 "KokoroProsody.mlmodelc", "KokoroNoise_v2.mlmodelc", "KokoroVocoder.mlmodelc", "KokoroTail_v2.mlmodelc"]
    public static func safeRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\\") && !path.utf8.contains(0)
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
public struct NKAssetLayout: Equatable {
    public let home: URL
    public var modelsRoot: URL { home.appendingPathComponent(".cache/fluidaudio/Models", isDirectory: true) }
    public var frontend: URL { modelsRoot.appendingPathComponent("kokoro", isDirectory: true) }
    public var chain: URL { modelsRoot.appendingPathComponent("kokoro-82m-coreml/ANE", isDirectory: true) }
    // Foundation resolves the helper's actual sandbox/container home. Does not create paths.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home.standardizedFileURL.resolvingSymlinksInPath() }
    public func fileURL(_ file: NKAssetManifest.File) throws -> URL {
        guard file.localPath.hasPrefix("home/"), NKAssetManifest.safeRelative(file.localPath) else { throw NKRuntimeFailure.layout }
        return home.appendingPathComponent(String(file.localPath.dropFirst(5)))
    }
}
public enum NKAssetVerifier {
    // Read-only checks. The caller must retain this private tree unchanged throughout SDK work.
    public static func verify(_ manifest: NKAssetManifest, layout: NKAssetLayout) throws {
        try manifest.validate()
        for file in manifest.files { try verifyFile(file, layout: layout) }
        for bundle in NKAssetManifest.bundles {
            let model = layout.chain.appendingPathComponent(bundle)
            let backup = model.path + ".pre-flexible-shape-migration"
            // lstat sees dangling symlinks too; migration must not consume or delete any backup.
            var info = stat()
            guard lstat(backup, &info) != 0 && errno == ENOENT else { throw NKRuntimeFailure.migration }
            let mil = model.appendingPathComponent("model.mil")
            guard let data = try? Data(contentsOf: mil), data.count <= 1_000_000,
                  data.range(of: Data("[FlexibleShapeInformation =".utf8)) != nil else { throw NKRuntimeFailure.migration }
        }
    }
    public static func verifyFile(_ file: NKAssetManifest.File, layout: NKAssetLayout) throws {
        guard file.bytes > 0, file.bytes <= 50_000_000 else { throw NKRuntimeFailure.size }
        let url = try layout.fileURL(file)
        try checkPath(url, under: layout.home)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw NKRuntimeFailure.layout }
            guard (attributes[.size] as? NSNumber)?.intValue == file.bytes else { throw NKRuntimeFailure.size }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var digest = SHA256(), count = 0
            while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
                count += bytes.count; guard count <= file.bytes else { throw NKRuntimeFailure.size }
                digest.update(data: bytes)
            }
            guard count == file.bytes else { throw NKRuntimeFailure.size }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw NKRuntimeFailure.digest }
        } catch let failure as NKRuntimeFailure { throw failure }
        catch { throw NKRuntimeFailure.missing }
    }
    public static func checkPath(_ url: URL, under root: URL) throws {
        guard url.path.hasPrefix(root.path + "/") else { throw NKRuntimeFailure.layout }
        var current = root
        let components = String(url.path.dropFirst(root.path.count + 1)).split(separator: "/")
        for part in components {
            current.appendPathComponent(String(part))
            var info = stat()
            guard lstat(current.path, &info) == 0 else { throw NKRuntimeFailure.missing }
            guard (info.st_mode & S_IFMT) != S_IFLNK else { throw NKRuntimeFailure.layout }
        }
    }
}

// Small injected boundary: tests never construct the SDK backend or load any real assets.
public struct NKEngineSamples {
    public let samples: [Float]
    public let sampleRate: Int
    public init(samples: [Float], sampleRate: Int) { self.samples = samples; self.sampleRate = sampleRate }
}
public protocol NKEngineBackend: AnyObject {
    func initialize(modelsRoot: URL) async throws
    func phonemes(text: String) async throws -> String
    func synthesize(phonemes: String) async throws -> NKEngineSamples
    func wav(samples: [Float]) throws -> Data
}
public final class NKVerifiedEngine {
    private let backend: NKEngineBackend
    private let policy: () -> Void
    private let verify: () throws -> Void
    private let layout: NKAssetLayout
    private let os: OperatingSystemVersion
    private var ready = false
    // One serial work owner is required; this seam does not provide its own scheduler.
    public init(backend: NKEngineBackend, layout: NKAssetLayout, os: OperatingSystemVersion,
                policy: @escaping () -> Void, verify: @escaping () throws -> Void) {
        self.backend = backend; self.layout = layout; self.os = os; self.policy = policy; self.verify = verify
    }
    public func initialize() async throws {
        ready = false
        guard !(os.majorVersion == 26 && (4...5).contains(os.minorVersion)) else { throw NKRuntimeFailure.unsupportedOS }
        try checkedAssets()
        policy() // Before any backend SDK entry, including manager construction.
        do { try await backend.initialize(modelsRoot: layout.modelsRoot); ready = true }
        catch { throw NKRuntimeFailure.synthesis }
    }
    public func synthesize(text: String) async throws -> Data {
        guard ready else { throw NKRuntimeFailure.notReady }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1024,
              text.split(whereSeparator: { $0.isWhitespace }).count <= 64,
              text.split(whereSeparator: { $0.isWhitespace }).allSatisfy({ $0.count <= 62 }) else { throw NKRuntimeFailure.input }
        try checkedAssets(); policy()
        do {
            let phonemes = try await backend.phonemes(text: text)
            guard !phonemes.isEmpty, phonemes.unicodeScalars.count <= 510, phonemes.utf8.count <= 4096 else { throw NKRuntimeFailure.input }
            try Task.checkCancellation()
            let result = try await backend.synthesize(phonemes: phonemes)
            try Task.checkCancellation()
            guard result.sampleRate == 24000, !result.samples.isEmpty, result.samples.count <= 480000,
                  result.samples.allSatisfy({ $0.isFinite }), result.samples.contains(where: { $0 != 0 }) else { throw NKRuntimeFailure.samples }
            let data = try backend.wav(samples: result.samples)
            try NKAudio.validate(data); return data
        } catch let failure as NKRuntimeFailure { throw failure }
        catch { throw NKRuntimeFailure.synthesis } // Never forward NSError/userInfo/content.
    }
    private func checkedAssets() throws {
        do { try verify() } catch let failure as NKRuntimeFailure { throw failure }
        catch { throw NKRuntimeFailure.layout }
    }
}

// Single bounded result slot, shared only across work and control owners.
// Invalidating before cancellation prevents late completion from entering the outbox.
public final class NKResultMailbox {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var pending: [NKFrame] = []
    private var published = false
    public init() {}
    public func begin() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1; pending.removeAll(); published = false; return epoch
    }
    public func invalidate() { _ = begin() }
    @discardableResult public func publish(_ frames: [NKFrame], epoch token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == epoch, !published, !frames.isEmpty, frames.count <= 3,
              frames.reduce(0, { $0 + $1.payload.count }) <= NKFrame.maxPayload + 4096 else { return false }
        pending = frames; published = true; return true
    }
    public func take() -> [NKFrame] {
        lock.lock(); defer { lock.unlock() }
        let result = pending; pending.removeAll(); return result
    }
}

public enum NKDescriptorSetup {
    // Preserve descriptor flags. Must finish before descriptors enter an owner lock.
    public static func nonblocking(_ fd: Int32, noSIGPIPE: Bool,
                                   call: (Int32, Int32, Int32) -> Int32 = { fcntl($0, $1, $2) }) throws {
        let flags = call(fd, F_GETFL, 0)
        guard flags >= 0, call(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw NKError.launch }
        if noSIGPIPE { guard call(fd, F_SETNOSIGPIPE, 1) == 0 else { throw NKError.launch } }
    }
}
