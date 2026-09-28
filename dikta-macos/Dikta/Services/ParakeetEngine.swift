import CoreML
import FluidAudio
import Foundation

/// Seam between `ParakeetEngine` and FluidAudio's Parakeet models — the same
/// role `TranscriptionEngine` plays for `MenuBarViewModel` and WhisperKit:
/// `ParakeetEngine` talks to FluidAudio only through this protocol, never to
/// `AsrModels`/`AsrManager` directly, so tests substitute `FakeParakeetBackend`
/// (`DiktaTests/FakeParakeetBackend.swift`) and never download or load a real
/// model under XCTest.
protocol ParakeetBackend: AnyObject {
    /// Download (if needed) and load the model variant for `kind`, reporting
    /// download progress on `progressHandler` (0...1). Called on an
    /// unspecified queue, mirroring FluidAudio's own `ProgressHandler`.
    func loadModel(
        kind: TranscriptionEngineKind,
        encoderComputeUnits: MLComputeUnits?,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws

    /// Transcribe `samples` (Float32 @ 16kHz) with the loaded model.
    /// `promptText` is accepted for interface parity with `Transcriber`, but
    /// FluidAudio's Parakeet decoder takes no textual prompt, so a real
    /// backend ignores it.
    func transcribe(_ samples: [Float], promptText: String?) async throws -> ParakeetBackendResult
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
/// Holds one `AsrManager` + `TdtDecoderState` pair for the lifetime of a
/// loaded model, reusing the decoder state across `transcribe` calls the way
/// FluidAudio's streaming paths do — each chunk continues from the previous
/// chunk's decoder state rather than starting cold.
final class FluidAudioParakeetBackend: ParakeetBackend {
    private var manager: AsrManager?
    private var decoderState: TdtDecoderState?

    func loadModel(
        kind: TranscriptionEngineKind,
        encoderComputeUnits: MLComputeUnits?,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let version = Self.modelVersion(for: kind)
        let models = try await AsrModels.downloadAndLoad(
            version: version,
            encoderComputeUnits: encoderComputeUnits,
            progressHandler: { progress in progressHandler(progress.fractionCompleted) }
        )

        let manager = AsrManager(models: models)
        let decoderLayers = await manager.decoderLayerCount
        self.manager = manager
        self.decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
    }

    func transcribe(_ samples: [Float], promptText: String?) async throws -> ParakeetBackendResult {
        guard let manager, var state = decoderState else {
            throw ParakeetEngineError.modelNotLoaded
        }

        let result = try await manager.transcribe(samples, decoderState: &state)
        decoderState = state

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        return ParakeetBackendResult(
            text: result.text,
            wordTimings: words.map { ParakeetWordTiming(word: $0.word, start: $0.startTime, end: $0.endTime) }
        )
    }

    /// Maps a persisted `TranscriptionEngineKind` to the FluidAudio model
    /// version it downloads/loads. `.whisper` has no Parakeet equivalent —
    /// unreachable in practice, since `ParakeetEngine` is only ever
    /// constructed for a `.parakeet*` kind — but is listed explicitly so the
    /// switch stays exhaustive rather than needing a `default` that could
    /// silently swallow a future kind.
    private static func modelVersion(for kind: TranscriptionEngineKind) -> AsrModelVersion {
        switch kind {
        case .parakeetRedux: return .redux
        case .parakeetV3: return .v3
        case .parakeetUltra: return .ultra
        case .whisper: return .v3
        }
    }
}

/// Service for transcribing audio using FluidAudio's Parakeet models.
///
/// Conforms to `TranscriptionEngine` alongside `Transcriber` (WhisperKit) so
/// `MenuBarViewModel` can depend on that protocol rather than on either
/// backend directly. One instance transcribes one fixed
/// `TranscriptionEngineKind` (`.parakeetRedux`/`.parakeetV3`/`.parakeetUltra`)
/// — unlike `Transcriber`, whose `reload(model:)` swaps the active Whisper
/// model size, Parakeet has no equivalent submenu
/// (`TranscriptionEngineKind.usesWhisperModelSubmenu` is `false` for every
/// Parakeet kind), so switching Parakeet variants means switching which
/// `ParakeetEngine` instance is active, not reloading this one.
@MainActor
final class ParakeetEngine: ObservableObject, TranscriptionEngine {
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var downloadProgress: Double?

    private let kind: TranscriptionEngineKind
    private let backend: ParakeetBackend
    private let freeDiskSpaceProvider: () -> Int64

    /// - Parameters:
    ///   - kind: Which Parakeet variant this engine loads and transcribes with.
    ///   - backend: FluidAudio seam. Defaults to the real FluidAudio-backed
    ///     implementation; tests inject `FakeParakeetBackend`.
    ///   - freeDiskSpaceProvider: Same disk-space probe `Transcriber` uses
    ///     (bytes free on the volume holding Application Support, where
    ///     FluidAudio caches models too — see `MLModelConfigurationUtils
    ///     .defaultModelsDirectory`), so both engines agree on what "enough
    ///     free space" means. Defaults to `Transcriber.defaultFreeDiskSpace`.
    init(
        kind: TranscriptionEngineKind,
        backend: ParakeetBackend = FluidAudioParakeetBackend(),
        freeDiskSpaceProvider: @escaping () -> Int64 = Transcriber.defaultFreeDiskSpace
    ) {
        self.kind = kind
        self.backend = backend
        self.freeDiskSpaceProvider = freeDiskSpaceProvider
    }

    /// Load the configured variant. No-op if already loading or ready.
    func load() async {
        guard !isLoading && !isReady else { return }
        await loadModel()
    }

    /// `TranscriptionEngine.reload(model:)` exists for WhisperKit's model-size
    /// switching (see `Transcriber.reload(model:)`); Parakeet has no
    /// equivalent — `model` is unused. A no-op that leaves `isReady`
    /// untouched, so a caller that always calls `reload(model:)` on a
    /// Whisper-model-menu selection doesn't have to special-case Parakeet.
    func reload(model: WhisperModel) async throws {}

    private func loadModel() async {
        isLoading = true
        errorMessage = nil
        downloadProgress = nil

        do {
            guard hasEnoughDiskSpace() else {
                throw ParakeetEngineError.insufficientDiskSpace(
                    kind: kind,
                    requiredMB: kind.approximateSizeMB * 2
                )
            }

            downloadProgress = 0
            AppLogger.transcription.info("Downloading Parakeet model: \(self.kind.displayName)")

            try await backend.loadModel(
                kind: kind,
                encoderComputeUnits: Self.encoderComputeUnits(for: kind)
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }
            isReady = true
        } catch {
            errorMessage = "Failed to load \(kind.displayName) model: \(error.localizedDescription)"
            AppLogger.transcription.error("Parakeet model loading error: \(error.localizedDescription)")
        }

        downloadProgress = nil
        isLoading = false
    }

    /// Redux's ternary-quantized encoder benchmarks faster on GPU than on
    /// ANE; v3/Ultra use the platform default (ANE) by passing `nil` through
    /// to `AsrModels`. See `AsrModels.createModelSpecs`'s doc comment on
    /// `encoderComputeUnits` for the general ANE-vs-GPU tradeoff.
    private static func encoderComputeUnits(for kind: TranscriptionEngineKind) -> MLComputeUnits? {
        kind == .parakeetRedux ? .cpuAndGPU : nil
    }

    /// True if there's at least 2x `kind`'s approximate download size free,
    /// mirroring `Transcriber.hasEnoughDiskSpace(for:)`.
    private func hasEnoughDiskSpace() -> Bool {
        let requiredBytes = Int64(kind.approximateSizeMB) * 2 * 1_048_576
        return freeDiskSpaceProvider() >= requiredBytes
    }

    /// Transcribe audio samples with the loaded Parakeet model.
    /// - Parameters:
    ///   - audioSamples: Float32 audio samples at 16kHz.
    ///   - language: Ignored — FluidAudio's Parakeet decode path used here
    ///     has no language-hint input in this engine's scope.
    /// - Returns: Cleaned text, using the same trim/sanitize pass as
    ///   `Transcriber` (`Transcriber.cleanSegments`, shared rather than
    ///   duplicated so the two engines never drift on what counts as noise).
    func transcribe(_ audioSamples: [Float], language: String? = nil, micSensitivity: MicSensitivity = .normal) async throws -> String {
        guard isReady else {
            throw ParakeetEngineError.modelNotLoaded
        }

        guard !audioSamples.isEmpty else {
            throw ParakeetEngineError.emptyAudio
        }

        let result = try await backend.transcribe(audioSamples, promptText: nil)
        let text = Transcriber.cleanSegments([RawTranscriptSegment(text: result.text)])

        if text.isEmpty {
            throw ParakeetEngineError.noSpeechDetected
        }

        return text
    }

    /// Transcribe audio samples into timestamped segments, in seconds
    /// relative to the start of `samples`. `language` is ignored (see
    /// `transcribe`). `promptText` is accepted for `TranscriptionEngine`
    /// conformance — mirroring `Transcriber`'s cross-chunk continuity prompt
    /// — and passed through to the backend, but FluidAudio's Parakeet
    /// decoder takes no textual prompt, so it has no effect on the result.
    /// - Returns: Segments sorted by `start`, monotonic non-decreasing, with
    ///   sanitized text and empty segments dropped — the same rules
    ///   `Transcriber.transcribeSegments` applies, reused via
    ///   `Transcriber.sanitizeAndDropEmpty`/`Transcriber.sortMonotonic`.
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

        return Transcriber.sortMonotonic(Transcriber.sanitizeAndDropEmpty(rawSegments))
    }
}

enum ParakeetEngineError: Error, LocalizedError {
    case modelNotLoaded
    case emptyAudio
    case noSpeechDetected
    case insufficientDiskSpace(kind: TranscriptionEngineKind, requiredMB: Int)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Parakeet model not loaded"
        case .emptyAudio:
            return "No audio recorded"
        case .noSpeechDetected:
            return "No speech detected in recording"
        case .insufficientDiskSpace(let kind, let requiredMB):
            return "Not enough free disk space to download \(kind.displayName) (~\(kind.approximateSizeMB) MB model). Free at least \(requiredMB) MB and try again."
        }
    }
}
