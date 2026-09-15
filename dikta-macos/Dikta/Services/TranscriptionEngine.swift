import Foundation

/// Abstraction over a speech-to-text backend.
///
/// `Transcriber` (WhisperKit-backed) is the only conformer today, but callers
/// (namely `MenuBarViewModel`) depend on this protocol rather than on WhisperKit
/// directly. That keeps the WhisperKit dependency contained to one file and lets
/// the active model be swapped at runtime via `reload(model:)` without an app
/// restart.
@MainActor
protocol TranscriptionEngine: AnyObject {
    /// True while a model is being loaded or reloaded.
    var isLoading: Bool { get }
    /// True once a model has finished loading successfully.
    var isReady: Bool { get }
    /// Set when the most recent load/reload attempt failed.
    var errorMessage: String? { get }
    /// Fraction (0...1) of an in-progress model download, or nil when no
    /// download is happening (including while a bundled model loads, which
    /// never downloads).
    var downloadProgress: Double? { get }

    /// Load the currently configured model. No-op if already loading or ready.
    func load() async

    /// Unload the current model (if any) and load `model` in its place.
    /// Throws if the new model fails to load; `isReady`/`errorMessage` reflect
    /// the failure as well.
    func reload(model: WhisperModel) async throws

    /// Transcribe audio samples using the currently loaded model.
    func transcribe(_ audioSamples: [Float], language: String?, micSensitivity: MicSensitivity) async throws -> String

    /// Prepare the engine to transcribe in `language`, going forward.
    ///
    /// Most engines (WhisperKit's `Transcriber`) take a language code
    /// per-`transcribe` call and need no separate preparation step, hence the
    /// no-op default below. `AppleDictationEngine` overrides this: it must
    /// resolve `language` to a supported locale and make sure that locale's
    /// assets are installed *before* the next `transcribe` call, since
    /// `transcribe` itself refuses to auto-download mid-dictation.
    ///
    /// Throws if preparation fails (e.g. an unsupported/uninstallable
    /// locale); callers should keep the previous language active in that case
    /// rather than switching to one the engine can't actually use.
    func prepare(language: Language) async throws
}

extension TranscriptionEngine {
    func prepare(language: Language) async throws {}
}
