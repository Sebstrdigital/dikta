import CoreML
import FluidAudio
import Foundation

/// Seam between `ParakeetEngine` and FluidAudio's Parakeet models — the same
/// role `TranscriptionEngine` plays for `MenuBarViewModel`:
/// `ParakeetEngine` talks to FluidAudio only through this protocol, never to
/// `AsrModels`/`AsrManager` directly, so tests substitute `FakeParakeetBackend`
/// (`DiktaTests/FakeParakeetBackend.swift`) and never download or load a real
/// model under XCTest.
protocol ParakeetBackend: AnyObject {
    /// Download (if needed) and load Ultra, reporting download progress.
    func loadUltra(
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws

    /// Transcribe `samples` (Float32 @ 16kHz) with the loaded model.
    /// `promptText` is accepted for chunk-pipeline interface parity, but
    /// FluidAudio's Parakeet decoder takes no textual prompt, so a real
    /// backend ignores it.
    func transcribe(_ samples: [Float], promptText: String?) async throws -> ParakeetBackendResult

    /// Release the loaded model's resources (see `TranscriptionEngine.unload()`).
    func unload() async
}

/// One backend transcription result: joined text plus word-level timings,
/// in seconds relative to the start of the samples passed to `transcribe`.
/// Empty `wordTimings` means the backend returned no per-token timing data
/// for this call — see `ParakeetEngine.transcribeSegments`'s fallback.
struct ParakeetBackendResult {
    let text: String
    let wordTimings: [ParakeetWordTiming]
}

struct ParakeetWordTiming {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Real `ParakeetBackend`, backed by FluidAudio's batch `AsrManager`.
///
/// Holds one `AsrManager` for the lifetime of a loaded model, but builds a
/// *fresh* `TdtDecoderState` for every `transcribe` call rather than
/// reusing one across calls. Dictation takes are independent utterances,
/// not a continuous stream: carrying LSTM h/c and `lastToken` from one take
/// into the next (as FluidAudio's own streaming paths do, and as
/// `finalizeLastChunk` does when a state is reused) would leak decoder
/// context between unrelated takes and skew results away from the
/// per-clip-fresh-state benchmarks in `bench/DiktaBench/main.swift`.
final class FluidAudioParakeetBackend: ParakeetBackend {
    private var manager: AsrManager?
    private var decoderLayers: Int?

    func loadUltra(
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let models = try await AsrModels.downloadAndLoad(
            version: .ultra,
            encoderComputeUnits: nil,
            progressHandler: { progress in progressHandler(progress.fractionCompleted) }
        )

        let manager = AsrManager(models: models)
        self.manager = manager
        self.decoderLayers = await manager.decoderLayerCount
    }

    func transcribe(_ samples: [Float], promptText: String?) async throws -> ParakeetBackendResult {
        guard let manager, let decoderLayers else {
            throw ParakeetEngineError.modelNotLoaded
        }

        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state)

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        return ParakeetBackendResult(
            text: result.text,
            wordTimings: words.map { ParakeetWordTiming(word: $0.word, start: $0.startTime, end: $0.endTime) }
        )
    }

    /// Release the loaded model's resources (see `TranscriptionEngine.unload()`).
    func unload() async {
        await manager?.cleanup()
        manager = nil
        decoderLayers = nil
    }
}

/// Service for transcribing audio using FluidAudio's Parakeet models.
///
/// The sole production speech-to-text engine. Every macOS transcription path
/// uses the pinned Parakeet Ultra model with multilingual automatic decode.
@MainActor
final class ParakeetEngine: ObservableObject, TranscriptionEngine {
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var downloadProgress: Double?

    nonisolated static let approximateSizeMB = 615

    private let backend: ParakeetBackend
    private let freeDiskSpaceProvider: () -> Int64

    /// Tests inject both dependencies so no real model or user filesystem is touched.
    init(
        backend: ParakeetBackend = FluidAudioParakeetBackend(),
        freeDiskSpaceProvider: @escaping () -> Int64 = TranscriptionSupport.defaultFreeDiskSpace
    ) {
        self.backend = backend
        self.freeDiskSpaceProvider = freeDiskSpaceProvider
    }

    /// Load the configured variant. No-op if already loading or ready.
    func load() async {
        guard !isLoading && !isReady else { return }
        await loadModel()
    }

    /// Release the backend's loaded model resources — called when this
    /// engine is being replaced by another (see `MenuBarViewModel.setEngine`),
    /// so FluidAudio's compiled Core ML models don't linger in memory
    /// alongside the new engine's.
    func unload() async {
        await backend.unload()
        isReady = false
    }

    private func loadModel() async {
        isLoading = true
        errorMessage = nil
        downloadProgress = nil

        do {
            guard hasEnoughDiskSpace() else {
                throw ParakeetEngineError.insufficientDiskSpace(requiredMB: Self.approximateSizeMB * 2)
            }

            downloadProgress = 0
            AppLogger.transcription.info("Loading Parakeet Ultra")

            try await backend.loadUltra { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }
            isReady = true
        } catch {
            errorMessage = "Failed to load Parakeet Ultra: \(error.localizedDescription)"
            AppLogger.transcription.error("Parakeet model loading error: \(error.localizedDescription)")
        }

        downloadProgress = nil
        isLoading = false
    }

    /// True if there's at least twice the approximate Ultra download size free.
    private func hasEnoughDiskSpace() -> Bool {
        let requiredBytes = Int64(Self.approximateSizeMB) * 2 * 1_048_576
        return freeDiskSpaceProvider() >= requiredBytes
    }

    /// Transcribe audio samples with the loaded Parakeet model.
    /// - Parameters:
    ///   - audioSamples: Float32 audio samples at 16kHz.
    ///   - language: Ignored — FluidAudio's Parakeet decode path used here
    ///     has no language-hint input in this engine's scope.
    /// - Returns: Cleaned text, using the same trim/sanitize pass as
    ///   the backend-neutral `TranscriptionSupport` cleanup pass.
    func transcribe(_ audioSamples: [Float], language: String? = nil, micSensitivity: MicSensitivity = .normal) async throws -> String {
        guard isReady else {
            throw ParakeetEngineError.modelNotLoaded
        }

        guard !audioSamples.isEmpty else {
            throw ParakeetEngineError.emptyAudio
        }

        let result = try await backend.transcribe(audioSamples, promptText: nil)
        let text = TranscriptionSupport.cleanSegments([RawTranscriptSegment(text: result.text)])

        if text.isEmpty {
            throw ParakeetEngineError.noSpeechDetected
        }

        return text
    }

    /// Transcribe audio samples into timestamped segments, in seconds
    /// relative to the start of `samples`. `language` is ignored (see
    /// `transcribe`). `promptText` is accepted for `TranscriptionEngine`
    /// conformance and passed through to the backend, but FluidAudio's Parakeet
    /// decoder takes no textual prompt, so it has no effect on the result.
    /// - Returns: Segments sorted by `start`, monotonic non-decreasing, with
    ///   sanitized text and empty segments dropped — the same rules
    ///   the shared `TranscriptionSupport` helpers apply.
    ///   When the backend reports no per-token timings for this call (see
    ///   `ParakeetBackendResult.wordTimings`), falls back to a single segment
    ///   spanning this whole chunk — "one segment per result window" for the
    ///   non-streaming batch path (US-007 knownIssues).
    func transcribeSegments(
        _ samples: [Float],
        language: String? = nil,
        micSensitivity: MicSensitivity = .normal,
        promptText: String? = nil
    ) async throws -> [TranscriptSegment] {
        guard isReady else {
            throw ParakeetEngineError.modelNotLoaded
        }

        guard !samples.isEmpty else {
            throw ParakeetEngineError.emptyAudio
        }

        let result = try await backend.transcribe(samples, promptText: promptText)

        let rawSegments: [TranscriptSegment]
        if result.wordTimings.isEmpty {
            rawSegments = [
                TranscriptSegment(start: 0, end: TimeInterval(samples.count) / 16_000, text: result.text)
            ]
        } else {
            rawSegments = result.wordTimings.map {
                TranscriptSegment(start: $0.start, end: $0.end, text: $0.word)
            }
        }

        return TranscriptionSupport.sortMonotonic(TranscriptionSupport.sanitizeAndDropEmpty(rawSegments))
    }
}

enum ParakeetEngineError: Error, LocalizedError {
    case modelNotLoaded
    case emptyAudio
    case noSpeechDetected
    case insufficientDiskSpace(requiredMB: Int)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Parakeet model not loaded"
        case .emptyAudio:
            return "No audio recorded"
        case .noSpeechDetected:
            return "No speech detected in recording"
        case .insufficientDiskSpace(let requiredMB):
            return "Not enough free disk space to download Parakeet Ultra (~\(ParakeetEngine.approximateSizeMB) MB model). Free at least \(requiredMB) MB and try again."
        }
    }
}
