import Foundation

/// Why a shadow join ended in `.failed`.
enum ShadowFailure: Equatable {
    /// No Chrome/Edge/Brave found for `ChromeShadowHost`.
    case noBrowser
    /// The URL's host is not in the platform table.
    case unsupportedPlatform
    /// Platform row exists but its selectors are still placeholders.
    case platformNotImplemented(String)
    case pageLoadFailed(String)
    case launchFailed(String)
    /// Name field / ask-to-join control never showed up.
    case joinControlsNotFound
    /// Waited for the host to admit us and gave up.
    case admissionTimedOut
    /// The host refused the join request.
    case denied
}

enum ShadowJoinState: Equatable {
    case joining
    case waitingForAdmission
    case admitted
    case failed(ShadowFailure)
    case left
}

enum ShadowEvent: Equatable {
    case state(ShadowJoinState)
    case activeSpeaker(String?)
    case participantJoined(String)
    case participantLeft(String)
    case pageWarning(String)
}

/// A browser-backed meeting guest. Joins with mic and camera off; progress is reported
/// through `events`. `join` returns once the join flow is started, not once admitted.
@MainActor
protocol ShadowHost: AnyObject {
    /// Single-consumer stream of everything the host observes.
    var events: AsyncStream<ShadowEvent> { get }
    /// PIDs whose audio output carries the meeting, for `SystemAudioTapRecorder`.
    var audioProcessIDs: [pid_t] { get }
    func join(url: URL, displayName: String) async
    func leave() async
}
