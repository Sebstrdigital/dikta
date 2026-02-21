import Foundation
import AVFoundation

/// Service for recording audio from the microphone
final class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var isRecording = false
    private var configObserver: NSObjectProtocol?

    /// Target sample rate for Whisper (16kHz)
    static let sampleRate: Double = 16000

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

    /// Start recording audio
    func startRecording() throws {
        guard !isRecording else { return }

        var engine = AVAudioEngine()
        var inputFormat = engine.inputNode.outputFormat(forBus: 0)

        // Retry if sample rate is 0 (e.g. Bluetooth HFP profile switching for AirPods)
        if inputFormat.sampleRate == 0 {
            AppLogger.audio.info("Input format has 0 sample rate, waiting for audio route to settle...")
            engine.stop()
            Thread.sleep(forTimeInterval: 0.3)

            engine = AVAudioEngine()
            inputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0 else {
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

        // Create converter for sample rate conversion
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }

        // Clear buffer
        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()

        // Install tap on input node
        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer, converter: converter, outputFormat: outputFormat)
        }

        engine.prepare()
        try engine.start()
        isRecording = true

        // Observe audio configuration changes during recording (e.g. Bluetooth route changes)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            AppLogger.audio.warning("AudioRecorder engine config changed during recording")
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

        if error == nil, let channelData = outputBuffer.floatChannelData {
            let frameLength = Int(outputBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

            bufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            bufferLock.unlock()
        }
    }

    /// Stop recording and return the audio buffer
    func stopRecording() -> [Float] {
        guard isRecording else { return [] }

        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false

        bufferLock.lock()
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
