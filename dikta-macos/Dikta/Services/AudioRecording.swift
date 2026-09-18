import Foundation

/// The microphone-capture surface `MenuBarViewModel` uses.
///
/// Extracted so a unit test can drive the whole recording state machine —
/// start, live tap, stop, the diagnostic counters — without an `AVAudioEngine`,
/// a microphone, or an `AVCaptureDevice.requestAccess` prompt. Production is
/// unchanged: `AudioRecorder` conforms as-is (every member below already
/// existed with exactly this signature), and `MenuBarViewModel` still defaults
/// to a real `AudioRecorder()`.
///
/// Class-bound because a recorder is shared, mutable state with an identity:
/// the ViewModel sets `onLiveSamples` on it from one place and the audio
/// callback thread reads it from another. A value type would copy.
protocol AudioRecording: AnyObject {
    // MARK: Per-recording configuration

    /// See `AudioRecorder.silenceAutoStopEnabled`.
    var silenceAutoStopEnabled: Bool { get set }

    /// See `AudioRecorder.maxBufferSamples`.
    var maxBufferSamples: Int { get set }

    /// See `AudioRecorder.accumulateInMemory`.
    var accumulateInMemory: Bool { get set }

    // MARK: Callbacks

    /// See `AudioRecorder.onLiveSamples`. Called on the capture thread while
    /// the recorder's buffer lock is held; must not block.
    var onLiveSamples: (([Float]) -> Void)? { get set }

    /// See `AudioRecorder.onSilenceAutoStop`. Called on the main thread.
    var onSilenceAutoStop: (([Float]) -> Void)? { get set }

    // MARK: Lifecycle

    /// True between a successful `startRecording` and `stopRecording`.
    var recording: Bool { get }

    /// Opens the microphone. `AudioRecorder` supplies a `.normal` default for
    /// `micSensitivity`; a protocol requirement cannot carry a default value,
    /// and every call site in `MenuBarViewModel` passes one explicitly anyway.
    func startRecording(micSensitivity: MicSensitivity) async throws

    /// Closes the microphone and returns whatever was accumulated in RAM
    /// (empty when `accumulateInMemory` was false). A no-op when not recording.
    @discardableResult
    func stopRecording() -> [Float]

    // MARK: Diagnostics

    /// Hardware input rate of the last recording, for the `START` log line.
    var inputSampleRate: Double { get }

    /// Counters read by the `AUDIO` diagnostic line after a recording ends.
    var routeChangeCount: Int { get }
    var converterErrorCount: Int { get }
    var emptyBufferCount: Int { get }
}

/// The real recorder already has every member of `AudioRecording`, so this is
/// a declaration of conformance only — no behavior is added or changed.
extension AudioRecorder: AudioRecording {}
