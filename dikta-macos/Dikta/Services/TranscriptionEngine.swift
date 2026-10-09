import Foundation

/// Abstraction over a speech-to-text backend.
///
/// The macOS app has one production conformer, `ParakeetEngine`, while tests
/// inject fakes. Keeping callers behind this seam prevents tests from loading or
/// downloading the real Ultra model.
@MainActor
protocol TranscriptionEngine: AnyObject {
    /// True while the Ultra model is being loaded.
    var isLoading: Bool { get }
    /// True once a model has finished loading successfully.
    var isReady: Bool { get }
    /// Set when the most recent load attempt failed.
    var errorMessage: String? { get }
    /// Fraction (0...1) of an in-progress model download, or nil when no
    /// download is happening (including while a bundled model loads, which
    /// never downloads).
    var downloadProgress: Double? { get }

    /// Load Ultra. No-op if already loading or ready.
    func load() async

    /// Release loaded model resources.
    func unload() async

    /// Transcribe audio samples using Ultra. `language` remains in the seam for
    /// source compatibility with pipeline tests, but production callers pass
    /// nil and Ultra does not accept a language hint.
    func transcribe(_ audioSamples: [Float], language: String?, micSensitivity: MicSensitivity) async throws -> String

    /// Transcribe audio samples using the currently loaded model, returning
    /// timestamped segments instead of one joined string. `promptText`, when
    /// non-nil and non-empty, conditions the decoder on the previous chunk's
    /// tail for continuity across chunk boundaries. Does not affect
    /// `transcribe(_:language:micSensitivity:)`.
    func transcribeSegments(_ samples: [Float], language: String?, micSensitivity: MicSensitivity, promptText: String?) async throws -> [TranscriptSegment]
}
