import Foundation
import WhisperKit

/// Service for transcribing audio using WhisperKit
@MainActor
final class Transcriber: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published private(set) var loadingProgress: Double = 0
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
        loadingProgress = 0
        errorMessage = nil

        do {
            if let bundledPath = getBundledModelPath() {
                AppLogger.transcription.info("Loading bundled model from \(bundledPath)")
                whisperKit = try await WhisperKit(
                    modelFolder: bundledPath,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: false
                )
            } else {
                AppLogger.transcription.info("Downloading model: \(self.modelName)")
                whisperKit = try await WhisperKit(
                    model: modelName,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: true
                )
            }
            isReady = true
            loadingProgress = 1.0
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
    func transcribe(_ audioSamples: [Float], language: String? = nil) async throws -> String {
        guard let whisperKit = whisperKit else {
            throw TranscriberError.modelNotLoaded
        }

        guard !audioSamples.isEmpty else {
            throw TranscriberError.emptyAudio
        }

        let options = DecodingOptions(
            language: language,
            temperatureFallbackCount: 3,         // Retry with higher temp if failed
            compressionRatioThreshold: 2.4,      // Detect repetitive hallucinations
            logProbThreshold: -1.0,              // Filter low-confidence output
            noSpeechThreshold: 0.6               // Detect silence/no speech
        )

        AppLogger.transcription.debug("Using language: \(language ?? "auto"), samples: \(audioSamples.count)")

        let result = try await whisperKit.transcribe(audioArray: audioSamples, decodeOptions: options)

        AppLogger.transcription.debug("Got \(result.count) segments")

        // Combine all segments into a single string
        let text = result.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)

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
