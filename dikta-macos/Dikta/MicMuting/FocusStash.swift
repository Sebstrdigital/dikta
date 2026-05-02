import AppKit

final class FocusStash {
    func capture() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func restore(_ bundleIdentifier: String?) {
        guard let bundleIdentifier,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return
        }

        app.activate()
    }
}
