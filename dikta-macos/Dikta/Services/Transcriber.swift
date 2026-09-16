import Foundation
import WhisperKit

/// A segment's text, decoupled from WhisperKit's own `TranscriptionSegment` type
/// so `Transcriber.cleanSegments` can be unit tested without linking WhisperKit.
struct TranscriptSegment {
    let text: String
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
    @Published private(set) var downloadProgress: Double?

    private var whisperKit: WhisperKit?
    private var model: WhisperModel
    private let freeDiskSpaceProvider: () -> Int64

    /// Bumped at the start and end of every `loadModel` call. `progressCallback`
    /// hops to `@MainActor` asynchronously (it's invoked from WhisperKit's
    /// download machinery, possibly off-MainActor), so a hop queued just before
    /// `loadModel` finishes can otherwise land *after* the end-of-call
    /// `downloadProgress = nil` reset and resurrect a stale percentage on an
    /// already-finished (or already-superseded) load. Each hop captures the
    /// generation it was scheduled under and is a no-op unless it still matches.
    private var downloadGeneration = 0

    /// - Parameter freeDiskSpaceProvider: Returns bytes free on the volume that
    ///   will hold a downloaded model. Defaults to a real filesystem probe;
    ///   tests inject a fixed value to exercise the disk-space guard without
    ///   depending on the host machine's actual free space.
    init(model: WhisperModel, freeDiskSpaceProvider: @escaping () -> Int64 = Transcriber.defaultFreeDiskSpace) {
        self.model = model
        self.freeDiskSpaceProvider = freeDiskSpaceProvider
    }

    /// Load the currently configured model. No-op if already loading or ready.
    func load() async {
        guard !isLoading && !isReady else { return }
        await loadModel(model)
    }

    /// Unload the current model (if any) and load `model` in its place, so the
    /// active model can be switched without an app restart.
    func reload(model: WhisperModel) async throws {
        guard !isLoading else {
            throw TranscriberError.reloadInProgress
        }

        whisperKit = nil
        isReady = false
        self.model = model

        await loadModel(model)

        guard isReady else {
            throw TranscriberError.reloadFailed(errorMessage ?? "Failed to load Whisper model")
        }
    }

    /// Load `model`, preferring a bundled copy over downloading one. When a
    /// download is needed, `downloadProgress` is published from 0...1 for the
    /// duration; it stays nil for a bundled load, since nothing is downloaded.
    private func loadModel(_ model: WhisperModel) async {
        isLoading = true
        errorMessage = nil
        downloadGeneration += 1
        let generation = downloadGeneration
        downloadProgress = nil

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
                guard hasEnoughDiskSpace(for: model) else {
                    throw TranscriberError.insufficientDiskSpace(
                        model: model,
                        requiredMB: model.approximateSizeMB * 2
                    )
                }

                AppLogger.transcription.info("Downloading model: \(model.variant) from \(model.repo)")
                downloadProgress = 0

                // WhisperKit's convenience init (`download: true`) performs the
                // same download internally but exposes no progress hook, so we
                // call the underlying static download explicitly to observe
                // progress, then load the downloaded folder like a bundled model.
                let modelFolder = try await WhisperKit.download(
                    variant: model.variant,
                    from: model.repo,
                    progressCallback: { [weak self] progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in
                            guard let self, self.downloadGeneration == generation else { return }
                            self.downloadProgress = fraction
                        }
                    }
                )

                let wk = try await WhisperKit(
                    modelFolder: modelFolder.path,
                    verbose: false,
                    prewarm: false,
                    load: false,
                    download: false
                )
                try await wk.loadModels()
                whisperKit = wk
            }
            isReady = true
        } catch {
            errorMessage = "Failed to load Whisper model: \(error.localizedDescription)"
            AppLogger.transcription.error("Whisper model loading error: \(error.localizedDescription)")
        }

        // Bump the generation *before* clearing downloadProgress so any hop
        // still in flight for this (now-finished) load compares stale and
        // no-ops, rather than potentially landing after this reset and
        // resurrecting a stray percentage.
        downloadGeneration += 1
        downloadProgress = nil
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

    /// True if there's at least 2x `model`'s approximate download size free,
    /// so the download has headroom for the model's own decompressed/converted
    /// footprint rather than failing partway through.
    private func hasEnoughDiskSpace(for model: WhisperModel) -> Bool {
        let requiredBytes = Int64(model.approximateSizeMB) * 2 * 1_048_576
        return freeDiskSpaceProvider() >= requiredBytes
    }

    /// Bytes free on the volume holding the app's Application Support
    /// directory (where WhisperKit downloads models). Returns `Int64.max`
    /// (i.e. "assume enough space") if the filesystem can't be queried, so a
    /// probe failure never blocks a download that would otherwise succeed.
    nonisolated static func defaultFreeDiskSpace() -> Int64 {
        let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory()
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let freeSize = attributes[.systemFreeSize] as? NSNumber else {
            return .max
        }
        return freeSize.int64Value
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

        let validSegmentCount = allSegments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.count
        AppLogger.transcription.info("Valid segments: \(validSegmentCount) of \(allSegments.count)")

        // Diagnostic file log: one compact line with per-segment scores and text
        let noSpeechProbs = allSegments.map { String(format: "%.2f", $0.noSpeechProb) }.joined(separator: ",")
        let logProbs = allSegments.map { String(format: "%.1f", $0.avgLogprob) }.joined(separator: ",")
        let segTexts = allSegments.map { "\"\($0.text.trimmingCharacters(in: .whitespaces))\"" }.joined(separator: ",")

        let text = Self.cleanSegments(allSegments.map { TranscriptSegment(text: $0.text) })

        DiagnosticLogger.shared.log("WHISPER | segs=\(allSegments.count) valid=\(validSegmentCount) | noSpeech=[\(noSpeechProbs)] | logProb=[\(logProbs)] | texts=[\(segTexts)]")
        DiagnosticLogger.shared.log("WHISPER_CLEAN | text=\"\(text)\"")

        if text.isEmpty {
            throw TranscriberError.noSpeechDetected
        }

        return text
    }

    /// Strip Whisper control tokens and bracket noise tokens, drop empty/whitespace
    /// segments, and join what remains into one string.
    ///
    /// Pure function — no WhisperKit dependency — so it can be unit tested directly.
    static func cleanSegments(_ segments: [TranscriptSegment]) -> String {
        let validSegments = segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }

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
    case reloadInProgress
    case insufficientDiskSpace(model: WhisperModel, requiredMB: Int)

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
        case .reloadInProgress:
            return "A model reload is already in progress"
        case .insufficientDiskSpace(let model, let requiredMB):
            return "Not enough free disk space to download \(model.displayName) (~\(model.approximateSizeMB) MB model). Free at least \(requiredMB) MB and try again."
        }
    }
}
