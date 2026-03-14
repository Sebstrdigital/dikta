import Foundation
import Sparkle

/// Wraps the Sparkle SPUStandardUpdaterController and exposes update state to SwiftUI via @Published.
///
/// Lifecycle: created once in DiktaApp and passed down through the view hierarchy.
/// The underlying Sparkle controller owns the update check scheduling and UI.
final class SparkleController: ObservableObject {

    private let updaterController: SPUStandardUpdaterController

    /// True when Sparkle has found a new version that the user has not yet installed or skipped.
    @Published var updateAvailable: Bool = false

    /// Version string of the pending update, e.g. "0.7". Nil when no update is available.
    @Published var pendingVersion: String?

    init() {
        // userInitiatedCheckCanBeSkipped: false → don't show "skip" button on manual checks
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    // MARK: - Public API

    var updater: SPUUpdater { updaterController.updater }

    /// Trigger an immediate, user-visible update check (shown in menu as "Check for Updates...").
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Whether Sparkle will automatically check for updates on launch.
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    // MARK: - Update badge

    /// Called by the update observer when a new version is found.
    func markUpdateAvailable(version: String) {
        DispatchQueue.main.async {
            self.pendingVersion = version
            self.updateAvailable = true
        }
    }

    /// Called after the user installs or skips the update.
    func clearUpdate() {
        DispatchQueue.main.async {
            self.pendingVersion = nil
            self.updateAvailable = false
        }
    }
}
