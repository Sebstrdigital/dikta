import AppKit
import ApplicationServices
import Foundation

final class GoogleMeetMuter: MicMuter {
    private struct BrowserTarget {
        let bundleIdentifier: String
        let applicationName: String
    }

    private let focusStash = FocusStash()
    private let browsers: [BrowserTarget] = [
        .init(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome"),
        .init(bundleIdentifier: "com.apple.Safari", applicationName: "Safari"),
        .init(bundleIdentifier: "company.thebrowser.Browser", applicationName: "Arc"),
        .init(bundleIdentifier: "com.brave.Browser", applicationName: "Brave Browser"),
    ]

    func mute() -> MuteToken? {
        toggleMeetMute(preferredBundleIdentifier: nil)
    }

    func unmute(_ token: MuteToken) {
        _ = toggleMeetMute(
            preferredBundleIdentifier: token.browserBundleID,
            preferredLocator: token.meetingLocator,
            previousFrontmostBundleID: token.previousFrontmostBundleID
        )
    }

    private func toggleMeetMute(
        preferredBundleIdentifier: String?,
        preferredLocator: String? = nil,
        previousFrontmostBundleID: String? = nil
    ) -> MuteToken? {
        guard let match = findTarget(preferredBundleIdentifier: preferredBundleIdentifier, preferredLocator: preferredLocator) else {
            return nil
        }

        guard let browserApp = runningApplication(bundleIdentifier: match.target.bundleIdentifier) else {
            return nil
        }

        let frontmostBundleID = previousFrontmostBundleID ?? focusStash.capture()
        browserApp.activate()
        sendCommandD()
        focusStash.restore(frontmostBundleID)

        return MuteToken(
            muterID: muterID,
            previousFrontmostBundleID: frontmostBundleID,
            browserBundleID: match.target.bundleIdentifier,
            browserWindowTitle: nil,
            meetingLocator: match.locator
        )
    }

    private func findTarget(preferredBundleIdentifier: String?, preferredLocator: String?) -> (target: BrowserTarget, locator: String)? {
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let candidates = browsers
            .filter { runningBundleIDs.contains($0.bundleIdentifier) }
            .sorted { lhs, rhs in
                sortScore(bundleIdentifier: lhs.bundleIdentifier, frontmostBundleID: frontmostBundleID, preferredBundleIdentifier: preferredBundleIdentifier) <
                sortScore(bundleIdentifier: rhs.bundleIdentifier, frontmostBundleID: frontmostBundleID, preferredBundleIdentifier: preferredBundleIdentifier)
            }

        for candidate in candidates {
            if let preferredBundleIdentifier, candidate.bundleIdentifier != preferredBundleIdentifier {
                continue
            }

            let locator = preferredLocator ?? queryBrowser(applicationName: candidate.applicationName)
            guard let locator, locator.lowercased().contains("meet.google.com") else {
                continue
            }

            return (candidate, locator)
        }

        return nil
    }

    private func sortScore(bundleIdentifier: String, frontmostBundleID: String?, preferredBundleIdentifier: String?) -> Int {
        if let preferredBundleIdentifier, preferredBundleIdentifier == bundleIdentifier { return 0 }
        if frontmostBundleID == bundleIdentifier { return 1 }
        return 2
    }

    private func queryBrowser(applicationName: String) -> String? {
        let script = """
        tell application \"\(applicationName)\"
            if it is running then
                repeat with w in windows
                    repeat with t in tabs of w
                        set tabURL to \"\"
                        set tabTitle to \"\"
                        try
                            set tabURL to URL of t
                        end try
                        try
                            set tabTitle to title of t
                        on error
                            try
                                set tabTitle to name of t
                            end try
                        end try
                        if tabURL contains \"meet.google.com\" then return tabURL
                        if tabTitle contains \"meet.google.com\" then return tabTitle
                    end repeat
                end repeat
            end if
        end tell
        return \"\"
        """

        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier })
    }

    private func sendCommandD() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 2, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 2, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
