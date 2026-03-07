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

    // Silence auto-stop
    /// Called on the main thread when 10 continuous seconds of silence triggers auto-stop.
    /// Receives the captured audio samples for processing.
    var onSilenceAutoStop: (([Float]) -> Void)?

    private var silenceStartDate: Date?
    private let silenceAutoStopThreshold: TimeInterval = 10.0
    /// RMS energy below this level is considered silence (set per-recording based on MicDistance)
    private var silenceRMSThreshold: Float = 0.005

    /// Target sample rate for Whisper (16kHz)
    static let sampleRate: Double = 16000

    /// Maximum audio buffer size: 5 minutes at 16kHz (4,800,000 samples).
    /// When reached the captured audio is sent for processing immediately.
    static let maxBufferSamples: Int = 4_800_000

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
    /// - Parameter micDistance: The current mic distance preset, used to set the silence RMS threshold.
    func startRecording(micDistance: MicDistance = .normal) async throws {
        guard !isRecording else { return }

        silenceRMSThreshold = micDistance.silenceRMSThreshold

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
            AppLogger.audio.error("AVAudioConverter.convert() failed: \(error.localizedDescription)")
            return
        }

        if let channelData = outputBuffer.floatChannelData {
            let frameLength = Int(outputBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

            bufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            let captured = audioBuffer
            let bufferFull = audioBuffer.count >= Self.maxBufferSamples
            bufferLock.unlock()

            // Hard buffer limit: 5 minutes at 16kHz — trigger processing immediately
            if bufferFull {
                silenceStartDate = nil
                let callback = onSilenceAutoStop
                DispatchQueue.main.async {
                    callback?(captured)
                }
                return
            }

            // Silence detection: compute RMS of this buffer chunk
            checkSilenceAutoStop(samples: samples, captured: captured)
        }
    }

    private func checkSilenceAutoStop(samples: [Float], captured: [Float]) {
        guard !samples.isEmpty else { return }

        // RMS energy of this chunk
        let sumOfSquares = samples.reduce(0.0) { $0 + $1 * $1 }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()

        let now = Date()
        if rms < silenceRMSThreshold {
            if silenceStartDate == nil {
                silenceStartDate = now
            } else if let start = silenceStartDate,
                      now.timeIntervalSince(start) >= silenceAutoStopThreshold {
                // Silence threshold exceeded — trim trailing silence and trigger auto-stop
                let silenceSamples = Int(now.timeIntervalSince(start) * Self.sampleRate)
                let trimmedEnd = max(0, captured.count - silenceSamples)
                let trimmed = trimmedEnd > 0 ? Array(captured[..<trimmedEnd]) : captured

                silenceStartDate = nil
                let callback = onSilenceAutoStop
                DispatchQueue.main.async {
                    callback?(trimmed)
                }
            }
        } else {
            // Speech detected — reset silence timer
            silenceStartDate = nil
        }
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
