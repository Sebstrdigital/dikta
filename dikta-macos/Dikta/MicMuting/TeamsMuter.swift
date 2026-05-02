import AppKit
import ApplicationServices

final class TeamsMuter: MicMuter {
    private let focusStash = FocusStash()
    private let bundleIdentifiers = ["com.microsoft.teams2", "com.microsoft.teams"]

    func mute() -> MuteToken? {
        toggleTeamsMute(previousFrontmostBundleID: nil)
    }

    func unmute(_ token: MuteToken) {
        _ = toggleTeamsMute(previousFrontmostBundleID: token.previousFrontmostBundleID)
    }

    private func toggleTeamsMute(previousFrontmostBundleID: String?) -> MuteToken? {
        guard let app = runningTeamsApplication() else {
            return nil
        }

        let frontmostBundleID = previousFrontmostBundleID ?? focusStash.capture()
        app.activate()
        sendCommandShiftM()
        focusStash.restore(frontmostBundleID)

        return MuteToken(
            muterID: muterID,
            previousFrontmostBundleID: frontmostBundleID
        )
    }

    private func runningTeamsApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return bundleIdentifiers.contains(bundleID)
        }
    }

    private func sendCommandShiftM() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 46, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 46, keyDown: false) else {
            return
        }

        keyDown.flags = [.maskCommand, .maskShift]
        keyUp.flags = [.maskCommand, .maskShift]
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
