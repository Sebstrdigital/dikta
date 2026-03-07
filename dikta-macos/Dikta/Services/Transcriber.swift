import Foundation
import WhisperKit

/// Service for transcribing audio using WhisperKit
@MainActor
final class Transcriber: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?

    private var whisperKit: WhisperKit?
    private let modelName: String

    init(modelName: String = "small") {
        self.modelName = modelName
    }

    /// Load the Whisper model
    func loadModel() async {
        guard !isLoading && !isReady else { return }

        isLoading = true
        errorMessage = nil

        do {
            if let bundledPath = getBundledModelPath() {
                AppLogger.transcription.info("Loading bundled model from \(bundledPath)")
                let wk = try await WhisperKit(
                    modelFolder: bundledPath,
                    verbose: false,
                    prewarm: false,
                    load: false,
                    download: false
                )
                try await wk.loadModels()
                whisperKit = wk
            } else {
                AppLogger.transcription.info("Downloading model: \(self.modelName)")
                let wk = try await WhisperKit(
                    model: modelName,
                    verbose: false,
                    prewarm: false,
                    load: false,
                    download: true
                )
                try await wk.loadModels()
                whisperKit = wk
            }
            isReady = true
        } catch {
            errorMessage = "Failed to load Whisper model: \(error.localizedDescription)"
            AppLogger.transcription.error("Whisper model loading error: \(error.localizedDescription)")
        }

        isLoading = false
    }

    /// Check for a bundled model in the app's Resources
    private func getBundledModelPath() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let modelPath = "\(resourcePath)/WhisperModels/openai_whisper-\(modelName)"
        return FileManager.default.fileExists(atPath: modelPath) ? modelPath : nil
    }

    /// Transcribe audio samples
    /// - Parameters:
    ///   - audioSamples: Float32 audio samples at 16kHz
    ///   - language: Language code for transcription
    /// - Returns: Transcribed text
    func transcribe(_ audioSamples: [Float], language: String? = nil, micDistance: MicDistance = .normal) async throws -> String {
        guard let whisperKit = whisperKit else {
            throw TranscriberError.modelNotLoaded
        }

        guard !audioSamples.isEmpty else {
            throw TranscriberError.emptyAudio
        }

        let options = DecodingOptions(
            language: language,
            temperatureFallbackCount: 3,         // Retry with higher temp if failed
            compressionRatioThreshold: 3.0,      // Relaxed to avoid rejecting valid long-form segments
            logProbThreshold: micDistance.logProbThreshold,
            noSpeechThreshold: micDistance.noSpeechThreshold
        )

        AppLogger.transcription.debug("Using language: \(language ?? "auto"), samples: \(audioSamples.count)")

        let results = try await whisperKit.transcribe(audioArray: audioSamples, decodeOptions: options)

        // Log segment-level details for diagnostics
        let allSegments = results.flatMap { $0.segments }
        AppLogger.transcription.info("Transcription returned \(results.count) result(s), \(allSegments.count) segment(s) total")

        for (i, segment) in allSegments.enumerated() {
            let textPreview = segment.text.trimmingCharacters(in: .whitespaces)
            AppLogger.transcription.info(
                "Segment \(i): text=\"\(textPreview)\", avgLogprob=\(segment.avgLogprob), compressionRatio=\(segment.compressionRatio), noSpeechProb=\(segment.noSpeechProb)"
            )
        }

        // Keep only segments with non-empty text (filter out silence/empty segments)
        let validSegments = allSegments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }

        AppLogger.transcription.info("Valid segments: \(validSegments.count) of \(allSegments.count)")

        let text = validSegments.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        if text.isEmpty {
            throw TranscriberError.noSpeechDetected
        }

        return text
    }
}

enum TranscriberError: Error, LocalizedError {
    case modelNotLoaded
    case emptyAudio
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model not loaded"
        case .emptyAudio:
            return "No audio recorded"
        case .noSpeechDetected:
            return "No speech detected in recording"
        }
    }
}
