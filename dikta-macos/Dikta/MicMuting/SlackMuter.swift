import Foundation

/// Slack's former implementation sent a bare M whenever Slack was frontmost.
/// That types into message composers; being active (or having a window titled
/// "Huddle") does not establish that a call mute control owns keyboard focus.
/// Fail closed until a verified, state-aware Slack call-control path exists.
final class SlackMuter: MicMuter {
    func mute() -> MuteToken? { nil }

    func unmute(_ token: MuteToken) {
        // No token is issued, and stale tokens must never trigger keystrokes.
    }
}
