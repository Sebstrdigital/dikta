import Foundation

/// Available Kokoro TTS voices. The raw value is the signed native pack ID.
enum KokoroVoice: String, CaseIterable, Sendable {
    case af_heart = "af_heart", af_nicole = "af_nicole", am_adam = "am_adam", bm_george = "bm_george"
    // Compatibility-only raw values: never offered by `allCases` and rejected
    // by the fixed catalog, so saved selections remain visible/read-blocked.
    case af_bella = "af_bella", af_sarah = "af_sarah", af_sky = "af_sky", am_michael = "am_michael", bf_emma = "bf_emma", bf_isabella = "bf_isabella", bm_lewis = "bm_lewis"
    static let allCases: [KokoroVoice] = [.af_heart, .af_nicole, .am_adam, .bm_george]

    var displayName: String {
        switch self {
        case .af_heart: return "Heart"
        case .af_nicole: return "Nicole"
        case .am_adam: return "Adam"
        case .bm_george: return "George"
        default: return rawValue
        }
    }
}

enum TextToSpeechSpeed: Double, CaseIterable, Sendable {
    case slow = 0.75, normal = 1, fast = 1.25, speedy = 1.75
    var displayName: String {
        switch self {
        case .slow: return "Slow (0.75×)"
        case .normal: return "Normal (1×)"
        case .fast: return "Fast (1.25×)"
        case .speedy: return "Speedy (1.75×)"
        }
    }
}

/// An exact, ordered range in the original selection. The chunker stores ranges,
/// not a second copy of the long selection or generated audio.
struct ProgressiveTextChunk: Equatable {
    let sequence: Int
    let range: Range<String.Index>
}

/// Conservative source-side work bounds. These are not claimed to predict the
/// SDK's phoneme count: the helper remains authoritative for its 510-phoneme and
/// acoustic-frame guards and returns an explicit input failure when they reject a
/// chunk. Exact source ranges preserve every scalar, space and punctuation mark.
struct ProgressiveTextChunker {
    static let maximumSourceUTF8Bytes = 256 * 1024
    static let maximumChunks = 1_024
    static let maximumChunkUTF8Bytes = 480
    static let maximumChunkWords = 48
    static let maximumWordCharacters = 62

    enum ChunkError: Error, Equatable { case unsupportedInput }

    func chunks(in text: String) throws -> [ProgressiveTextChunk] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maximumSourceUTF8Bytes,
              !text.unicodeScalars.contains(where: { $0.value < 32 && !$0.properties.isWhitespace }),
              text.split(whereSeparator: { $0.isWhitespace }).allSatisfy({ $0.count <= Self.maximumWordCharacters }) else {
            throw ChunkError.unsupportedInput
        }

        var chunks: [ProgressiveTextChunk] = []
        var start = text.startIndex
        while start < text.endIndex {
            var cursor = start
            var lastSentence: String.Index?
            var lastClause: String.Index?
            var lastWhitespace: String.Index?

            while cursor < text.endIndex {
                let next = text.index(after: cursor)
                let candidate = text[start..<next]
                let words = candidate.split(whereSeparator: { $0.isWhitespace }).count
                if candidate.utf8.count > Self.maximumChunkUTF8Bytes || words > Self.maximumChunkWords { break }

                cursor = next
                let characterIndex = text.index(before: next)
                let character = text[characterIndex]
                if character.isWhitespace {
                    lastWhitespace = next
                } else if isSentenceBoundary(character, at: characterIndex, in: text) {
                    lastSentence = next
                } else if isClauseBoundary(character, at: characterIndex, in: text) {
                    lastClause = next
                }
            }

            let end: String.Index
            if cursor == text.endIndex {
                end = cursor
            } else {
                end = lastSentence ?? lastClause ?? lastWhitespace ?? cursor
            }
            guard end > start,
                  !text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  chunks.count < Self.maximumChunks else {
                throw ChunkError.unsupportedInput
            }
            chunks.append(ProgressiveTextChunk(sequence: chunks.count, range: start..<end))
            start = end
        }
        return chunks
    }

    /// Punctuation is preferred only when it terminates a token. In particular,
    /// punctuation embedded in decimals, abbreviations, URLs, and other lexical
    /// tokens is never treated as a chunk boundary.
    private func isSentenceBoundary(_ character: Character, at index: String.Index, in text: String) -> Bool {
        guard character == "." || character == "!" || character == "?",
              isFollowedByWhitespaceOrEnd(index, in: text) else { return false }
        guard character == "." else { return true }

        var tokenStart = index
        while tokenStart > text.startIndex {
            let previous = text.index(before: tokenStart)
            if text[previous].isWhitespace { break }
            tokenStart = previous
        }
        let token = text[tokenStart..<index]
        if token.contains(".") { return false }
        let letters = token.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if letters.count == token.unicodeScalars.count, letters.count <= 3 { return false }
        return true
    }

    private func isClauseBoundary(_ character: Character, at index: String.Index, in text: String) -> Bool {
        guard character == "," || character == ";" || character == ":" else { return false }
        return isFollowedByWhitespaceOrEnd(index, in: text)
    }

    private func isFollowedByWhitespaceOrEnd(_ index: String.Index, in text: String) -> Bool {
        let next = text.index(after: index)
        return next == text.endIndex || text[next].isWhitespace
    }
}

/// Serialized owner of one progressive native request. It owns source ranges,
/// request/session identity and scheduling; playback owns only its current WAV.
@MainActor
final class TextToSpeechService: TextToSpeechSpeaking {
    static let maximumAudioBytes = 1_048_576

    enum TTSError: LocalizedError, Equatable {
        case notAvailable(String)
        case unsupportedText
        case playbackFailed
        case playbackInterrupted
        case alreadySpeaking

        var errorDescription: String? {
            switch self {
            case .notAvailable(let message): return message
            case .unsupportedText:
                return "This selection is outside the native voice engine's bounded input limits. Dikta did not truncate it."
            case .playbackFailed:
                return "Native speech audio could not be played."
            case .playbackInterrupted:
                return "Native speech audio was interrupted. Try Read Aloud again."
            case .alreadySpeaking:
                return "Read Aloud is already speaking."
            }
        }
    }

    var voice: KokoroVoice = .af_heart
    var speed: TextToSpeechSpeed = .normal
    private(set) var unavailabilityMessage: String?
    private(set) var isSetUp = false
    var speaking: Bool { activeRequest != nil }

    private struct PlaybackWaiter {
        let request: UUID
        let chunk: Int
        let tag: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let runtime: any NativeKokoroRuntimeServing
    private let player: any NativeTTSPlayback
    private let chunker: ProgressiveTextChunker
    private var activeRequest: UUID?
    private var playbackWaiter: PlaybackWaiter?
    private var pendingPlaybackIdentity: (request: UUID, chunk: Int, tag: UUID)?
    private var earlyPlaybackResult: Result<Void, Error>?
    private struct GenerationHandle {
        let request: UUID
        let chunk: Int
        let identity: UUID
        let task: Task<Data, Error>
    }

    private var generationTask: GenerationHandle?

    init(
        runtime: (any NativeKokoroRuntimeServing)? = nil,
        player: (any NativeTTSPlayback)? = nil,
        chunker: ProgressiveTextChunker = ProgressiveTextChunker()
    ) {
        self.runtime = runtime ?? NativeKokoroRuntimeClient()
        self.player = player ?? AVNativeTTSPlayer()
        self.chunker = chunker
        self.player.eventHandler = { [weak self] event in self?.handlePlayback(event) }
    }

    /// Configured asset readiness is deliberately distinct from engine loaded
    /// state. A true result means the first request may proceed and wait for lazy
    /// startup; it never means the helper is already resident.
    func captureRequest() -> TextToSpeechRequest {
        TextToSpeechRequest(voice: voice, speed: speed)
    }

    func checkAvailable(for request: TextToSpeechRequest) async -> Bool {
        do {
            _ = try await runtime.prepare(voiceID: request.voice.rawValue, speed: Float(request.speed.rawValue))
            try Task.checkCancellation()
            isSetUp = true
            unavailabilityMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            if case NativeKokoroReadError.selectedVoiceNotInstalled = error { isSetUp = true }
            unavailabilityMessage = safeMessage(for: error)
            return false
        }
    }

    func speak(_ text: String, request: TextToSpeechRequest) async throws {
        // Chunking and request ownership happen before startup. Unsupported input
        // cannot acquire an asset lease or helper.
        try Task.checkCancellation()
        guard activeRequest == nil else { throw TTSError.alreadySpeaking }
        let chunks: [ProgressiveTextChunk]
        do { chunks = try chunker.chunks(in: text) }
        catch { throw TTSError.unsupportedText }

        let requestID = UUID()
        activeRequest = requestID

        try await withTaskCancellationHandler {
            do {
                let snapshot = try await runtime.prepare(voiceID: request.voice.rawValue, speed: Float(request.speed.rawValue))
                try requireOwnership(requestID)

                var index = 0
                var audio = try await synthesize(text[chunks[0].range], snapshot: snapshot, request: requestID)
                while true {
                    try requireOwnership(requestID)
                    let tag = UUID() // distinct audio identity for every source range
                    try startPlayback(audio, request: requestID, chunk: index, tag: tag)

                    let nextIndex = index + 1
                    let lookahead: Task<Data, Error>?
                    if nextIndex < chunks.count {
                        let source = String(text[chunks[nextIndex].range])
                        let task = Task { @MainActor [runtime] in
                            try await runtime.synthesize(text: source, snapshot: snapshot)
                        }
                        generationTask = GenerationHandle(
                            request: requestID, chunk: nextIndex, identity: UUID(), task: task
                        )
                        lookahead = task
                    } else {
                        lookahead = nil
                    }

                    do {
                        try await waitForPlayback(request: requestID, chunk: index, tag: tag)
                    } catch {
                        cancelGeneration(request: requestID, chunk: nextIndex)
                        throw error
                    }
                    try requireOwnership(requestID)
                    // Credits follow actual playback consumption, never receipt.
                    runtime.playbackDrained()

                    guard let lookahead else { break }
                    let generationIdentity = generationTask.flatMap {
                        $0.request == requestID && $0.chunk == nextIndex ? $0.identity : nil
                    }
                    audio = try await lookahead.value
                    clearGeneration(request: requestID, chunk: nextIndex, identity: generationIdentity)
                    try validateAudio(audio)
                    try requireOwnership(requestID)
                    index = nextIndex
                }

                try requireOwnership(requestID)
                clearGeneration(request: requestID)
                activeRequest = nil
            } catch {
                if activeRequest == requestID {
                    activeRequest = nil // invalidate before playback/helper cleanup
                    cancelGeneration(request: requestID)
                    let continuation = playbackWaiter?.request == requestID ? playbackWaiter?.continuation : nil
                    playbackWaiter = nil
                    pendingPlaybackIdentity = nil
                    earlyPlaybackResult = nil
                    continuation?.resume(throwing: CancellationError())
                    player.stop()
                    runtime.stop()
                }
                if error is CancellationError { throw CancellationError() }
                if let native = error as? NativeKokoroReadError {
                    throw TTSError.notAvailable(native.errorDescription ?? "Native Read Aloud failed.")
                }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: requestID) }
        }
    }

    // Compatibility conveniences for direct service tests. The ViewModel always
    // uses one explicit request captured before its first asynchronous selection.
    func checkAvailable() async -> Bool {
        await checkAvailable(for: captureRequest())
    }

    func speak(_ text: String) async throws {
        try await speak(text, request: captureRequest())
    }

    /// Invalidate request ownership before touching playback or native work.
    func stop() {
        guard let id = activeRequest else { return }
        cancel(id: id)
    }

    private func synthesize(_ source: Substring, snapshot: NativeKokoroAssetSnapshot, request: UUID) async throws -> Data {
        let audio = try await runtime.synthesize(text: String(source), snapshot: snapshot)
        try requireOwnership(request)
        try validateAudio(audio)
        return audio
    }

    private func validateAudio(_ audio: Data) throws {
        guard !audio.isEmpty, audio.count <= Self.maximumAudioBytes else { throw TTSError.playbackFailed }
    }

    private func requireOwnership(_ id: UUID) throws {
        try Task.checkCancellation()
        guard activeRequest == id else { throw CancellationError() }
    }

    private func startPlayback(_ wav: Data, request: UUID, chunk: Int, tag: UUID) throws {
        pendingPlaybackIdentity = (request, chunk, tag)
        earlyPlaybackResult = nil
        do { try player.play(wav: wav, tag: tag) }
        catch {
            pendingPlaybackIdentity = nil
            throw TTSError.playbackFailed
        }
    }

    private func waitForPlayback(request: UUID, chunk: Int, tag: UUID) async throws {
        guard let pending = pendingPlaybackIdentity,
              pending.request == request, pending.chunk == chunk, pending.tag == tag else {
            throw TTSError.playbackFailed
        }
        if let result = earlyPlaybackResult {
            earlyPlaybackResult = nil
            pendingPlaybackIdentity = nil
            return try result.get()
        }
        try await withCheckedThrowingContinuation { continuation in
            playbackWaiter = PlaybackWaiter(request: request, chunk: chunk, tag: tag, continuation: continuation)
        }
    }

    private func handlePlayback(_ event: NativeTTSPlaybackEvent) {
        switch event {
        case .started:
            return
        case .finished(let tag):
            resumePlayback(tag: tag, result: .success(()))
        case .failed(let tag):
            resumePlayback(tag: tag, result: .failure(TTSError.playbackFailed))
        case .interrupted(let tag):
            resumePlayback(tag: tag, result: .failure(TTSError.playbackInterrupted))
        }
    }

    private func resumePlayback(tag: UUID, result: Result<Void, Error>) {
        guard let pending = pendingPlaybackIdentity,
              activeRequest == pending.request, pending.tag == tag else { return }
        guard let waiter = playbackWaiter else {
            earlyPlaybackResult = result
            return
        }
        guard waiter.request == pending.request, waiter.chunk == pending.chunk, waiter.tag == tag else { return }
        playbackWaiter = nil
        pendingPlaybackIdentity = nil
        earlyPlaybackResult = nil
        waiter.continuation.resume(with: result)
    }

    private func cancel(id: UUID) {
        guard activeRequest == id else { return }
        activeRequest = nil
        cancelGeneration(request: id)
        let continuation = playbackWaiter?.request == id ? playbackWaiter?.continuation : nil
        playbackWaiter = nil
        pendingPlaybackIdentity = nil
        earlyPlaybackResult = nil
        continuation?.resume(throwing: CancellationError())
        player.stop()
        runtime.stop()
    }

    private func cancelGeneration(request: UUID, chunk: Int? = nil) {
        guard let handle = generationTask, handle.request == request,
              chunk == nil || handle.chunk == chunk else { return }
        generationTask = nil
        handle.task.cancel()
    }

    private func clearGeneration(request: UUID, chunk: Int? = nil, identity: UUID? = nil) {
        guard let handle = generationTask, handle.request == request,
              chunk == nil || handle.chunk == chunk,
              identity == nil || handle.identity == identity else { return }
        generationTask = nil
    }

    private func safeMessage(for error: Error) -> String {
        if let native = error as? NativeKokoroReadError {
            return native.errorDescription ?? "Native Read Aloud is unavailable."
        }
        return "Native Read Aloud is unavailable. Open Setup and try again."
    }
}
