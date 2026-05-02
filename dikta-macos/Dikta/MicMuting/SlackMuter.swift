import AppKit
import ApplicationServices

final class SlackMuter: MicMuter {
    private let focusStash = FocusStash()
    private let slackBundleIdentifier = "com.tinyspeck.slackmacgap"

    func mute() -> MuteToken? {
        toggleSlackMute(previousFrontmostBundleID: nil)
    }

    func unmute(_ token: MuteToken) {
        _ = toggleSlackMute(previousFrontmostBundleID: token.previousFrontmostBundleID)
    }

    private func toggleSlackMute(previousFrontmostBundleID: String?) -> MuteToken? {
        guard let slackApp = runningSlackApplication(), shouldToggle(for: slackApp) else {
            return nil
        }

        let frontmostBundleID = previousFrontmostBundleID ?? focusStash.capture()
        slackApp.activate()
        sendM()
        focusStash.restore(frontmostBundleID)

        return MuteToken(
            muterID: muterID,
            previousFrontmostBundleID: frontmostBundleID
        )
    }

    private func runningSlackApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == slackBundleIdentifier }
    }

    private func shouldToggle(for slackApp: NSRunningApplication) -> Bool {
        if slackApp.isActive {
            return true
        }

        return slackHasHuddleWindow(pid: slackApp.processIdentifier)
    }

    private func slackHasHuddleWindow(pid: pid_t) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t
            guard ownerPID == pid else { continue }

            let title = (window[kCGWindowName as String] as? String) ?? ""
            if title.localizedCaseInsensitiveContains("huddle") {
                return true
            }
        }

        return false
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
