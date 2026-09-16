import Foundation
import Sparkle

/// Wraps the Sparkle SPUStandardUpdaterController and exposes update state to SwiftUI via @Published.
///
/// Lifecycle: created once in DiktaApp and passed down through the view hierarchy.
/// The underlying Sparkle controller owns the update check scheduling and UI.
final class SparkleController: NSObject, ObservableObject, SPUUpdaterDelegate {

    private var updaterController: SPUStandardUpdaterController!

    /// True when Sparkle has found a new version that the user has not yet installed or skipped.
    @Published var updateAvailable: Bool = false

    /// Version string of the pending update, e.g. "0.7". Nil when no update is available.
    @Published var pendingVersion: String?

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            // Never start the updater when Dikta.app is only the XCTest host:
            // a started updater fetches the appcast over the network during tests.
            startingUpdater: !MenuBarViewModel.isRunningUnderXCTestHost,
            updaterDelegate: self,
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

    // MARK: - SPUUpdaterDelegate

    /// Called when Sparkle finds a valid update — show the badge.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        markUpdateAvailable(version: item.displayVersionString)
    }

    /// Called when Sparkle confirms no update is available — clear the badge.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        clearUpdate()
    }

    /// Called when the user skips a version — clear the badge.
    func updater(_ updater: SPUUpdater, userDidSkip item: SUAppcastItem) {
        clearUpdate()
    }

    /// Called after a successful update installation — clear the badge.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error == nil {
            clearUpdate()
        }
    }
}
