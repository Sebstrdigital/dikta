import AppKit

/// The outside-world seams of a shadow participant session. Tests replace all of
/// them: no browser, no tap, no modal sheet.
struct ShadowDependencies {
    var isEnabled: () -> Bool
    var hostFactory: @MainActor (ShadowHostKind) -> any ShadowHost
    /// Builds the tap for the given host audio PIDs.
    var captureFactory: (Set<pid_t>) -> any SystemAudioCapturing
    /// Asks for the meeting link. Args: clipboard prefill, notetaker name, whether to show
    /// the one-time consent notice. Returns nil when the user cancels.
    var promptForMeeting: @MainActor (URL?, String, Bool) async -> URL?
    var clipboardText: () -> String?

    static let live = ShadowDependencies(
        isEnabled: { ShadowParticipantFlag.isEnabled() },
        hostFactory: { kind in
            switch kind {
            case .wkWebView: return WKWebViewShadowHost()
            case .chrome: return ChromeShadowHost()
            }
        },
        captureFactory: { SystemAudioTapRecorder(targetPIDs: $0) },
        promptForMeeting: { prefill, name, showNotice in
            ShadowMeetingSheet.askForMeeting(prefill: prefill, notetakerName: name, showNotice: showNotice)
        },
        clipboardText: { NSPasteboard.general.string(forType: .string) }
    )
}

/// Modal dialogs for the shadow participant.
@MainActor
enum ShadowMeetingSheet {
    static func consentText(notetakerName: String) -> String {
        "Dikta will join the meeting as \u{201C}\(notetakerName)\u{201D} and record its audio together with your microphone, on this Mac only. Other participants will see \u{201C}\(notetakerName)\u{201D} in the meeting and the host may have to let it in. It is your responsibility to tell participants that the meeting is being recorded."
    }

    static func askForMeeting(prefill: URL?, notetakerName: String, showNotice: Bool) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://meet.google.com/abc-defg-hij"
        field.stringValue = prefill?.absoluteString ?? ""
        while true {
            let alert = NSAlert()
            alert.messageText = "Join meeting as participant"
            alert.informativeText = showNotice
                ? "Paste the Meet, Teams or Zoom link.\n\n" + consentText(notetakerName: notetakerName)
                : "Paste the Meet, Teams or Zoom link. Dikta joins as \u{201C}\(notetakerName)\u{201D}."
            alert.accessoryView = field
            alert.addButton(withTitle: "Join")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if let url = ShadowPlatform.meetingURL(from: field.stringValue) { return url }
            field.stringValue = ""
            field.placeholderString = "Not a Meet, Teams or Zoom link"
        }
    }

    /// Returns the new name, or nil when cancelled or empty.
    static func askForDisplayName(current: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = current
        let alert = NSAlert()
        alert.messageText = "Notetaker name"
        alert.informativeText = "The name the shadow participant shows in the meeting."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
