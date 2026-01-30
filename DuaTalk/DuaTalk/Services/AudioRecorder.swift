import Foundation
import AVFoundation

/// Service for recording audio from the microphone
final class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var isRecording = false

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

        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw AudioRecorderError.engineCreationFailed
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer, converter: converter, outputFormat: outputFormat)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
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

    var errorDescription: String? {
        switch self {
        case .engineCreationFailed:
            return "Failed to create audio engine"
        case .formatCreationFailed:
            return "Failed to create audio format"
        case .converterCreationFailed:
            return "Failed to create audio converter"
        }
    }
}
