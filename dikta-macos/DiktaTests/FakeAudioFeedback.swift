import Foundation
@testable import Dikta

/// An `AudioFeedbackPlaying` that builds no `AVAudioEngine` and makes no sound.
///
/// Every ViewModel test injects this. The real `AudioFeedback` constructs an
/// `AVAudioEngine` in its initializer and tears one down in `deinit`; a test
/// process that builds a ViewModel per test case intermittently wedges when a
/// new engine's `mainMixerNode` contends with a previous instance's `deinit`
/// inside CoreAudio's `HALB_Mutex`.
///
/// Unlike `SilentAudioFeedback` (the production safety net) this records what
/// it was asked to play, so a test can assert on the chimes.
final class FakeAudioFeedback: AudioFeedbackPlaying {
    var isMuted: Bool = false

    private(set) var beepOnCount = 0
    private(set) var beepOffCount = 0

    func beepOn() {
        beepOnCount += 1
    }

    func beepOff() {
        beepOffCount += 1
    }
}
