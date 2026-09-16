import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Migrate from old "Dua Talk" directory if needed
        AppPaths.migrateIfNeeded()
        // Copy bundled kokoro_server.py to Application Support if missing
        copyBundledServerScript()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        OnboardingWindowController.shared.show()
        return true
    }

    private func copyBundledServerScript() {
        let fm = FileManager.default
        let dest = AppPaths.kokoroServerScript

        guard !fm.fileExists(atPath: dest),
              let bundled = Bundle.main.path(forResource: "kokoro_server", ofType: "py") else {
            return
        }

        do {
            let dir = AppPaths.appSupport
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            try fm.copyItem(atPath: bundled, toPath: dest)
        } catch {
            AppLogger.general.error("Failed to copy kokoro_server.py: \(error.localizedDescription)")
        }
    }
}

/// No-op `TranscriptionEngine` used only when `Dikta.app` itself is acting as
/// the unit-test host for `xcodebuild test -scheme Dikta` (a "Host Application"
/// unit test bundle launches the real app first). In that case `DiktaApp`'s own
/// `init` still runs for real, so without this, `MenuBarViewModel()` below would
/// fall through to a real `Transcriber` and attempt a live WhisperKit model
/// download as a side effect of the app launching — invisible on a dev machine
/// with the model cached, but a hang/crash on a clean CI runner. Never touches
/// WhisperKit or the network.
@MainActor
private final class NoOpTranscriptionEngine: TranscriptionEngine {
    let isLoading = false
    let isReady = true
    let errorMessage: String? = nil
    let downloadProgress: Double? = nil

    func load() async {}
    func reload(model: WhisperModel) async throws {}
    func transcribe(_ audioSamples: [Float], language: String?, micSensitivity: MicSensitivity) async throws -> String { "" }
}

@main
struct DiktaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = MenuBarViewModel(
        engine: MenuBarViewModel.isRunningUnderXCTestHost ? NoOpTranscriptionEngine() : nil
    )
    @StateObject private var sparkle = SparkleController()

    init() {
        // Share SparkleController with the About window
        OnboardingWindowController.shared.sparkleController = _sparkle.wrappedValue
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
                .environmentObject(sparkle)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        let icon: some View = {
            switch viewModel.appState {
            case .idle:
                return Image(systemName: "mic")
            case .loading:
                return Image(systemName: "hourglass")
            case .recording:
                return Image(systemName: "record.circle.fill")
            case .processing:
                return Image(systemName: "hourglass")
            case .speaking:
                return Image(systemName: "speaker.wave.2.fill")
            }
        }()

        HStack(spacing: 2) {
            icon
            Text(viewModel.configService.language.menuBarCode)
                .font(.caption2)
        }
    }
}
