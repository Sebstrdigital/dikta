import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement

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

enum TTSSetupStatus: Equatable {
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

    private static let appSupportDir = AppPaths.appSupport
    private static let venvPython = AppPaths.venvPython
    private static let serverScript = AppPaths.kokoroServerScript

    init() {
        checkExisting()
    }

    func checkExisting() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.venvPython) && fm.fileExists(atPath: Self.serverScript) else { return }

        // Files exist — verify server is actually ready
        status = .startingServer
        Task {
            let ready = await waitForServer(timeout: 120)
            status = ready ? .installed : .failed("Voice engine failed to start. Try restarting.")
        }
    }

    func install() {
        guard !status.isInstalling else { return }
        status = .installing(step: "Preparing...")

        Task {
            do {
                try await runSetup()
                status = .installing(step: "Starting voice engine...")

                // Signal TextToSpeechService to start the server
                NotificationCenter.default.post(name: .ttsInstallCompleted, object: nil)

                // Wait for server to actually respond
                let ready = await waitForServer(timeout: 120)
                if ready {
                    status = .installed
                } else {
                    status = .failed("Voice engine timed out. Try restarting Dikta.")
                }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func runSetup() async throws {
        let fm = FileManager.default
        let dir = Self.appSupportDir

        // Create app support dir if needed
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Select a verified interpreter before touching an existing installation.
        let pythonPath = try await TTSSetupCommands.findPython()

        // Copy kokoro_server.py from bundle
        if let bundledScript = Bundle.main.path(forResource: "kokoro_server", ofType: "py") {
            let dest = Self.serverScript
            try Data(contentsOf: URL(fileURLWithPath: bundledScript))
                .write(to: URL(fileURLWithPath: dest), options: .atomic)
        }

        // Never reuse an incomplete or incompatible venv, and never delete it.
        let venvPath = dir + "/venv"
        try TTSSetupCommands.preserveVenv(at: venvPath)
        status = .installing(step: "Preparing...")
        _ = try await TTSSetupCommands.run(pythonPath, arguments: ["-m", "venv", venvPath], timeout: 60)

        status = .installing(step: "Downloading voice engine...")
        let python = venvPath + "/bin/python3"
        _ = try await TTSSetupCommands.run(python, arguments: ["-m", "pip", "install", "--upgrade", "pip", "--timeout", "30", "--retries", "2"])
        _ = try await TTSSetupCommands.run(python, arguments: ["-m", "pip", "install", "--timeout", "30", "--retries", "2", "kokoro", "soundfile", "numpy"])
        _ = try await TTSSetupCommands.run(python, arguments: ["-c", "import kokoro, soundfile, numpy"], timeout: 60)
    }

    private func waitForServer(timeout: Int) async -> Bool {
        let attempts = timeout * 2  // 500ms intervals
        for _ in 0..<attempts {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await pingServer() { return true }
        }
        return false
    }

    private func pingServer() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:59123/ping") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    enum SetupError: LocalizedError {
        case pythonNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .pythonNotFound:
                return "Python 3.11 is required for Kokoro. Install Python 3.11 from python.org or Homebrew, then retry."
            case .commandFailed(let msg):
                return msg
            }
        }
    }
}

/// Installer commands run off the cooperative pool with file-backed output:
/// a verbose pip child cannot fill a pipe while we wait for it to terminate.
/// Logs are retained locally so failures have diagnostics beyond the About row.
enum TTSSetupCommands {
    static func findPython(candidates: [String] = [
        "/opt/homebrew/bin/python3.11", "/usr/local/bin/python3.11",
        "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
        "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"
    ]) async throws -> String {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if let version = try? await run(path, arguments: ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"], timeout: 5),
               version.trimmingCharacters(in: .whitespacesAndNewlines) == "3.11" {
                return path
            }
        }
        throw TTSSetupManager.SetupError.pythonNotFound
    }

    @discardableResult
    static func preserveVenv(at path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let backup = path + ".backup-" + UUID().uuidString
        try FileManager.default.moveItem(atPath: path, toPath: backup)
        return backup
    }

    static func run(_ path: String, arguments: [String], timeout: TimeInterval = 600) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let log = FileManager.default.temporaryDirectory
                        .appendingPathComponent("dikta-tts-setup-\(UUID().uuidString).log")
                    guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
                        throw TTSSetupManager.SetupError.commandFailed("Cannot create installer log.")
                    }
                    let output = try FileHandle(forWritingTo: log)
                    defer { try? output.close() }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = arguments
                    process.standardOutput = output
                    process.standardError = output
                    try process.run()
                    let deadline = ProcessInfo.processInfo.systemUptime + timeout
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    let timedOut = process.isRunning
                    if timedOut {
                        process.terminate()
                        let grace = ProcessInfo.processInfo.systemUptime + 2
                        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                    process.waitUntilExit()
                    let input = try FileHandle(forReadingFrom: log)
                    defer { try? input.close() }
                    let end = try input.seekToEnd()
                    try input.seek(toOffset: end > 8192 ? end - 8192 : 0)
                    let text = String(decoding: try input.readToEnd() ?? Data(), as: UTF8.self)
                    if timedOut || process.terminationStatus != 0 {
                        let reason = timedOut ? "Timed out after \(Int(timeout))s" : "Exit code \(process.terminationStatus)"
                        throw TTSSetupManager.SetupError.commandFailed("\(reason): \(text.suffix(1000))\nLog: \(log.path)")
                    }
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        case .failed(let msg):
            VStack(alignment: .trailing, spacing: 2) {
                Button("Retry") { ttsSetup.install() }
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
