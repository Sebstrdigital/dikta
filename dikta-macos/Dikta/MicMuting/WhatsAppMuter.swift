import AppKit
import ApplicationServices

final class WhatsAppMuter: MicMuter {
    private let bundleIdentifiers = ["net.whatsapp.WhatsApp", "WhatsApp Desktop"]

    func mute() -> MuteToken? {
        toggleWhatsAppMute()
    }

    func unmute(_ token: MuteToken) {
        guard token.didToggle == true else { return }
        _ = toggleWhatsAppMute()
    }

    private func toggleWhatsAppMute() -> MuteToken? {
        guard let app = runningWhatsAppApplication() else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let muteButton = findMuteButton(in: appElement) else {
            return nil
        }

        AXUIElementPerformAction(muteButton, kAXPressAction as CFString)
        return MuteToken(muterID: muterID, didToggle: true)
    }

    private func runningWhatsAppApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            if let bundleID = app.bundleIdentifier, bundleIdentifiers.contains(bundleID) {
                return true
            }
            return app.localizedName == "WhatsApp Desktop"
        }
    }

    private func findMuteButton(in root: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var steps = 0

        while !queue.isEmpty, steps < 2_000 {
            steps += 1
            let element = queue.removeFirst()

            if isMuteButton(element) {
                return element
            }

            queue.append(contentsOf: children(of: element))
        }

        return nil
    }

    private func isMuteButton(_ element: AXUIElement) -> Bool {
        guard role(of: element) == kAXButtonRole as String else {
            return false
        }

        let title = attributeString(kAXTitleAttribute as String, on: element) ?? ""
        let description = attributeString(kAXDescriptionAttribute as String, on: element) ?? ""

        return title.localizedCaseInsensitiveContains("mute") || description.localizedCaseInsensitiveContains("mute")
    }

    private func role(of element: AXUIElement) -> String? {
        attributeString(kAXRoleAttribute as String, on: element)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let array = value as? [AXUIElement] else {
            return []
        }
        return array
    }

    private func attributeString(_ attribute: String, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }

        return value as? String
    }
}
