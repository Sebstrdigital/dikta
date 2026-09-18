import Foundation
import AVFoundation

/// Service for recording audio from the microphone
final class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var isRecording = false
    private var configObserver: NSObjectProtocol?

    // Diagnostic counters (read after stopRecording)
    private(set) var inputSampleRate: Double = 0
    private(set) var routeChangeCount: Int = 0
    private(set) var converterErrorCount: Int = 0
    private(set) var emptyBufferCount: Int = 0

    // Silence auto-stop
    /// Called on the main thread when 10 continuous seconds of silence triggers auto-stop.
    /// Receives the captured audio samples for processing.
    var onSilenceAutoStop: (([Float]) -> Void)?

    /// Set to false to disable silence auto-stop entirely for the next
    /// recording (debrief mode records until the user stops it manually).
    /// Defaults to true, which is the normal dictation behaviour.
    var silenceAutoStopEnabled: Bool = true

    /// Optional live tap: called with every converted 16 kHz mono chunk as it
    /// arrives, from the same place (and on the same thread) that the RAM
    /// buffer is appended to — the AVAudioEngine tap callback, which is
    /// serialized by the engine, so a consumer never sees two chunks at once.
    ///
    /// Call recording uses this to stream the mic track to disk. The call is
    /// made while `bufferLock` is held, and `stopRecording()` clears this
    /// property under the same lock *after* removing the tap: together that
    /// guarantees no invocation is in flight or can begin once
    /// `stopRecording()` has returned, so the owner can safely tear down
    /// whatever the tap was feeding. Nil (the default) leaves the hot path
    /// untouched.
    ///
    /// **The closure must not block.** It runs on an audio callback thread
    /// *and* holds `bufferLock`, so any disk I/O, `fsync`, network call or
    /// lock wait inside it stalls capture and delays `stopRecording()`.
    /// Copy the buffer and hand it to your own queue — that is what
    /// `MenuBarViewModel.CallRecordingSession` does.
    ///
    /// Set it before `startRecording()`, from the owner's own thread — same
    /// contract as `onSilenceAutoStop`.
    var onLiveSamples: (([Float]) -> Void)?

    /// When false, converted samples are *not* accumulated in the in-RAM
    /// capture buffer (and the `maxBufferSamples` cap, which only guards that
    /// buffer, never fires). `stopRecording()` then returns an empty array.
    ///
    /// Call recording sets this: a two-hour call streams to disk through
    /// `onLiveSamples` and must not also be held in RAM. Every other path
    /// leaves it true, which is the behaviour the recorder has always had.
    var accumulateInMemory: Bool = true

    private var silenceStartDate: Date?
    private let silenceAutoStopThreshold: TimeInterval = 10.0
    /// RMS energy below this level is considered silence (set per-recording based on MicSensitivity)
    private var silenceRMSThreshold: Float = 0.005

    /// Target sample rate for Whisper (16kHz)
    static let sampleRate: Double = 16000

    /// Default maximum audio buffer size: 5 minutes at 16kHz (4,800,000 samples).
    /// When reached the captured audio is sent for processing immediately.
    static let defaultMaxBufferSamples: Int = 4_800_000

    /// Effective cap for the next recording. Debrief mode raises this so a
    /// multi-minute debrief isn't cut short; normal dictation leaves it at
    /// `defaultMaxBufferSamples`.
    var maxBufferSamples: Int = AudioRecorder.defaultMaxBufferSamples

    /// Check if microphone permission is granted
    static func checkPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Retry delays for Bluetooth HFP profile switching (300ms, 500ms, 800ms)
    private static let retryDelaysNs: [UInt64] = [300_000_000, 500_000_000, 800_000_000]

    /// Start recording audio
    /// - Parameter micSensitivity: The current mic sensitivity preset, used to set the silence RMS threshold.
    func startRecording(micSensitivity: MicSensitivity = .normal) async throws {
        guard !isRecording else { return }

        silenceRMSThreshold = micSensitivity.silenceRMSThreshold

        // Reset diagnostic counters
        routeChangeCount = 0
        converterErrorCount = 0
        emptyBufferCount = 0

        var engine = AVAudioEngine()
        var inputFormat = engine.inputNode.outputFormat(forBus: 0)

        // Retry with increasing delays if sample rate is 0 (e.g. Bluetooth HFP profile switching for AirPods)
        if inputFormat.sampleRate == 0 {
            AppLogger.audio.info("Input format has 0 sample rate, waiting for audio route to settle...")
            engine.stop()

            var settled = false
            for (attempt, delay) in Self.retryDelaysNs.enumerated() {
                try? await Task.sleep(nanoseconds: delay)
                engine = AVAudioEngine()
                inputFormat = engine.inputNode.outputFormat(forBus: 0)
                if inputFormat.sampleRate > 0 {
                    AppLogger.audio.info("Audio route settled after retry \(attempt + 1)")
                    settled = true
                    break
                }
                AppLogger.audio.warning("Retry \(attempt + 1)/\(Self.retryDelaysNs.count): still 0 sample rate, waiting \(delay / 1_000_000)ms...")
                engine.stop()
            }

            guard settled else {
                throw AudioRecorderError.noInputDevice
            }
        }

        self.audioEngine = engine
        self.inputSampleRate = inputFormat.sampleRate
        try startRecordingWithEngine(engine, inputFormat: inputFormat)
    }

    private func startRecordingWithEngine(_ engine: AVAudioEngine, inputFormat: AVAudioFormat) throws {
        // Target format: 16kHz mono Float32
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.formatCreationFailed
        }

        // Create converter for sample rate conversion (stored as instance property to avoid closure capture leak)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }
        self.audioConverter = converter

        // Clear buffer and silence state
        silenceStartDate = nil
        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()

        // Install tap on input node
        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.bufferLock.lock()
            let converter = self.audioConverter
            self.bufferLock.unlock()
            guard let converter else { return }
            self.processBuffer(buffer, converter: converter, outputFormat: outputFormat)
        }

        engine.prepare()
        try engine.start()
        isRecording = true

        // Observe audio configuration changes during recording (e.g. Bluetooth route changes)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            AppLogger.audio.warning("AudioRecorder engine config changed during recording — recreating converter")

            let newInputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard newInputFormat.sampleRate > 0 else {
                AppLogger.audio.error("New input format has 0 sample rate after config change, cannot recreate converter")
                return
            }

            guard let newConverter = AVAudioConverter(from: newInputFormat, to: outputFormat) else {
                AppLogger.audio.error("Failed to recreate AVAudioConverter after config change")
                return
            }
            self.bufferLock.lock()
            self.audioConverter = newConverter
            self.bufferLock.unlock()
            self.routeChangeCount += 1
            DiagnosticLogger.shared.log("ROUTE_CHANGE | newRate=\(newInputFormat.sampleRate)Hz | changeCount=\(self.routeChangeCount)")
            AppLogger.audio.info("AVAudioConverter recreated with new input format: \(newInputFormat.sampleRate)Hz")
        }
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        // Calculate output frame capacity
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error {
            converterErrorCount += 1
            AppLogger.audio.error("AVAudioConverter.convert() failed: \(error.localizedDescription)")
            return
        }

        if outputBuffer.frameLength == 0 {
            emptyBufferCount += 1
            return
        }

        if let channelData = outputBuffer.floatChannelData {
            let frameLength = Int(outputBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

            // Live tap first, under the lock (see `onLiveSamples`), so a
            // consumer writing to disk is ordered against `stopRecording()`.
            bufferLock.lock()
            onLiveSamples?(samples)
            bufferLock.unlock()

            // Call recording streams to disk instead of buffering in RAM;
            // with no capture buffer there is also nothing for the
            // `maxBufferSamples` cap (a RAM guard) to protect, and the
            // silence bookkeeping below has no buffer to trim.
            guard accumulateInMemory else { return }

            bufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            let bufferFull = audioBuffer.count >= maxBufferSamples
            bufferLock.unlock()

            // Hard buffer limit — trigger processing immediately
            if bufferFull {
                silenceStartDate = nil
                let captured = snapshotBuffer()
                let callback = onSilenceAutoStop
                DispatchQueue.main.async {
                    callback?(captured)
                }
                return
            }

            // Silence detection. This guard sits above everything that touches
            // the capture buffer: debrief mode records for up to two hours and
            // must not pay for bookkeeping it has switched off.
            guard silenceAutoStopEnabled else { return }

            guard let trimCount = silenceAutoStopTrimCount(samples: samples) else { return }

            // Only now — on the one callback that actually fires auto-stop — is
            // the capture buffer read.
            let captured = snapshotBuffer()
            let trimmedEnd = max(0, captured.count - trimCount)
            let trimmed = trimmedEnd > 0 ? Array(captured[..<trimmedEnd]) : captured
            let callback = onSilenceAutoStop
            DispatchQueue.main.async {
                callback?(trimmed)
            }
        }
    }

    private func snapshotBuffer() -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return audioBuffer
    }

    /// Updates silence bookkeeping with the newest chunk and returns how many
    /// trailing samples to trim when auto-stop should fire now, or nil when it
    /// shouldn't.
    ///
    /// Takes only the new chunk, never the capture buffer. Binding the capture
    /// buffer to a local on every tap callback is cheap on its own (Swift
    /// arrays are copy-on-write, and a binding that dies inside the callback
    /// never breaks uniqueness) but it escaped into the auto-stop callback,
    /// which makes the *next* `append` copy the entire buffer — 460 MB at the
    /// debrief cap. Deciding first and snapshotting only when firing keeps the
    /// hot path free of the buffer entirely.
    ///
    /// Internal so it can be unit-tested without a microphone.
    func silenceAutoStopTrimCount(samples: [Float], now: Date = Date()) -> Int? {
        guard !samples.isEmpty else { return nil }

        // RMS energy of this chunk
        let sumOfSquares = samples.reduce(0.0) { $0 + $1 * $1 }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()

        guard rms < silenceRMSThreshold else {
            // Speech detected — reset silence timer
            silenceStartDate = nil
            return nil
        }

        guard let start = silenceStartDate else {
            silenceStartDate = now
            return nil
        }

        let silentFor = now.timeIntervalSince(start)
        guard silentFor >= silenceAutoStopThreshold else { return nil }

        silenceStartDate = nil
        return Int(silentFor * Self.sampleRate)
    }

    /// Stop recording and return the audio buffer
    func stopRecording() -> [Float] {
        guard isRecording else { return [] }

        // Reset silence detection state
        silenceStartDate = nil

        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false

        bufferLock.lock()
        audioConverter = nil
        // Cleared under the same lock the tap callback holds while invoking
        // it, and only after the tap was removed above: once this unlock
        // happens no further live-sample call can start, and any in-flight
        // one has already finished — so the owner may close its writer.
        onLiveSamples = nil
        let result = audioBuffer
        audioBuffer.removeAll()
        bufferLock.unlock()

        return result
    }

    /// Check if currently recording
    var recording: Bool {
        isRecording
    }
}

enum AudioRecorderError: Error, LocalizedError {
    case engineCreationFailed
    case formatCreationFailed
    case converterCreationFailed
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .engineCreationFailed:
            return "Failed to create audio engine"
        case .formatCreationFailed:
            return "Failed to create audio format"
        case .converterCreationFailed:
            return "Failed to create audio converter"
        case .noInputDevice:
            return "No audio input device available"
        }
    }
}
