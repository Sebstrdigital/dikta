import Foundation

/// The start/stop-chime surface `MenuBarViewModel` uses.
///
/// Extracted for one specific reason: `AudioFeedback.init` builds an
/// `AVAudioEngine` eagerly, and a test process that constructs many
/// `MenuBarViewModel`s ends up racing a previous instance's
/// `AudioFeedback.deinit` inside CoreAudio's `HALB_Mutex`, which
/// intermittently wedges the whole test host. Tests inject
/// `FakeAudioFeedback` instead, so no engine is ever built.
protocol AudioFeedbackPlaying: AnyObject {
    /// When true, `beepOn`/`beepOff` do nothing. Mirrored from
    /// `ConfigService.muteSounds`.
    var isMuted: Bool { get set }

    /// Rising chime when recording starts.
    func beepOn()

    /// Falling chime when recording stops.
    func beepOff()
}

/// The real feedback already has every member, so this is a declaration of
/// conformance only — no behavior is added or changed.
extension AudioFeedback: AudioFeedbackPlaying {}

/// An `AudioFeedbackPlaying` that builds nothing and plays nothing.
///
/// This is the safety net behind `MenuBarViewModel.makeDefaultAudioFeedback()`:
/// tests are expected to inject `FakeAudioFeedback` explicitly, but a
/// `MenuBarViewModel` built under XCTest *without* an injected feedback — most
/// notably the one `DiktaApp` builds when `Dikta.app` is hosting the test
/// bundle — must still never construct an `AVAudioEngine`. Same reasoning, and
/// same shape, as the `assert` that guards the default `Transcriber`.
///
/// Production is unaffected: outside XCTest the default is a real
/// `AudioFeedback`, exactly as before.
final class SilentAudioFeedback: AudioFeedbackPlaying {
    var isMuted: Bool = false

    func beepOn() {}
    func beepOff() {}
}
