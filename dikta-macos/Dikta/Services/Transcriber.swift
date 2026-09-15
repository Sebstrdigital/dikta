import Foundation
import WhisperKit

/// A segment's text and no-speech confidence, decoupled from WhisperKit's own
/// `TranscriptionSegment` type so `Transcriber.cleanSegments` can be unit tested
/// without linking WhisperKit.
struct TranscriptSegment {
    let text: String
    let noSpeechProb: Float
}

/// Service for transcribing audio using WhisperKit.
///
/// Conforms to `TranscriptionEngine` so `MenuBarViewModel` depends on that protocol
/// rather than on WhisperKit directly.
@MainActor
final class Transcriber: ObservableObject, TranscriptionEngine {
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?

    private var whisperKit: WhisperKit?
    private var model: WhisperModel

    init(model: WhisperModel) {
        self.model = model
    }

    /// Load the currently configured model. No-op if already loading or ready.
    func load() async {
        guard !isLoading && !isReady else { return }
        await loadModel(model)
    }

    /// Unload the current model (if any) and load `model` in its place, so the
    /// active model can be switched without an app restart.
    func reload(model: WhisperModel) async throws {
        guard !isLoading else { return }

        whisperKit = nil
        isReady = false
        self.model = model

        await loadModel(model)

        guard isReady else {
            throw TranscriberError.reloadFailed(errorMessage ?? "Failed to load Whisper model")
        }
    }

    /// Load `model`, preferring a bundled copy over downloading one.
    private func loadModel(_ model: WhisperModel) async {
        isLoading = true
        errorMessage = nil

        do {
            if let bundledPath = getBundledModelPath(for: model) {
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
                AppLogger.transcription.info("Downloading model: \(model.variant) from \(model.repo)")
                let wk = try await WhisperKit(
                    model: model.variant,
                    modelRepo: model.repo,
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

    /// Check for a bundled model in the app's Resources. Uses the same fully
    /// qualified variant string (e.g. "openai_whisper-small") as the download
    /// path, so the two never disagree about which model they mean.
    private func getBundledModelPath(for model: WhisperModel) -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let modelPath = "\(resourcePath)/WhisperModels/\(model.variant)"
        return FileManager.default.fileExists(atPath: modelPath) ? modelPath : nil
    }

    /// Transcribe audio samples
    /// - Parameters:
    ///   - audioSamples: Float32 audio samples at 16kHz
    ///   - language: Language code for transcription
    /// - Returns: Transcribed text
    func transcribe(_ audioSamples: [Float], language: String? = nil, micSensitivity: MicSensitivity = .normal) async throws -> String {
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
            logProbThreshold: micSensitivity.logProbThreshold,
            noSpeechThreshold: micSensitivity.noSpeechThreshold
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

        // Diagnostic file log: one compact line with per-segment scores and text
        let noSpeechProbs = allSegments.map { String(format: "%.2f", $0.noSpeechProb) }.joined(separator: ",")
        let logProbs = allSegments.map { String(format: "%.1f", $0.avgLogprob) }.joined(separator: ",")
        let segTexts = allSegments.map { "\"\($0.text.trimmingCharacters(in: .whitespaces))\"" }.joined(separator: ",")

        let text = Self.cleanSegments(
            allSegments.map { TranscriptSegment(text: $0.text, noSpeechProb: $0.noSpeechProb) },
            noSpeechThreshold: micSensitivity.noSpeechThreshold
        )

        DiagnosticLogger.shared.log("WHISPER | segs=\(allSegments.count) | noSpeech=[\(noSpeechProbs)] | logProb=[\(logProbs)] | texts=[\(segTexts)]")
        DiagnosticLogger.shared.log("WHISPER_CLEAN | text=\"\(text)\"")

        if text.isEmpty {
            throw TranscriberError.noSpeechDetected
        }

        return text
    }

    /// Strip Whisper control tokens and bracket noise tokens, drop empty/whitespace
    /// segments and segments Whisper itself flagged as likely silence (`noSpeechProb`
    /// at or above `noSpeechThreshold`), and join what remains into one string.
    ///
    /// Pure function — no WhisperKit dependency — so it can be unit tested directly.
    static func cleanSegments(_ segments: [TranscriptSegment], noSpeechThreshold: Float) -> String {
        let validSegments = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.noSpeechProb < noSpeechThreshold
        }

        return validSegments.map { segment in
            // Strip Whisper control tokens (e.g. <|startoftranscript|>, <|en|>, <|0.00|>, <|endoftext|>)
            // Also strip bracket noise tokens (e.g. [BLANK_AUDIO], [ Silence ], [silence], [no speech])
            // These represent trailing silence appended by Whisper and must not trigger a no_speech discard.
            segment.text
                .replacingOccurrences(of: "<\\|[^|]+\\|>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\[\\s*(?:BLANK_AUDIO|silence|no speech)\\s*\\]", with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum TranscriberError: Error, LocalizedError {
    case modelNotLoaded
    case emptyAudio
    case noSpeechDetected
    case reloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model not loaded"
        case .emptyAudio:
            return "No audio recorded"
        case .noSpeechDetected:
            return "No speech detected in recording"
        case .reloadFailed(let message):
            return message
        }
    }
}
