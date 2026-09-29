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

/// Waits, for a bounded time after admission, until at least one of the host's audio PIDs
/// has a CoreAudio process object. The meeting page's audio object (WebKit GPU process,
/// Chromium audio helper) only exists once playback has started, so resolving right at
/// admission can find nothing and the tap would fall back to the unmuted global tap.
struct ShadowTapTargetWait {
    struct Outcome: Equatable {
        /// The host's PIDs at the last check; what the tap is built from.
        let pids: Set<pid_t>
        /// True when at least one of `pids` resolved.
        let resolvable: Bool
        /// Checks made, including the first one.
        let attempts: Int
    }

    var lister: AudioProcessListing
    var timeout: Duration = .seconds(10)
    var interval: Duration = .milliseconds(500)
    /// Injectable so tests tick without sleeping.
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// Re-reads `currentPIDs` on every check (helpers can appear after admission). Stops
    /// early when `shouldContinue` turns false.
    @MainActor
    func run(currentPIDs: () -> [pid_t], shouldContinue: () -> Bool = { true }) async -> Outcome {
        let maxAttempts = max(1, Int((timeout / interval).rounded(.down)) + 1)
        var pids = Set<pid_t>()
        var attempts = 0
        while attempts < maxAttempts {
            attempts += 1
            pids = Set(currentPIDs())
            if pids.contains(where: { lister.audioProcessObject(forPID: $0).id != nil }) {
                return Outcome(pids: pids, resolvable: true, attempts: attempts)
            }
            guard attempts < maxAttempts, shouldContinue() else { break }
            await sleep(interval)
            guard shouldContinue() else { break }
        }
        return Outcome(pids: pids, resolvable: false, attempts: attempts)
    }
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
    /// Bounded wait for the host's audio PIDs to become tappable after admission. nil
    /// (the test default) builds the tap from the PIDs as they are at admission.
    var tapTargetWait: ShadowTapTargetWait? = nil

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
        askAdmissionTimeout: { ShadowMeetingSheet.askAfterAdmissionTimeout(seconds: $0) },
        tapTargetWait: ShadowTapTargetWait(lister: CoreAudioProcessLister())
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
