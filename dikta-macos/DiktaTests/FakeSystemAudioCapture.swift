import Foundation
@testable import Dikta

/// Test double for `SystemAudioCapturing`. Lets tests drive start/stop and
/// synthetic samples through the debrief pipeline without opening a real
/// CoreAudio process tap. `feed(_:)` exists for later stories (continuous
/// disk writer, unified pipeline) that consume `onSamples`.
final class FakeSystemAudioCapture: SystemAudioCapturing {
    var onSamples: (([Float]) -> Void)?

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var isRunning = false

    /// Set to make the next `start()` throw instead of succeeding.
    var errorToThrow: Error?

    func start() async throws {
        startCallCount += 1
        if let errorToThrow {
            throw errorToThrow
        }
        isRunning = true
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
    }

    /// Delivers synthetic samples through `onSamples`, as the real tap would
    /// after conversion. Mirrors `SystemAudioTapRecorder`'s contract: no
    /// delivery once `stop()` has been called, so tests can assert that
    /// stop() and delivery never race.
    func feed(_ samples: [Float]) {
        guard isRunning else { return }
        onSamples?(samples)
    }
}
