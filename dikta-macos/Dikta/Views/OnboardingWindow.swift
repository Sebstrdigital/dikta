import SwiftUI
import AppKit
import AVFoundation

/// Window controller for first-launch onboarding
@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<OnboardingView>?

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

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 580)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Dikta"
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

// MARK: - TTS Setup

extension Notification.Name {
    static let ttsInstallCompleted = Notification.Name("ttsInstallCompleted")
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

        // Copy kokoro_server.py from bundle
        if let bundledScript = Bundle.main.path(forResource: "kokoro_server", ofType: "py") {
            let dest = Self.serverScript
            if fm.fileExists(atPath: dest) {
                try fm.removeItem(atPath: dest)
            }
            try fm.copyItem(atPath: bundledScript, toPath: dest)
        }

        // Find python3
        let pythonPath = try findPython()

        // Create venv
        let venvPath = dir + "/venv"
        if !fm.fileExists(atPath: venvPath) {
            status = .installing(step: "Preparing...")
            try await runProcess(pythonPath, arguments: ["-m", "venv", venvPath])
        }

        // Install packages (this can take several minutes)
        status = .installing(step: "Downloading voice engine...")
        let pip = venvPath + "/bin/pip"
        try await runProcess(pip, arguments: ["install", "kokoro", "soundfile", "numpy"])
    }

    private func findPython() throws -> String {
        // Check common locations
        let candidates = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.13",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        throw SetupError.pythonNotFound
    }

    private func runProcess(_ path: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    var errorMsg = "Exit code \(proc.terminationStatus)"
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if let stderr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !stderr.isEmpty {
                        errorMsg = String(stderr.suffix(200))
                    }
                    continuation.resume(throwing: SetupError.commandFailed(errorMsg))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
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
                return "Python 3 not found. Install from python.org or via Homebrew."
            case .commandFailed(let msg):
                return msg
            }
        }
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    let onDismiss: () -> Void

    @StateObject private var ttsSetup = TTSSetupManager()
    @State private var micStatus: PermissionStatus = .unknown
    @State private var accessibilityStatus: Bool = false

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

                // 2. Accessibility
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

            // Get Started
            Button(action: onDismiss) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(ttsSetup.status.isInstalling)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 500, height: 580)
        .onAppear {
            checkPermissions()
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
                    .lineLimit(1)
            }
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
