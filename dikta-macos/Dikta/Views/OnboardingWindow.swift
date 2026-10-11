import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement
import Security

/// Window controller for first-launch onboarding
@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    /// Set once from DiktaApp so the About window can access Sparkle
    var sparkleController: SparkleController?

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?

    func show() {
        // If already showing, just bring to front
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        close()

        let contentView = OnboardingView { [weak self] in
            self?.close()
        }

        let wrappedView: AnyView
        if let sparkle = sparkleController {
            wrappedView = AnyView(contentView.environmentObject(sparkle))
        } else {
            wrappedView = AnyView(contentView)
        }

        let hostingView = NSHostingView(rootView: wrappedView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 660)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About"
        window.contentView = hostingView
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false

        self.window = window
        self.hostingView = hostingView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
        hostingView = nil
    }
}

// MARK: - App Ready State

extension Notification.Name {
    static let ttsInstallCompleted = Notification.Name("ttsInstallCompleted")
    static let appModelLoaded = Notification.Name("appModelLoaded")
}

@MainActor
final class NativeKokoroVoiceAvailability: ObservableObject {
    enum State: Equatable { case unknown, checking, ready, unavailable(String) }

    typealias ReadinessProvider = @Sendable () async throws -> NativeKokoroInstaller.Readiness

    static let shared = NativeKokoroVoiceAvailability()
    @Published private(set) var state: State = .unknown
    @Published private(set) var installedVoices = Set<String>()

    private let readinessProvider: ReadinessProvider
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()

    init(readinessProvider: @escaping ReadinessProvider = {
        let installer = try await NativeKokoroInstaller.production()
        return try await installer.readiness()
    }) {
        self.readinessProvider = readinessProvider
    }

    func update(_ readiness: NativeKokoroInstaller.Readiness) {
        generation = UUID() // invalidate an older read-only refresh before publishing
        installedVoices = readiness.installedVoices
        state = readiness.baseInstalled ? .ready : .unavailable("The verified voice engine is not installed.")
    }

    func markUnavailable(_ error: Error) {
        generation = UUID()
        installedVoices = []
        state = .unavailable(error.localizedDescription)
    }

    func markUnknown() {
        generation = UUID()
        installedVoices = []
        state = .unknown
    }

    /// A read-only, verified refresh. It never installs assets or changes the
    /// user's selected voice. Its generation guard prevents a pre-install probe
    /// from overwriting the newer post-activation verification result.
    func refresh() {
        guard refreshTask == nil else { return }
        let job = UUID()
        generation = job
        state = .checking
        refreshTask = Task { [weak self] in
            defer { self?.refreshTask = nil }
            do {
                guard let self else { return }
                let readiness = try await self.readinessProvider()
                guard !Task.isCancelled, self.generation == job else { return }
                self.installedVoices = readiness.installedVoices
                self.state = readiness.baseInstalled ? .ready : .unavailable("The verified voice engine is not installed.")
            } catch is CancellationError {
                guard let self, self.generation == job else { return }
                self.state = .unknown
            } catch {
                guard let self, self.generation == job else { return }
                self.markUnavailable(error)
            }
        }
    }

    func isSelectable(_ voice: KokoroVoice) -> Bool {
        guard state == .ready else { return false }
        return voice == .af_heart || installedVoices.contains(voice.rawValue)
    }
}

enum TTSSetupStatus: Equatable {
    case checking
    case notInstalled
    case installing(step: String)
    case startingServer
    case installed
    case failed(String)

    /// Whether user-initiated setup is in progress (disables Get Started button)
    var isInstalling: Bool {
        if case .installing = self { return true }
        return false
    }
}

@MainActor
final class TTSSetupManager: ObservableObject {
    @Published var status: TTSSetupStatus = .notInstalled
    @Published private(set) var installedVoices = Set<String>()
    @Published var maintenanceNotice: String?
    private var installTask: Task<Void, Never>?
    private var baseJob: UUID?
    private var readinessJob: UUID?
    private var installer: NativeKokoroInstaller?
    private let productionFactory: @Sendable () async throws -> NativeKokoroInstaller

    init(installer: NativeKokoroInstaller? = nil,
         productionFactory: @escaping @Sendable () async throws -> NativeKokoroInstaller = { try await .production() }) {
        self.installer = installer
        self.productionFactory = productionFactory
        status = .checking
    }

    /// Explicit UI-lifecycle entry point. Signature validation, helper describe and
    /// the complete readiness hash pass happen only after the view appears, never
    /// synchronously in this MainActor initializer.
    func prepare() async {
        let job = UUID()
        readinessJob = job
        status = .checking
        do {
            let resolved = if let installer { installer } else { try await productionFactory() }
            let readiness = try await resolved.readiness()
            try Task.checkCancellation()
            guard readinessJob == job else { return }
            installer = resolved
            installedVoices = readiness.installedVoices
            NativeKokoroVoiceAvailability.shared.update(readiness)
            status = readiness.baseInstalled ? .installed : .notInstalled
            readinessJob = nil
        } catch is CancellationError {
            guard readinessJob == job else { return }
            NativeKokoroVoiceAvailability.shared.markUnknown()
            status = .notInstalled
            readinessJob = nil
        } catch {
            guard readinessJob == job else { return }
            NativeKokoroVoiceAvailability.shared.markUnavailable(error)
            status = .failed(error.localizedDescription)
            readinessJob = nil
        }
    }

    func checkExisting() async {
        guard let installer else { await prepare(); return }
        do {
            let readiness = try await installer.readiness()
            guard !Task.isCancelled else { return }
            installedVoices = readiness.installedVoices
            NativeKokoroVoiceAvailability.shared.update(readiness)
            status = readiness.baseInstalled ? .installed : .notInstalled
        } catch is CancellationError {
            // Preserve the last verified snapshot while this read-only probe is
            // cancelled; it did not establish that installed packs vanished.
        } catch {
            guard !Task.isCancelled else { return }
            NativeKokoroVoiceAvailability.shared.markUnavailable(error)
            status = .failed(error.localizedDescription)
        }
    }

    func install() {
        guard installTask == nil else { return }
        let job = UUID(); baseJob = job; maintenanceNotice = nil
        status = .installing(step: "Preparing verified native assets…")
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let installer else { throw NativeKokoroInstaller.InstallError.identity }
                let outcome = try await installer.installBase { [weak self] completed, total in
                    Task { @MainActor in
                        guard let self, self.baseJob == job else { return }
                        self.status = .installing(step: "Verifying \(completed) of \(total)…")
                    }
                }
                guard baseJob == job else { return }
                let readiness = try await installer.readiness()
                guard baseJob == job else { return }
                installedVoices = readiness.installedVoices
                NativeKokoroVoiceAvailability.shared.update(readiness)
                status = readiness.baseInstalled ? .installed : .notInstalled
                if outcome.retentionWarning { maintenanceNotice = "Installed. The previous verified version remains safely retained in staging." }
            } catch is CancellationError {
                guard baseJob == job else { return }
                if let installer, let readiness = try? await installer.readiness(), !Task.isCancelled {
                    status = readiness.baseInstalled ? .installed : .notInstalled
                    installedVoices = readiness.installedVoices
                    NativeKokoroVoiceAvailability.shared.update(readiness)
                } else {
                    NativeKokoroVoiceAvailability.shared.markUnknown()
                    status = .notInstalled
                }
            } catch {
                guard baseJob == job else { return }
                NativeKokoroVoiceAvailability.shared.markUnavailable(error)
                status = .failed(error.localizedDescription)
            }
            guard baseJob == job else { return }
            installTask = nil; baseJob = nil
        }
    }

    func cancel() { installTask?.cancel() }
    func retry() {
        if installer == nil { Task { await prepare() } }
        else { install() }
    }
}

enum NativeKokoroLayoutDescriptor {
    static let productionIdentifier = "com.duatalk.app.NativeKokoroHelper"
    static let productionTeam = "UUM29335B4"
    static func productionHome() throws -> URL {
        let executable = NativeKokoroSession.packagedURL()
        var staticCode: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecRequirementCreateWithString("anchor apple generic and identifier \"\(productionIdentifier)\" and certificate leaf[subject.OU] = \"\(productionTeam)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw NativeKokoroInstaller.InstallError.identity
        }
        let child = try NativeKokoroChild(executable: executable)
        defer { child.closeControl(); child.signal(force: true); child.closeResults() }
        var outbox = NKOutbox(), decoder = NKDecoder(), received: [NKFrame] = []
        func transact(_ frame: NKFrame, terminal: NKKind) throws -> [NKFrame] {
            received.removeAll(); try outbox.enqueue(frame)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                try outbox.flush { try child.write($0) }
                if let bytes = try child.read() { try decoder.feed(bytes) { received.append($0) } }
                if received.contains(where: { $0.kind == terminal }) { return received }
                if child.exited() { break }
                usleep(1_000)
            }
            throw NativeKokoroInstaller.InstallError.identity
        }
        guard try transact(NKFrame(.hello, session: 0x4b32444553435249), terminal: .ready) ==
                [NKFrame(.ready, session: 0x4b32444553435249)] else { throw NativeKokoroInstaller.InstallError.identity }
        let frames = try transact(NKFrame(.describe, session: 0x4b32444553435249, request: 1), terminal: .complete)
        guard frames.count == 2, frames[0].kind == .layout, frames[0].request == 1,
              let paths = try JSONSerialization.jsonObject(with: frames[0].payload) as? [String], paths.count == 4 else {
            throw NativeKokoroInstaller.InstallError.identity
        }
        let home = URL(fileURLWithPath: paths[0]).standardizedFileURL
        let layout = NKAssetLayout(home: home)
        guard home.path.hasSuffix("/Library/Containers/\(productionIdentifier)/Data"),
              paths[1] == layout.modelsRoot.path, paths[2] == layout.frontend.path, paths[3] == layout.chain.path else {
            throw NativeKokoroInstaller.InstallError.identity
        }
        return home
    }
}

private final class NativeKokoroRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let allowedHosts = Set(["huggingface.co", "cdn-lfs.huggingface.co", "cdn-lfs-us-1.hf.co", "cas-bridge.xethub.hf.co"])
    let origin: URL
    init(origin: URL) { self.origin = origin }
    static func allows(_ url: URL) -> Bool { url.scheme == "https" && url.port == nil && allowedHosts.contains(url.host ?? "") }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, Self.allows(origin), Self.allows(next) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

enum NativeKokoroPinnedTransport {
    static func fetch(_ url: URL, expectedBytes: Int) async throws -> Data {
        guard expectedBytes > 0, expectedBytes <= 50_000_000,
              NativeKokoroRedirectPolicy.allows(url), url.host == "huggingface.co" else {
            throw NativeKokoroInstaller.InstallError.manifest
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpMethod = "GET"
        let (stream, response) = try await URLSession.shared.bytes(for: request, delegate: NativeKokoroRedirectPolicy(origin: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url.map(NativeKokoroRedirectPolicy.allows) == true,
              http.expectedContentLength < 0 || http.expectedContentLength == Int64(expectedBytes) else {
            throw NativeKokoroInstaller.InstallError.transport
        }
        var result = Data(); result.reserveCapacity(expectedBytes)
        for try await byte in stream {
            try Task.checkCancellation()
            guard result.count < expectedBytes else { throw NativeKokoroInstaller.InstallError.transport }
            result.append(byte)
        }
        guard result.count == expectedBytes else { throw NativeKokoroInstaller.InstallError.transport }
        return result
    }
}

struct NativeKokoroActivation: Sendable {
    typealias Exists = @Sendable (URL) -> Bool
    typealias Move = @Sendable (URL, URL) throws -> Void
    typealias Swap = @Sendable (URL, URL) -> Bool
    var exists: Exists = { FileManager.default.fileExists(atPath: $0.path) }
    var move: Move = { try FileManager.default.moveItem(at: $0, to: $1) }
    var swap: Swap = { staged, active in
        renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, active.path, UInt32(RENAME_SWAP)) == 0
    }
    func commit(staged: URL, active: URL, retained: URL) throws -> NativeKokoroInstaller.Outcome {
        if exists(active) {
            guard swap(staged, active) else { throw NativeKokoroInstaller.InstallError.activation }
            do {
                try move(staged, retained)
                return .init(activated: true, retainedPrevious: true, retentionWarning: false)
            } catch {
                // Atomic commit already succeeded; never misreport the prior tree as active.
                return .init(activated: true, retainedPrevious: true, retentionWarning: true)
            }
        }
        try move(staged, active)
        return .init(activated: true, retainedPrevious: false, retentionWarning: false)
    }
}

/// Verified, cancellable installer boundary. Downloads only manifest-pinned HTTPS
/// files into a fresh sibling staging tree, verifies the complete SDK layout, then
/// atomically swaps the single Models directory. A valid prior tree is retained.
final class NativeKokoroInstaller: @unchecked Sendable {
    struct SourceManifest: Decodable {
        struct File: Decodable { let bytes: Int; let localPath: String; let sha256: String; let sourceURL: URL }
        let files: [File]
    }
    enum InstallError: LocalizedError, Equatable {
        case manifest, disk, transport, busy, activation, identity
        var errorDescription: String? {
            switch self {
            case .manifest: return "The signed voice asset manifest is invalid."
            case .disk: return "Not enough disk space to prepare the voice engine safely."
            case .transport: return "A voice asset download failed verification. Retry to repair it."
            case .busy: return "Read Aloud is currently using these assets. Stop it and retry."
            case .activation: return "The verified voice engine could not be activated; the previous installation was preserved."
            case .identity: return "The signed native voice helper identity or private asset layout could not be verified."
            }
        }
    }
    struct Outcome: Equatable, Sendable {
        let activated: Bool
        let retainedPrevious: Bool
        let retentionWarning: Bool
        static let unchanged = Outcome(activated: false, retainedPrevious: false, retentionWarning: false)
    }
    struct Readiness: Equatable, Sendable {
        let baseInstalled: Bool
        let installedVoices: Set<String>
    }
    typealias Fetch = @Sendable (URL, Int) async throws -> Data
    typealias LeaseFactory = @Sendable () throws -> NKAssetLease
    private let home: URL
    private let manifestData: Data
    private let fetch: Fetch
    private let available: @Sendable (URL) throws -> Int64
    private let acquireShared: LeaseFactory
    private let acquireExclusive: LeaseFactory
    private let preflightFailure: InstallError?
    private let activation: NativeKokoroActivation
    private let willVerifyUnderSharedLease: @Sendable () -> Void
    private let willCommitUnderExclusiveLease: @Sendable () -> Void
    private let fm = FileManager.default

    init(home: URL, manifestData: Data,
         fetch: @escaping Fetch,
         available: @escaping @Sendable (URL) throws -> Int64,
         acquireShared: LeaseFactory? = nil,
         acquireExclusive: LeaseFactory? = nil,
         preflightFailure: InstallError? = nil,
         activation: NativeKokoroActivation = .init(),
         willVerifyUnderSharedLease: @escaping @Sendable () -> Void = {},
         willCommitUnderExclusiveLease: @escaping @Sendable () -> Void = {}) {
        self.home = home.standardizedFileURL; self.manifestData = manifestData; self.fetch = fetch
        self.available = available; self.preflightFailure = preflightFailure; self.activation = activation
        self.willVerifyUnderSharedLease = willVerifyUnderSharedLease
        self.willCommitUnderExclusiveLease = willCommitUnderExclusiveLease
        self.acquireShared = acquireShared ?? { try NKAssetLease(home: home, mode: .shared) }
        self.acquireExclusive = acquireExclusive ?? { try NKAssetLease(home: home, mode: .exclusive) }
    }
    static func production() async throws -> NativeKokoroInstaller {
        let worker = Task.detached(priority: .userInitiated) { () throws -> NativeKokoroInstaller in
            let home: URL
            do { home = try NativeKokoroLayoutDescriptor.productionHome() }
            catch { throw (error as? InstallError) ?? .identity }
            try Task.checkCancellation()
            return NativeKokoroInstaller(home: home, manifestData: NKEmbeddedManifest.data,
                fetch: { url, expectedBytes in try await NativeKokoroPinnedTransport.fetch(url, expectedBytes: expectedBytes) },
                available: { url in
                    let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    return values.volumeAvailableCapacityForImportantUsage ?? 0
                })
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    func readiness() async throws -> Readiness {
        guard preflightFailure == nil else { throw preflightFailure! }
        let worker = Task.detached(priority: .userInitiated) { try self.readinessWork() }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private func readinessWork() throws -> Readiness {
        if let preflightFailure { throw preflightFailure }
        let lease: NKAssetLease
        do { lease = try acquireShared() } catch { return Readiness(baseInstalled: false, installedVoices: []) }
        return try withExtendedLifetime(lease) {
            try Task.checkCancellation()
            willVerifyUnderSharedLease()
            let layout = NKAssetLayout(home: home)
            guard let manifest = try? NKAssetManifest.decodePinned(manifestData),
                  (try? Data(contentsOf: layout.modelsRoot.appendingPathComponent("COMPLETE"))) == Data("revision=\(NKAssetManifest.revision)\n".utf8),
                  (try? NKAssetVerifier.verify(manifest, layout: layout)) != nil else {
                return Readiness(baseInstalled: false, installedVoices: [])
            }
            guard NKVoiceCatalog.entries.allSatisfy({ (try? NKVoiceCatalog.verify($0.id, layout: layout)) != nil }) else {
                return Readiness(baseInstalled: false, installedVoices: [])
            }
            return Readiness(baseInstalled: true, installedVoices: Set(NKVoiceCatalog.entries.map(\.id)))
        }
    }
    func isBaseInstalled() async throws -> Bool { try await readiness().baseInstalled }
    func installBase(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Outcome {
        let worker = Task.detached(priority: .userInitiated) { try await self.installBaseWork(progress: progress) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private func installBaseWork(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Outcome {
        if let preflightFailure { throw preflightFailure }
        let pinned = try NKAssetManifest.decodePinned(manifestData)
        let sources = try JSONDecoder().decode(SourceManifest.self, from: manifestData)
        guard sources.files.count == pinned.files.count else { throw InstallError.manifest }
        let required = Int64(pinned.files.reduce(0) { $0 + $1.bytes }) * 2 + 16_777_216
        guard try available(capacityURL()) >= required else { throw InstallError.disk }
        let stage = home.deletingLastPathComponent().appendingPathComponent(".NativeKokoro-stage-\(NKAssetManifest.revision)")
        try validateOrCreateStage(stage)
        let stageLayout = NKAssetLayout(home: stage), activeLayout = NKAssetLayout(home: home)
        var readLease: NKAssetLease? = try? acquireShared() // first install has no lock parent yet
        defer { withExtendedLifetime(readLease) {} }
        for (index, source) in sources.files.enumerated() {
            try Task.checkCancellation()
            let file = pinned.files[index]
            guard source.bytes == file.bytes, source.sha256 == file.sha256,
                  source.localPath == file.localPath, source.sourceURL.scheme == "https",
                  source.sourceURL.host == "huggingface.co" else { throw InstallError.manifest }
            let destination = try stageLayout.fileURL(file)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? NKAssetVerifier.verifyFile(file, layout: stageLayout)) != nil {
                progress(index + 1, sources.files.count); continue // genuine verified partial-stage reuse
            }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            if readLease != nil, (try? NKAssetVerifier.verifyFile(file, layout: activeLayout)) != nil,
               let existing = try? activeLayout.fileURL(file) {
                try fm.copyItem(at: existing, to: destination)
            } else {
                let data = try await fetch(source.sourceURL, source.bytes)
                try Task.checkCancellation()
                guard data.count == source.bytes, NKAssetManifest.hash(data) == source.sha256 else { throw InstallError.transport }
                try data.write(to: destination, options: .atomic)
            }
            try NKAssetVerifier.verifyFile(file, layout: stageLayout)
            progress(index + 1, sources.files.count)
        }
        try NKAssetVerifier.verify(pinned, layout: stageLayout)
        readLease = nil
        let lease: NKAssetLease
        do { lease = try acquireExclusive() } catch NKLeaseFailure.busy { throw InstallError.busy }
        defer { withExtendedLifetime(lease) {} }
        willCommitUnderExclusiveLease()
        // Fixed voice packs are signed app resources, not downloaded assets.
        // Verify each resource before placing it into the exclusively leased staged tree.
        for entry in NKVoiceCatalog.entries {
            guard let source = Bundle.main.url(forResource: entry.id, withExtension: "bin", subdirectory: "Voices") else { throw InstallError.manifest }
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            guard data.count == entry.bytes, NKAssetManifest.hash(data) == entry.derivedSHA256 else { throw InstallError.manifest }
            let destination = stageLayout.chain.appendingPathComponent("\(entry.id).bin")
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try data.write(to: destination, options: .atomic)
            try NKVoiceCatalog.verify(entry.id, layout: stageLayout)
        }
        try NKAssetVerifier.verify(pinned, layout: stageLayout)
        let stagedModels = stageLayout.modelsRoot
        try Data("revision=\(NKAssetManifest.revision)\n".utf8).write(to: stagedModels.appendingPathComponent("COMPLETE"), options: [.atomic])
        try Task.checkCancellation() // immediately before commit while exclusively leased
        let active = activeLayout.modelsRoot
        try fm.createDirectory(at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
        let retained = home.appendingPathComponent(".cache/fluidaudio/Retained-\(UUID().uuidString)")
        return try activation.commit(staged: stagedModels, active: active, retained: retained)
    }
    private func isVoiceInstalledUnderHeldLease(_ id: String) -> Bool {
        (try? NKVoiceCatalog.verify(id, layout: NKAssetLayout(home: home))) != nil
    }
    private func capacityURL() throws -> URL {
        var candidate = home
        while !fm.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { throw InstallError.disk }
            candidate = parent
        }
        return candidate
    }
    private func validateOrCreateStage(_ stage: URL) throws {
        var info = stat()
        if lstat(stage.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw InstallError.activation }
        } else {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    let onDismiss: () -> Void

    @EnvironmentObject var sparkle: SparkleController
    @StateObject private var ttsSetup = TTSSetupManager()
    @State private var micStatus: PermissionStatus = .unknown
    @State private var accessibilityStatus: Bool = false
    @State private var isAppReady: Bool = false
    @State private var launchAtLogin: Bool = false
    @State private var autoCheckForUpdates: Bool = true

    enum PermissionStatus {
        case unknown, granted, denied
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)

                Text("Welcome to Dikta")
                    .font(.system(size: 24, weight: .bold))

                Text("Offline dictation for your Mac. Press a hotkey, speak, and your words are pasted instantly.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("v\(version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if sparkle.updateAvailable, let newVersion = sparkle.pendingVersion {
                    Button(action: { sparkle.checkForUpdates() }) {
                        Label("v\(newVersion) available — install", systemImage: "arrow.down.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            Divider()
                .padding(.horizontal, 32)

            // Setup steps
            VStack(spacing: 14) {
                Text("Setup")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 1. Microphone
                setupRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "Required for dictation"
                ) { micStatusView }

                // 2. Accessibility (also covers global hotkey monitoring via CGEventTap;
                //    a separate Input Monitoring permission is NOT required for CGEventTap)
                setupRow(
                    icon: "hand.raised.fill",
                    title: "Accessibility",
                    subtitle: "Required for hotkeys and auto-paste"
                ) { accessibilityStatusView }

                // 3. TTS
                setupRow(
                    icon: "speaker.wave.2.fill",
                    title: "Text-to-Speech",
                    subtitle: "Optional — read selected text aloud"
                ) { ttsStatusView }

                // 4. Launch at Login
                setupRow(
                    icon: "arrow.up.right.square",
                    title: "Launch at Login",
                    subtitle: "Start Dikta automatically when you log in"
                ) { launchAtLoginToggle }

                // 5. Auto-Update
                setupRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Automatic Updates",
                    subtitle: "Check for new versions on launch"
                ) { autoUpdateToggle }
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)

            Spacer()

            Button("Third-Party Notices") {
                if let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
                    NSWorkspace.shared.open(notices)
                }
            }
            .buttonStyle(.link)
            .font(.caption)

            // Tip
            Text("Look for the mic icon in your menu bar. Reopen this window by launching Dikta again.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 12)

            // Get Started / Loading model
            Button(action: onDismiss) {
                if isAppReady {
                    Text("Start Dictating")
                        .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading model...")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isAppReady || ttsSetup.status.isInstalling)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 500, height: 660)
        .onAppear {
            checkPermissions()
            checkLaunchAtLogin()
            autoCheckForUpdates = sparkle.automaticallyChecksForUpdates
            isAppReady = MenuBarViewModel.isModelLoaded
        }
        .onReceive(NotificationCenter.default.publisher(for: .appModelLoaded)) { _ in
            isAppReady = true
        }
        .task {
            await ttsSetup.prepare()
            // Poll permissions every 5 seconds until all granted
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !accessibilityStatus {
                    accessibilityStatus = AXIsProcessTrusted()
                }
                if micStatus == .denied {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                        micStatus = .granted
                    }
                }
                if accessibilityStatus && micStatus == .granted { break }
            }
        }
    }

    // MARK: - Setup Row

    private func setupRow<Status: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder status: () -> Status
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            status()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Status Views

    @ViewBuilder
    private var micStatusView: some View {
        switch micStatus {
        case .unknown:
            Button("Grant") { requestMicPermission() }
                .controlSize(.small)
        case .granted:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        case .denied:
            Button("Open Settings") { openSystemPrefs("Privacy_Microphone") }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var accessibilityStatusView: some View {
        if accessibilityStatus {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        } else {
            Button("Open Settings") { openSystemPrefs("Privacy_Accessibility") }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var ttsStatusView: some View {
        switch ttsSetup.status {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking voice assets…").font(.caption).foregroundColor(.secondary)
            }
        case .notInstalled:
            Button("Set Up") { ttsSetup.install() }
                .controlSize(.small)
        case .installing(let step):
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(step)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Button("Cancel") { ttsSetup.cancel() }
                        .controlSize(.mini)
                }
            }
        case .startingServer:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting voice engine...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        case .installed:
            HStack(spacing: 6) {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("4 bundled voices ready").font(.caption).foregroundColor(.secondary)
            }
        case .failed(let msg):
            VStack(alignment: .trailing, spacing: 2) {
                Button("Retry") { ttsSetup.retry() }
                    .controlSize(.small)
                Text(msg)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(3)
                    .help(msg)
            }
        }
    }

    // MARK: - Launch at Login

    @ViewBuilder
    private var launchAtLoginToggle: some View {
        Toggle("", isOn: $launchAtLogin)
            .labelsHidden()
            .onChange(of: launchAtLogin) { _, enabled in
                setLaunchAtLogin(enabled)
            }
    }

    // MARK: - Auto-Update

    @ViewBuilder
    private var autoUpdateToggle: some View {
        Toggle("", isOn: $autoCheckForUpdates)
            .labelsHidden()
            .onChange(of: autoCheckForUpdates) { _, enabled in
                sparkle.automaticallyChecksForUpdates = enabled
            }
    }

    private func checkLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLogger.general.error("Failed to \(enabled ? "register" : "unregister") launch at login: \(error.localizedDescription)")
            // Revert toggle if operation failed
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Helpers

    private func checkPermissions() {
        // Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micStatus = .granted
        case .denied, .restricted:
            micStatus = .denied
        default:
            micStatus = .unknown
        }

        // Accessibility
        accessibilityStatus = AXIsProcessTrusted()
    }

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                micStatus = granted ? .granted : .denied
            }
        }
    }

    private func openSystemPrefs(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
