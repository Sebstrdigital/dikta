import Foundation
@testable import Dikta

/// An `AudioRecording` that never opens a microphone.
///
/// The real `AudioRecorder` builds an `AVAudioEngine` and, on a machine that
/// has not yet answered the prompt, calls `AVCaptureDevice.requestAccess` —
/// neither of which belongs in a unit test. This stands in for it: it records
/// what the ViewModel asked of it, can be made to fail `startRecording`, and
/// lets a test push samples through the live tap and hand back a final buffer.
///
/// Not thread-safe, and deliberately so: `MenuBarViewModel` is `@MainActor` and
/// every test drives this from the main actor, so there is nothing to
/// synchronize against.
final class FakeAudioRecorder: AudioRecording {
    // MARK: Configuration the ViewModel sets

    var silenceAutoStopEnabled: Bool = true
    var maxBufferSamples: Int = AudioRecorder.defaultMaxBufferSamples
    var accumulateInMemory: Bool = true
    var onLiveSamples: (([Float]) -> Void)?
    var onSilenceAutoStop: (([Float]) -> Void)?

    // MARK: Injected behavior

    /// When set, `startRecording` throws this instead of starting.
    var errorToThrow: Error?

    /// Returned by `stopRecording()`. Stays empty when `accumulateInMemory` is
    /// false at stop time, mirroring the real recorder's contract.
    var finalBuffer: [Float] = []

    /// Runs inside `startRecording()` before it succeeds or throws — the hook
    /// for asserting what else had (or had not) started by then.
    var onStartCalled: (() -> Void)?

    // MARK: Recorded calls

    private(set) var recording: Bool = false
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    /// One entry per `startRecording` attempt, successful or not.
    private(set) var receivedMicSensitivities: [MicSensitivity] = []

    // MARK: Diagnostics

    /// Settable stand-ins for the real counters. `AudioRecording` exposes them
    /// get-only, so a test sets them here and then asserts that the code under
    /// test read them (see `diagnosticCounterReads`).
    var inputSampleRateToReturn: Double = 48_000
    var routeChangeCountToReturn: Int = 0
    var converterErrorCountToReturn: Int = 0
    var emptyBufferCountToReturn: Int = 0

    /// How many times the three `AUDIO`-line counters were read. The diagnostic
    /// line is built by string interpolation at its call site and then handed
    /// to a globally-configured `DiagnosticLogger` that writes to the real
    /// `~/Library/Logs/Dikta` — which a test must not depend on. Counting the
    /// reads asserts the same thing (that the path ran and gathered them)
    /// without touching the developer's filesystem.
    private(set) var diagnosticCounterReads = 0

    var inputSampleRate: Double { inputSampleRateToReturn }

    var routeChangeCount: Int {
        diagnosticCounterReads += 1
        return routeChangeCountToReturn
    }

    var converterErrorCount: Int {
        diagnosticCounterReads += 1
        return converterErrorCountToReturn
    }

    var emptyBufferCount: Int {
        diagnosticCounterReads += 1
        return emptyBufferCountToReturn
    }

    // MARK: AudioRecording

    func startRecording(micSensitivity: MicSensitivity) async throws {
        startCallCount += 1
        receivedMicSensitivities.append(micSensitivity)
        onStartCalled?()
        if let errorToThrow {
            throw errorToThrow
        }
        recording = true
    }

    @discardableResult
    func stopRecording() -> [Float] {
        // The real recorder guards on `isRecording` and returns an empty array
        // when it was never started — `startCallRecording`'s mic-failure branch
        // relies on that being a no-op.
        guard recording else { return [] }
        stopCallCount += 1
        recording = false
        return accumulateInMemory ? finalBuffer : []
    }

    // MARK: Test driving

    /// Pushes samples through the live tap, exactly as the real recorder's
    /// `AVAudioEngine` tap callback does.
    func feedLiveSamples(_ samples: [Float]) {
        onLiveSamples?(samples)
    }

    /// Fires the silence auto-stop callback with `samples`.
    func triggerSilenceAutoStop(_ samples: [Float]) {
        onSilenceAutoStop?(samples)
    }
}
