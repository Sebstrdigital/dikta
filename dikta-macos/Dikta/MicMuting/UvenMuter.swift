import AppKit
import ApplicationServices

final class UvenMuter: MicMuter {
    private let focusStash = FocusStash()

    func mute() -> MuteToken? {
        toggleUvenMute(previousFrontmostBundleID: nil)
    }

    func unmute(_ token: MuteToken) {
        _ = toggleUvenMute(previousFrontmostBundleID: token.previousFrontmostBundleID)
    }

    private func toggleUvenMute(previousFrontmostBundleID: String?) -> MuteToken? {
        guard let app = runningUvenApplication() else {
            return nil
        }

        let frontmostBundleID = previousFrontmostBundleID ?? focusStash.capture()
        app.activate()
        sendM()
        focusStash.restore(frontmostBundleID)

        return MuteToken(
            muterID: muterID,
            previousFrontmostBundleID: frontmostBundleID
        )
    }

    private func runningUvenApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            if app.bundleIdentifier?.localizedCaseInsensitiveContains("uven") == true {
                return true
            }
            return app.localizedName?.localizedCaseInsensitiveContains("uven") == true
        }
    }

    private func sendM() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 46, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 46, keyDown: false) else {
            return
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
