import AppKit

/// What the user picked when the host had not admitted the shadow participant in time.
enum ShadowTimeoutChoice: Equatable {
    case keepWaiting
    case switchToSystemAudio
}

/// Stands in for the system-audio tap while the shadow participant is still waiting to be
/// admitted: the Me track is already recording, and the real tap replaces this on admission
/// (or on a switch to Microphone + system audio).
final class IdleSystemAudioCapture: SystemAudioCapturing {
    var onSamples: (([Float]) -> Void)?
    func start() async throws {}
    func stop() {}
}

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
    /// Asks what to do when the host has not admitted us after the given number of seconds.
    var askAdmissionTimeout: @MainActor (TimeInterval) async -> ShadowTimeoutChoice = { _ in .keepWaiting }

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
        clipboardText: { NSPasteboard.general.string(forType: .string) },
        askAdmissionTimeout: { ShadowMeetingSheet.askAfterAdmissionTimeout(seconds: $0) }
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

    static func askAfterAdmissionTimeout(seconds: TimeInterval) -> ShadowTimeoutChoice {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Dikta has not been let into the meeting"
        alert.informativeText = "The host has not admitted Dikta after \(Int(seconds)) seconds. Keep waiting, or switch this recording to Microphone + system audio. Your microphone has been recorded all along and the recording continues in the same session."
        alert.addButton(withTitle: "Keep Waiting")
        alert.addButton(withTitle: "Use Microphone + System Audio")
        return alert.runModal() == .alertFirstButtonReturn ? .keepWaiting : .switchToSystemAudio
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
