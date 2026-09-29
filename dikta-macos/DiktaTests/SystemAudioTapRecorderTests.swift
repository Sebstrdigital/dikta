import XCTest
import CoreAudio
@testable import Dikta

final class SystemAudioTapRecorderTests: XCTestCase {

    // MARK: - downmixAndResample (pure conversion path — no real tap)

    @available(macOS 14.2, *)
    func testDownmixAndResample_stereoSine_lengthRatioWithinOneFrame() {
        let frames = 48_000 // 1s at 48 kHz
        let interleaved = Self.stereoSine(frames: frames, frequency: 440, sampleRate: 48_000, amplitude: 0.5)

        let result = SystemAudioTapRecorder.downmixAndResample(interleaved, frames: frames, from: 48_000, to: 16_000)

        let expectedCount = frames / 3 // 48kHz -> 16kHz is an exact 3:1 ratio
        XCTAssertLessThanOrEqual(abs(result.count - expectedCount), 1,
                                  "expected ~\(expectedCount) frames at 16 kHz, got \(result.count)")
    }

    @available(macOS 14.2, *)
    func testDownmixAndResample_stereoSine_preservesRMSWithinTenPercent() {
        let frames = 48_000
        let amplitude: Float = 0.5
        let interleaved = Self.stereoSine(frames: frames, frequency: 440, sampleRate: 48_000, amplitude: amplitude)

        let result = SystemAudioTapRecorder.downmixAndResample(interleaved, frames: frames, from: 48_000, to: 16_000)

        let inputMono = Self.monoFromInterleaved(interleaved, frames: frames)
        let inputRMS = Self.rms(inputMono)
        let outputRMS = Self.rms(result)

        XCTAssertGreaterThan(outputRMS, inputRMS * 0.9, "output RMS dropped more than 10%")
        XCTAssertLessThan(outputRMS, inputRMS * 1.1, "output RMS grew more than 10%")
    }

    @available(macOS 14.2, *)
    func testDownmixAndResample_silence_producesSilence() {
        let frames = 4_800
        let interleaved = [Float](repeating: 0, count: frames * 2)

        let result = SystemAudioTapRecorder.downmixAndResample(interleaved, frames: frames, from: 48_000, to: 16_000)

        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy { $0 == 0 })
    }

    @available(macOS 14.2, *)
    func testDownmixAndResample_sameRate_skipsResampleButStillDownmixes() {
        let frames = 100
        let interleaved = Self.stereoSine(frames: frames, frequency: 220, sampleRate: 16_000, amplitude: 0.3)

        let result = SystemAudioTapRecorder.downmixAndResample(interleaved, frames: frames, from: 16_000, to: 16_000)

        XCTAssertEqual(result.count, frames)
        XCTAssertEqual(result, Self.monoFromInterleaved(interleaved, frames: frames))
    }

    func testStereoToMonoResampler_fourChannelInput_averagesAllChannels() {
        // Any channel count, not just stereo — a real tap format query
        // could report more than 2 channels.
        let frames = 10
        var interleaved = [Float](repeating: 0, count: frames * 4)
        for frame in 0..<frames {
            interleaved[frame * 4 + 0] = 1.0
            interleaved[frame * 4 + 1] = 0.0
            interleaved[frame * 4 + 2] = 0.0
            interleaved[frame * 4 + 3] = 1.0
        }
        let format = StereoToMonoResampler.InputFormat(sampleRate: 16_000, channelCount: 4)
        guard let resampler = StereoToMonoResampler(inputFormat: format, targetSampleRate: 16_000) else {
            return XCTFail("failed to build resampler")
        }

        let result = resampler.process(interleaved, frames: frames)

        XCTAssertEqual(result.count, frames)
        XCTAssertTrue(result.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    // MARK: - Persistent converter (chunked streaming vs. fresh-per-call)

    @available(macOS 14.2, *)
    func testStereoToMonoResampler_chunked512_matchesLengthAndClickToleranceOfSingleShot() {
        assertChunkedResamplingWithinTolerance(chunkFrames: 512)
    }

    @available(macOS 14.2, *)
    func testStereoToMonoResampler_chunked1024_matchesLengthAndClickToleranceOfSingleShot() {
        assertChunkedResamplingWithinTolerance(chunkFrames: 1024)
    }

    @available(macOS 14.2, *)
    private func assertChunkedResamplingWithinTolerance(chunkFrames: Int, file: StaticString = #filePath, line: UInt = #line) {
        let totalFrames = 48_000 * 2 // 2s continuous signal
        let interleaved = Self.stereoSine(frames: totalFrames, frequency: 440, sampleRate: 48_000, amplitude: 0.5)

        // Single-shot baseline: one resampler, one process() call.
        let baseline = SystemAudioTapRecorder.downmixAndResample(interleaved, frames: totalFrames, from: 48_000, to: 16_000)
        let baselineMaxJump = Self.maxAdjacentJump(baseline)

        // Chunked: one persistent resampler, fed in consecutive chunks —
        // this is the pattern the real IO proc callback uses. Flushed once
        // at the end, the same way SystemAudioTapRecorder.stop() flushes
        // its resampler.
        let format = StereoToMonoResampler.InputFormat(sampleRate: 48_000, channelCount: 2)
        guard let resampler = StereoToMonoResampler(inputFormat: format, targetSampleRate: 16_000) else {
            return XCTFail("failed to build resampler", file: file, line: line)
        }
        var chunked: [Float] = []
        var frame = 0
        while frame < totalFrames {
            let framesInChunk = min(chunkFrames, totalFrames - frame)
            let slice = Array(interleaved[(frame * 2)..<((frame + framesInChunk) * 2)])
            chunked.append(contentsOf: resampler.process(slice, frames: framesInChunk))
            frame += framesInChunk
        }
        chunked.append(contentsOf: resampler.flush())
        let chunkedMaxJump = Self.maxAdjacentJump(chunked)

        let expectedCount = totalFrames / 3
        XCTAssertLessThanOrEqual(abs(chunked.count - expectedCount), 2,
                                  "expected ~\(expectedCount) frames, got \(chunked.count)", file: file, line: line)
        XCTAssertLessThanOrEqual(chunkedMaxJump, baselineMaxJump * 1.2,
                                  "chunked maxJump \(chunkedMaxJump) exceeded 1.2x single-shot baseline \(baselineMaxJump)",
                                  file: file, line: line)
    }

    // MARK: - Error mapping

    func testSystemAudioCaptureError_unavailable_carriesStatusAndStage() {
        let error = SystemAudioCaptureError.unavailable(osStatus: -50, stage: "AudioDeviceStart")
        guard case let .unavailable(status, stage) = error else {
            return XCTFail("expected .unavailable")
        }
        XCTAssertEqual(status, -50)
        XCTAssertEqual(stage, "AudioDeviceStart")
        XCTAssertTrue(error.errorDescription?.contains("AudioDeviceStart") ?? false)
    }

    func testSystemAudioCaptureError_permissionDenied_hasDescription() {
        let error = SystemAudioCaptureError.permissionDenied
        XCTAssertNotNil(error.errorDescription)
    }

    func testSystemAudioCaptureError_alreadyRunning_hasDescription() {
        let error = SystemAudioCaptureError.alreadyRunning
        XCTAssertNotNil(error.errorDescription)
    }

    func testMapIOProcError_permissionsError_mapsToPermissionDenied() {
        let error = SystemAudioCaptureError.mapIOProcError(kAudioDevicePermissionsError)

        guard case .permissionDenied = error else {
            return XCTFail("expected .permissionDenied, got \(error)")
        }
    }

    func testMapIOProcError_otherStatus_mapsToUnavailableWithCreateIOProcStage() {
        let error = SystemAudioCaptureError.mapIOProcError(-50)

        guard case let .unavailable(status, stage) = error else {
            return XCTFail("expected .unavailable, got \(error)")
        }
        XCTAssertEqual(status, -50)
        XCTAssertEqual(stage, "createIOProc")
    }

    // MARK: - Reentrant stop() / start()-stop() race (real class, no tap opened)

    // Instantiating SystemAudioTapRecorder and calling stop()/the testing
    // seam never touches CoreAudio — only start() does. This exercises the
    // real stop() dispatch logic directly.

    @available(macOS 14.2, *)
    func testStop_calledFromDeliveryQueue_doesNotDeadlock() {
        let recorder = SystemAudioTapRecorder()
        let completed = expectation(description: "reentrant stop() returned")

        recorder.runOnDeliveryQueueForTesting {
            recorder.stop() // would deadlock pre-fix: sync onto the queue it's already on
            completed.fulfill()
        }

        wait(for: [completed], timeout: 3.0)
    }

    @available(macOS 14.2, *)
    func testStop_calledFromOutsideDeliveryQueue_returnsWithoutDeadlock() {
        // Not running, no reentrancy — should just be a fast no-op.
        let recorder = SystemAudioTapRecorder()
        recorder.stop()
    }

    @available(macOS 14.2, *)
    func testShouldCommitStart_stopRequestedFlag() {
        // Pure decision behind the start()/stop() race fix. The full race
        // (a real stop() landing mid-setup, inside performBlockingSetupAndStart)
        // needs a real tap to exercise end-to-end, so this locks just the
        // flag semantics instead — documented, not integration-tested.
        XCTAssertTrue(SystemAudioTapRecorder.shouldCommitStart(stopRequested: false))
        XCTAssertFalse(SystemAudioTapRecorder.shouldCommitStart(stopRequested: true))
    }

    // MARK: - start/stop idempotency (via fake — no test may open a real tap)

    func testFakeCapture_startThenStop_marksRunningThenNotRunning() async throws {
        let fake = FakeSystemAudioCapture()
        XCTAssertFalse(fake.isRunning)

        try await fake.start()
        XCTAssertTrue(fake.isRunning)
        XCTAssertEqual(fake.startCallCount, 1)

        fake.stop()
        XCTAssertFalse(fake.isRunning)
        XCTAssertEqual(fake.stopCallCount, 1)
    }

    func testFakeCapture_stopWithoutStart_isSafeAndIdempotent() {
        let fake = FakeSystemAudioCapture()
        fake.stop()
        fake.stop()

        XCTAssertEqual(fake.stopCallCount, 2)
        XCTAssertFalse(fake.isRunning)
    }

    func testFakeCapture_repeatedStop_afterStart_isIdempotent() async throws {
        let fake = FakeSystemAudioCapture()
        try await fake.start()

        fake.stop()
        fake.stop()
        fake.stop()

        XCTAssertEqual(fake.stopCallCount, 3)
        XCTAssertFalse(fake.isRunning)
    }

    func testFakeCapture_startFailure_surfacesConfiguredError() async {
        let fake = FakeSystemAudioCapture()
        fake.errorToThrow = SystemAudioCaptureError.permissionDenied

        do {
            try await fake.start()
            XCTFail("expected permissionDenied to be thrown")
        } catch SystemAudioCaptureError.permissionDenied {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(fake.isRunning)
    }

    func testFakeCapture_feed_deliversSamplesThroughOnSamples() async throws {
        let fake = FakeSystemAudioCapture()
        var received: [Float]?
        fake.onSamples = { received = $0 }
        try await fake.start()

        fake.feed([0.1, 0.2, 0.3])

        XCTAssertEqual(received, [0.1, 0.2, 0.3])
    }

    // Atomicity contract (skeptic item 5): once stop() returns, no further
    // onSamples call may happen for that session.
    func testFakeCapture_feedAfterStop_doesNotInvokeOnSamples() async throws {
        let fake = FakeSystemAudioCapture()
        var callCount = 0
        fake.onSamples = { _ in callCount += 1 }
        try await fake.start()

        fake.feed([0.1])
        fake.stop()
        fake.feed([0.2])

        XCTAssertEqual(callCount, 1)
    }

    // MARK: - Synthetic signal helpers

    private static func stereoSine(frames: Int, frequency: Double, sampleRate: Double, amplitude: Float) -> [Float] {
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let value = amplitude * Float(sin(2.0 * Double.pi * frequency * t))
            samples[i * 2] = value
            samples[i * 2 + 1] = value
        }
        return samples
    }

    private static func monoFromInterleaved(_ interleaved: [Float], frames: Int) -> [Float] {
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            mono[i] = (interleaved[i * 2] + interleaved[i * 2 + 1]) * 0.5
        }
        return mono
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    /// Largest absolute difference between consecutive samples — a proxy
    /// for audible clicks at chunk/converter-reset boundaries.
    private static func maxAdjacentJump(_ samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0 }
        var maxJump: Float = 0
        for i in 1..<samples.count {
            maxJump = max(maxJump, abs(samples[i] - samples[i - 1]))
        }
        return maxJump
    }
}
