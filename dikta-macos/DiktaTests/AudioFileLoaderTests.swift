import XCTest
import AVFoundation
@testable import Dikta

final class AudioFileLoaderTests: XCTestCase {
    private var tempDir: URL!
    private let loader = AudioFileLoader()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Helpers

    /// Writes a sine wave at `frequency` Hz, peak amplitude `amplitude`, to
    /// `url` using `settings` (an `AVAudioFile(forWriting:settings:)` PCM
    /// settings dictionary).
    private func writeSineWave(
        to url: URL,
        sampleRate: Double,
        channels: Int,
        durationSeconds: Double,
        frequency: Double = 440,
        amplitude: Float = 0.5,
        settings: [String: Any]
    ) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            XCTFail("Failed to allocate write buffer")
            return
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else {
            XCTFail("Expected float32 processing format for writing")
            return
        }

        for frame in 0..<Int(frameCount) {
            let value = amplitude * sinf(2.0 * Float.pi * Float(frequency) * Float(frame) / Float(sampleRate))
            for channel in 0..<channels {
                channelData[channel][frame] = value
            }
        }

        try file.write(from: buffer)
    }

    /// Writes a stereo file where the left and right channels have
    /// independent peak amplitudes (both at `frequency` Hz where nonzero).
    /// Used to verify that loading genuinely downmixes both channels
    /// rather than picking (or dropping) one of them.
    private func writeStereoSineWave(
        to url: URL,
        sampleRate: Double,
        durationSeconds: Double,
        frequency: Double = 440,
        leftAmplitude: Float,
        rightAmplitude: Float,
        settings: [String: Any]
    ) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            XCTFail("Failed to allocate write buffer")
            return
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else {
            XCTFail("Expected float32 processing format for writing")
            return
        }

        for frame in 0..<Int(frameCount) {
            let phase = 2.0 * Float.pi * Float(frequency) * Float(frame) / Float(sampleRate)
            channelData[0][frame] = leftAmplitude * sinf(phase)
            channelData[1][frame] = rightAmplitude * sinf(phase)
        }

        try file.write(from: buffer)
    }

    /// Writes a stereo file (identical L/R) where each frame's sample value
    /// comes from `sample(frame)`. Deliberately its own function (rather
    /// than inlined in the test body) so the writing `AVAudioFile` is
    /// deallocated — finalizing the file's header — before the caller
    /// reopens it for reading; reading a file whose writer is still in
    /// scope can observe a not-yet-finalized (zero) frame count.
    private func writeStereoSamples(
        to url: URL,
        frameCount: Int,
        settings: [String: Any],
        sample: (Int) -> Float
    ) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            XCTFail("Failed to allocate write buffer")
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = buffer.floatChannelData else {
            XCTFail("Expected float32 processing format for writing")
            return
        }

        for frame in 0..<frameCount {
            let value = sample(frame)
            channelData[0][frame] = value
            channelData[1][frame] = value
        }

        try file.write(from: buffer)
    }

    /// Writes a valid but zero-frame file, in its own function for the same
    /// writer-lifetime reason as `writeStereoSamples`.
    private func writeZeroFrameFile(to url: URL, settings: [String: Any]) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 0) else {
            XCTFail("Failed to allocate zero-length buffer")
            return
        }
        buffer.frameLength = 0
        try file.write(from: buffer)
    }

    private var linearPCM44kStereoInt16Settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    // MARK: - Stereo 44.1kHz Int16 WAV

    func testLoadSampleCountWithinOnePercentOf16kHz() throws {
        let url = tempDir.appendingPathComponent("stereo44k.wav")
        try writeSineWave(to: url, sampleRate: 44100, channels: 2, durationSeconds: 1.0, settings: linearPCM44kStereoInt16Settings)

        let samples = try loader.load(url: url)

        XCTAssertEqual(Double(samples.count), 16000, accuracy: 160) // ±1%
    }

    func testLoadPeakAmplitudeMatchesWrittenAmplitude() throws {
        let url = tempDir.appendingPathComponent("stereo44k-peak.wav")
        try writeSineWave(to: url, sampleRate: 44100, channels: 2, durationSeconds: 1.0, amplitude: 0.5, settings: linearPCM44kStereoInt16Settings)

        let samples = try loader.load(url: url)
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }

        XCTAssertEqual(peak, 0.5, accuracy: 0.05)
    }

    func testLoadDownmixesLeftSineRightSilentToHalfPeak() throws {
        let url = tempDir.appendingPathComponent("stereo44k-left-only.wav")
        try writeStereoSineWave(
            to: url, sampleRate: 44100, durationSeconds: 1.0,
            leftAmplitude: 0.5, rightAmplitude: 0.0,
            settings: linearPCM44kStereoInt16Settings
        )

        let samples = try loader.load(url: url)
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }

        // Average of (0.5, 0.0) is 0.25 — if downmixing merely dropped the
        // right channel, or dropped the left, this would read 0.5 or 0.0.
        XCTAssertEqual(peak, 0.25, accuracy: 0.02)
    }

    func testLoadDownmixesRightSineLeftSilentToHalfPeak() throws {
        let url = tempDir.appendingPathComponent("stereo44k-right-only.wav")
        try writeStereoSineWave(
            to: url, sampleRate: 44100, durationSeconds: 1.0,
            leftAmplitude: 0.0, rightAmplitude: 0.5,
            settings: linearPCM44kStereoInt16Settings
        )

        let samples = try loader.load(url: url)
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }

        XCTAssertEqual(peak, 0.25, accuracy: 0.02)
    }

    func testLoadHasNoSilentTail() throws {
        let url = tempDir.appendingPathComponent("stereo44k-tail.wav")
        try writeSineWave(to: url, sampleRate: 44100, channels: 2, durationSeconds: 1.0, settings: linearPCM44kStereoInt16Settings)

        let samples = try loader.load(url: url)
        let tail = samples.suffix(100)

        XCTAssertTrue(tail.contains { $0 != 0 }, "Expected the trailing 100 samples not to be all silence")
    }

    /// A periodic signal makes "not identical to the previous chunk" a weak
    /// check for tail duplication (a sine's period doesn't align with the
    /// chunk boundary, so two chunks are "different" even when replayed).
    /// Instead: sine for the first half of the file, silence for the
    /// second half. If the converter replayed the final buffer past
    /// end-of-stream, the tail would contain sine content instead of
    /// silence.
    func testLoadHasNoReplayedTailAfterSignalStops() throws {
        let url = tempDir.appendingPathComponent("stereo44k-half-silent.wav")
        let sampleRate = 44100.0
        let totalFrames = Int(sampleRate * 1.0)
        let signalFrames = Int(sampleRate * 0.5)

        try writeStereoSamples(to: url, frameCount: totalFrames, settings: linearPCM44kStereoInt16Settings) { frame in
            frame < signalFrames ? 0.5 * sinf(2.0 * Float.pi * 440 * Float(frame) / Float(sampleRate)) : 0
        }

        let samples = try loader.load(url: url)

        XCTAssertEqual(Double(samples.count), 16000, accuracy: 160) // ±1%

        let tail = samples.suffix(800)
        let tailPeak = tail.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertLessThan(tailPeak, 0.01, "Expected the trailing 800 samples (after the signal stopped) to be silent, not a replayed sine tail")

        // The 0.2-0.3s window (samples 3200..<4800 at 16kHz) is still
        // within the sine portion of the source — confirms the signal
        // wasn't lost entirely, only its (correctly silent) tail.
        let windowStart = Int(0.2 * AudioFileLoader.targetSampleRate)
        let windowEnd = Int(0.3 * AudioFileLoader.targetSampleRate)
        let window = samples[windowStart..<windowEnd]
        let windowPeak = window.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertGreaterThan(windowPeak, 0.4, "Expected signal to still be present in the 0.2-0.3s window")
    }

    // MARK: - Mono 48kHz Float32 CAF

    func testLoadMono48kFloat32Caf() throws {
        let url = tempDir.appendingPathComponent("mono48k.caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try writeSineWave(to: url, sampleRate: 48000, channels: 1, durationSeconds: 1.0, settings: settings)

        let samples = try loader.load(url: url)

        XCTAssertEqual(Double(samples.count), 16000, accuracy: 160)
    }

    // MARK: - AAC .m4a

    func testLoadM4aIfAacEncodingIsAvailable() throws {
        let url = tempDir.appendingPathComponent("test.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
        ]

        do {
            try writeSineWave(to: url, sampleRate: 44100, channels: 1, durationSeconds: 1.0, settings: settings)
        } catch {
            throw XCTSkip("AAC encoding unavailable in this test environment: \(error)")
        }

        let samples = try loader.load(url: url)
        XCTAssertGreaterThan(samples.count, 0)
    }

    // MARK: - Errors

    func testLoadThrowsForMissingFile() {
        let url = tempDir.appendingPathComponent("does-not-exist.wav")
        XCTAssertThrowsError(try loader.load(url: url)) { error in
            guard case AudioFileLoaderError.unreadable = error else {
                XCTFail("Expected .unreadable, got \(error)")
                return
            }
        }
    }

    func testLoadThrowsUnsupportedFormatForUnsupportedExtension() throws {
        let url = tempDir.appendingPathComponent("not-audio.txt")
        try "not audio".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try loader.load(url: url)) { error in
            guard case AudioFileLoaderError.unsupportedFormat = error else {
                XCTFail("Expected .unsupportedFormat, got \(error)")
                return
            }
        }
    }

    func testLoadThrowsEmptyForZeroFrameFile() throws {
        let url = tempDir.appendingPathComponent("empty.wav")
        try writeZeroFrameFile(to: url, settings: linearPCM44kStereoInt16Settings)

        XCTAssertThrowsError(try loader.load(url: url)) { error in
            guard case AudioFileLoaderError.empty = error else {
                XCTFail("Expected .empty, got \(error)")
                return
            }
        }
    }

    // MARK: - Duration

    func testDurationMatchesWrittenLength() throws {
        let url = tempDir.appendingPathComponent("duration.wav")
        try writeSineWave(to: url, sampleRate: 44100, channels: 1, durationSeconds: 2.0, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])

        let duration = try loader.duration(url: url)

        XCTAssertEqual(duration, 2.0, accuracy: 0.05)
    }

    func testDurationThrowsForMissingFile() {
        let url = tempDir.appendingPathComponent("missing.wav")
        XCTAssertThrowsError(try loader.duration(url: url))
    }
}
