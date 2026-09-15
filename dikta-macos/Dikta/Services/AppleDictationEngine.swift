import Foundation
import Speech
import AVFoundation

/// `TranscriptionEngine` backed by Apple's on-device `DictationTranscriber`
/// (Speech framework, macOS 26+).
///
/// Lifecycle differs from `Transcriber` (WhisperKit): WhisperKit loads one
/// model once and reuses it for every utterance. `DictationTranscriber` and
/// `SpeechAnalyzer` must instead be constructed **fresh for every call to
/// `transcribe`** — reusing a pair across utterances has been observed to
/// silently return `""` on the second call, with no error (verified against
/// the SDK; see `docs/review-2026-09/apple-dictation-engine-spec.md` §6).
/// `load()` here therefore only resolves the configured language to a
/// supported locale and makes sure its assets are installed; it does not
/// build a long-lived transcriber/analyzer.
@available(macOS 26.0, *)
@MainActor
final class AppleDictationEngine: ObservableObject, TranscriptionEngine {
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var downloadProgress: Double?

    private let configService: ConfigService

    /// The `Language` `isReady` was last successfully resolved/installed for.
    /// Lets `load()` tell "ready for the language that's now configured" apart
    /// from "ready, but for a language that's since changed" — without this,
    /// `load()`'s `!isReady` early-return would silently no-op forever after
    /// the first successful load, even once `configService.language` moves on.
    private var preparedLanguage: Language?

    init(configService: ConfigService) {
        self.configService = configService
    }

    /// Maps a Dikta `Language` to the BCP-47 identifier `DictationTranscriber`
    /// expects (spec §4). Pure — no Speech framework calls — so it can be unit
    /// tested without touching Speech.
    nonisolated static func bcp47(for language: Language) -> String {
        switch language {
        case .english: return "en-US"
        case .swedish: return "sv-SE"
        case .indonesian: return "id-ID"
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .portuguese: return "pt-BR"
        case .italian: return "it-IT"
        case .dutch: return "nl-NL"
        case .finnish: return "fi-FI"
        case .norwegian: return "nb-NO"
        case .danish: return "da-DK"
        }
    }

    /// Resolve the currently configured `Language` and make sure its assets
    /// are installed. No-op if already loading, or already ready *for that
    /// language* — see `preparedLanguage`.
    func load() async {
        await prepareIfNeeded(for: configService.language)
    }

    /// Re-resolve and (re-)install assets for `language`, so switching the
    /// active dictation language while Apple Dictation is already loaded
    /// doesn't leave `transcribe` throwing `.assetsNotInstalled` until the
    /// app restarts. Unlike `load()`, this isn't a no-op when `isReady` is
    /// already true — re-preparing for a *different* language is exactly the
    /// case where the engine is ready for the *old* language and must become
    /// ready for the new one instead.
    ///
    /// Throws if `language` can't be resolved/installed; callers should keep
    /// the previous language active in that case (this leaves whatever
    /// language was last successfully prepared still working — `isReady`
    /// only goes `false` if *this* prepare fails outright, not merely because
    /// a different one is being attempted).
    func prepare(language: Language) async throws {
        guard !isLoading else {
            throw TranscriberError.reloadInProgress
        }
        await prepareIfNeeded(for: language)
        guard isReady, preparedLanguage == language else {
            throw AppleDictationEngineError.unsupportedLanguage(language.displayName)
        }
    }

    /// Shared core of `load()`/`prepare(language:)`: resolves `language` and
    /// installs its assets unless already prepared for exactly that language.
    /// Guards against overlapping calls via `isLoading`.
    private func prepareIfNeeded(for language: Language) async {
        guard !isLoading else { return }
        guard !(isReady && preparedLanguage == language) else { return }

        isLoading = true
        errorMessage = nil
        downloadProgress = nil

        await resolveAndInstall(for: language)

        isLoading = false
    }

    /// Apple Dictation has no interchangeable "model" the way WhisperKit does
    /// — there is only the one on-device `DictationTranscriber` per locale.
    /// Engine switching (Whisper <-> Apple Dictation) is handled by
    /// `MenuBarViewModel.setEngine` via `TranscriptionEngineFactory`, which
    /// builds and loads a whole new engine instance rather than reloading
    /// this one with a Whisper model identifier. This is therefore a no-op
    /// that leaves `isReady` (and whatever locale `load()` already
    /// resolved/installed) exactly as it was.
    func reload(model: WhisperModel) async throws {}

    func transcribe(_ audioSamples: [Float], language: String?, micSensitivity: MicSensitivity) async throws -> String {
        guard !audioSamples.isEmpty else {
            throw TranscriberError.emptyAudio
        }

        // Per spec: no auto-detect, and no language-code translation layer —
        // `language` (when passed) is a Dikta `Language.rawValue` like the
        // caller already passes to WhisperKit. If it differs from what
        // `load()` resolved, re-resolve rather than failing outright.
        let targetLanguage = language.flatMap(Language.init(rawValue:)) ?? configService.language
        let candidate = Locale(identifier: Self.bcp47(for: targetLanguage))

        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: candidate) else {
            throw AppleDictationEngineError.unsupportedLanguage(targetLanguage.displayName)
        }

        // Assets are only ever installed by `load()`. Never auto-download here
        // mid-dictation — if they're missing, surface a clear error instead.
        let installed = await DictationTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier == locale.identifier }) else {
            throw AppleDictationEngineError.assetsNotInstalled(targetLanguage.displayName)
        }

        // Fresh transcriber + analyzer per call — see the type doc comment.
        let dictationTranscriber = DictationTranscriber(locale: locale, preset: .shortDictation)

        guard let wantFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [dictationTranscriber]) else {
            throw AppleDictationEngineError.audioFormatUnavailable
        }

        let inputBuffer = try Self.convert(audioSamples, to: wantFormat)

        let analyzer = SpeechAnalyzer(modules: [dictationTranscriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: inputBuffer))
        continuation.finish()

        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        var text = ""
        for try await result in dictationTranscriber.results {
            text += String(result.text.characters)
        }

        // Parity with Transcriber.cleanSegments: return only trimmed,
        // non-empty text, and treat an empty result as "no speech" rather
        // than pasting nothing silently.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriberError.noSpeechDetected
        }
        return trimmed
    }

    // MARK: - Locale resolution + asset install

    /// Resolves `language` to a supported `DictationTranscriber` locale and
    /// ensures its assets are installed, setting `isReady`/`errorMessage`
    /// accordingly. Per spec §3, `AssetInventory.assetInstallationRequest`
    /// (not `AssetInventory.status(forModules:)`, which was observed to
    /// disagree with actual install state) is the reliable signal here:
    /// throwing means the locale isn't actually supported for install; a
    /// non-nil request means `downloadAndInstall()` needs to run (it's cheap/
    /// near-instant when assets are already installed).
    private func resolveAndInstall(for language: Language) async {
        let candidate = Locale(identifier: Self.bcp47(for: language))
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: candidate) else {
            isReady = false
            errorMessage = "Apple Dictation does not support \(language.displayName)."
            return
        }

        let probe = DictationTranscriber(locale: locale, preset: .shortDictation)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await withPublishedProgress(for: request) {
                    try await request.downloadAndInstall()
                }
            }
            isReady = true
            preparedLanguage = language
        } catch {
            isReady = false
            errorMessage = "Apple Dictation does not support \(language.displayName)."
            AppLogger.transcription.error("Apple Dictation asset install error: \(error.localizedDescription)")
        }
    }

    /// Runs `work` (an `AssetInstallationRequest.downloadAndInstall()` call)
    /// while mirroring the request's own `Progress.fractionCompleted` into
    /// `downloadProgress`. Falls back to a plain 0→1 jump around the call if
    /// no progress updates ever arrive (e.g. an install that completes before
    /// the first KVO tick), so `downloadProgress` never gets stuck at 0.
    private func withPublishedProgress(for request: AssetInstallationRequest, _ work: () async throws -> Void) async rethrows {
        downloadProgress = 0
        let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.downloadProgress = value
            }
        }
        defer {
            observation.invalidate()
            downloadProgress = nil
        }
        try await work()
    }

    // MARK: - Audio conversion

    /// Dikta's `AudioRecorder` produces 16kHz mono Float32 samples (its own
    /// target format for WhisperKit). `DictationTranscriber` typically wants
    /// Int16 (verified: `bestAvailableAudioFormat` returned 16kHz mono Int16
    /// for sv-SE — spec §2), so convert whenever the analyzer's requested
    /// format differs from the source.
    private static func convert(_ samples: [Float], to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let sourceBuffer = makeFloatBuffer(samples: samples, format: sourceFormat) else {
            throw AppleDictationEngineError.conversionFailed
        }

        guard format.commonFormat != sourceFormat.commonFormat || format.sampleRate != sourceFormat.sampleRate else {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw AppleDictationEngineError.conversionFailed
        }

        let ratio = format.sampleRate / sourceFormat.sampleRate
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1024
        ) else {
            throw AppleDictationEngineError.conversionFailed
        }

        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        if let conversionError {
            throw conversionError
        }
        return outputBuffer
    }

    private static func makeFloatBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData else { return nil }
        samples.withUnsafeBufferPointer { source in
            channelData[0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

enum AppleDictationEngineError: Error, LocalizedError {
    case unsupportedLanguage(String)
    case assetsNotInstalled(String)
    case audioFormatUnavailable
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let language):
            return "Apple Dictation does not support \(language)."
        case .assetsNotInstalled(let language):
            return "Apple Dictation language assets for \(language) are not installed yet. Switch languages while Apple Dictation is loading, or reload the engine, to install them."
        case .audioFormatUnavailable:
            return "Apple Dictation could not determine a compatible audio format."
        case .conversionFailed:
            return "Apple Dictation could not convert the recorded audio."
        }
    }
}
