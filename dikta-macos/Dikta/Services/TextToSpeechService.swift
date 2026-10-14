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
    /// Qualification can retain the old plan as a control without weakening any
    /// input, generation, lease or playback bound.
    var earlierFirstSentence = true
    static let maximumSourceUTF8Bytes = 256 * 1024
    static let maximumChunks = 1_024
    static let maximumChunkUTF8Bytes = 480
    static let maximumChunkWords = 48
    static let maximumWordCharacters = 62
    /// Native helper's hard source-byte guard. Exterior whitespace may be
    /// attached only when it remains within this independently enforced limit.
    static let maximumSynthesisUTF8Bytes = 1_024

    /// Nicole can produce unusually long acoustic output for otherwise valid
    /// source at 1.25×. Leave a margin below the helper's 20-second limit for
    /// that voice/speed pair; all other requests retain the qualified plan.
    private static let nicoleFastMaximumChunkUTF8Bytes = 240
    private static let nicoleFastMaximumChunkWords = 24

    enum ChunkError: Error, Equatable { case unsupportedInput }

    func chunks(in text: String, request: TextToSpeechRequest? = nil) throws -> [ProgressiveTextChunk] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maximumSourceUTF8Bytes,
              !text.unicodeScalars.contains(where: { $0.value < 32 && !$0.properties.isWhitespace }),
              text.split(whereSeparator: { $0.isWhitespace }).allSatisfy({ $0.count <= Self.maximumWordCharacters }) else {
            throw ChunkError.unsupportedInput
        }

        let limits = chunkLimits(for: request)
        // Real helper measurements justify a small opening sentence for medium
        // reads that formerly waited for one whole buffer. Leave long-read chunk
        // planning and short/unsentenced selections unchanged. No text is lost.
        let earlierSentence = earlierFirstSentence && text.utf8.count <= limits.bytes
            && text.split(whereSeparator: { $0.isWhitespace }).count <= limits.words
            && text.split(whereSeparator: { $0.isWhitespace }).count > 16
        var chunks: [ProgressiveTextChunk] = []
        var start = text.startIndex
        while start < text.endIndex {
            if text[start].isWhitespace,
               text[start...].allSatisfy({ $0.isWhitespace }),
               let last = chunks.indices.last {
                // A sentence-preferred boundary may leave exterior whitespace
                // behind. Attach it once, subject to the helper input ceiling.
                let attached = text[chunks[last].range.lowerBound..<text.endIndex]
                guard attached.utf8.count <= Self.maximumSynthesisUTF8Bytes else {
                    throw ChunkError.unsupportedInput
                }
                chunks[last] = ProgressiveTextChunk(sequence: last, range: chunks[last].range.lowerBound..<text.endIndex)
                return chunks
            }
            var cursor = start
            var lastSentence: String.Index?
            var lastClause: String.Index?
            var lastWhitespace: String.Index?

            while cursor < text.endIndex {
                let next = text.index(after: cursor)
                let candidate = text[start..<next]
                let words = candidate.split(whereSeparator: { $0.isWhitespace }).count
                if candidate.utf8.count > limits.bytes || words > limits.words { break }

                cursor = next
                let characterIndex = text.index(before: next)
                let character = text[characterIndex]
                if character.isWhitespace {
                    lastWhitespace = next
                } else if isSentenceBoundary(character, at: characterIndex, in: text) {
                    lastSentence = next
                    if earlierSentence, chunks.isEmpty, (4...16).contains(words), next < text.endIndex { break }
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
            if end > start, text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               end == text.endIndex, let last = chunks.indices.last {
                // Preserve exterior trailing whitespace in the preceding spoken
                // request, never as a blank request. This is an exact-range
                // policy exception to conservative spoken-content sizing only;
                // it remains under the helper's independent 1,024-byte guard.
                let attached = text[chunks[last].range.lowerBound..<end]
                guard attached.utf8.count <= Self.maximumSynthesisUTF8Bytes else {
                    throw ChunkError.unsupportedInput
                }
                chunks[last] = ProgressiveTextChunk(sequence: last, range: chunks[last].range.lowerBound..<end)
                return chunks
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

    /// Splits a helper-rejected range only at a source boundary. This is used
    /// solely for the helper's explicit overlong-audio signal, never as a
    /// blanket recovery for malformed input or synthesis errors.
    func split(_ chunk: ProgressiveTextChunk, in text: String) throws -> [ProgressiveTextChunk] {
        let source = text[chunk.range]
        let midpoint = source.utf8.count / 2
        var cursor = chunk.range.lowerBound
        var bytes = 0
        var candidates: [(index: String.Index, priority: Int, distance: Int)] = []
        while cursor < chunk.range.upperBound {
            let next = text.index(after: cursor)
            bytes += text[cursor..<next].utf8.count
            let character = text[cursor]
            let priority: Int?
            if isSentenceBoundary(character, at: cursor, in: text) { priority = 0 }
            else if isClauseBoundary(character, at: cursor, in: text) { priority = 1 }
            else if character.isWhitespace { priority = 2 }
            else { priority = nil }
            if let priority, next > chunk.range.lowerBound, next < chunk.range.upperBound,
               !text[chunk.range.lowerBound..<next].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !text[next..<chunk.range.upperBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidates.append((next, priority, abs(bytes - midpoint)))
            }
            cursor = next
        }
        guard let split = candidates.min(by: { lhs, rhs in
            lhs.distance == rhs.distance ? lhs.priority < rhs.priority : lhs.distance < rhs.distance
        })?.index else { throw ChunkError.unsupportedInput }
        return [
            ProgressiveTextChunk(sequence: chunk.sequence, range: chunk.range.lowerBound..<split),
            ProgressiveTextChunk(sequence: chunk.sequence + 1, range: split..<chunk.range.upperBound)
        ]
    }

    private func chunkLimits(for request: TextToSpeechRequest?) -> (bytes: Int, words: Int) {
        guard request?.voice == .af_nicole, request?.speed == .fast else {
            return (Self.maximumChunkUTF8Bytes, Self.maximumChunkWords)
        }
        return (Self.nicoleFastMaximumChunkUTF8Bytes, Self.nicoleFastMaximumChunkWords)
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
    private var playbackStarted: (() -> Void)?
    private let timing: (String, TimeInterval) -> Void
    private var playbackWaiter: PlaybackWaiter?
    private var pendingPlaybackIdentity: (request: UUID, chunk: Int, tag: UUID)?
    private var earlyPlaybackResult: Result<Void, Error>?
    private struct GeneratedAudio {
        let data: Data
        let drainToken: UUID?
    }

    private struct GenerationHandle {
        let request: UUID
        let chunk: Int
        let identity: UUID
        let task: Task<GeneratedAudio, Error>
    }

    private final class ChunkPlan {
        var chunks: [ProgressiveTextChunk]
        init(_ chunks: [ProgressiveTextChunk]) { self.chunks = chunks }
    }

    private var generationTask: GenerationHandle?

    init(
        runtime: (any NativeKokoroRuntimeServing)? = nil,
        player: (any NativeTTSPlayback)? = nil,
        chunker: ProgressiveTextChunker = ProgressiveTextChunker(),
        timing: @escaping (String, TimeInterval) -> Void = ReadAloudTiming.log
    ) {
        self.runtime = runtime ?? NativeKokoroRuntimeClient()
        self.player = player ?? AVNativeTTSPlayer()
        self.chunker = chunker
        self.timing = timing
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
        try await speak(text, request: request, playbackStarted: {})
    }

    func speak(_ text: String, request: TextToSpeechRequest, playbackStarted: @escaping () -> Void) async throws {
        // Chunking and request ownership happen before startup. Unsupported input
        // cannot acquire an asset lease or helper.
        try Task.checkCancellation()
        guard activeRequest == nil else { throw TTSError.alreadySpeaking }
        let plan: ChunkPlan
        do { plan = ChunkPlan(try chunker.chunks(in: text, request: request)) }
        catch { throw TTSError.unsupportedText }

        let requestID = UUID()
        activeRequest = requestID
        self.playbackStarted = playbackStarted

        try await withTaskCancellationHandler {
            do {
                let preparationStart = ReadAloudTiming.now
                let snapshot = try await runtime.prepare(voiceID: request.voice.rawValue, speed: Float(request.speed.rawValue))
                try requireOwnership(requestID)
                timing("service.assets", ReadAloudTiming.now - preparationStart)

                var index = 0
                let synthesisStart = ReadAloudTiming.now
                var audio = try await synthesizeChunk(at: index, plan: plan, text: text, snapshot: snapshot, request: requestID)
                timing("service.first_buffer", ReadAloudTiming.now - synthesisStart)
                while true {
                    try requireOwnership(requestID)
                    let tag = UUID() // distinct audio identity for every source range
                    try startPlayback(audio.data, request: requestID, chunk: index, tag: tag)
                    try requireOwnership(requestID) // Scheduling observers can cancel synchronously.

                    let nextIndex = index + 1
                    let lookahead: Task<GeneratedAudio, Error>?
                    if nextIndex < plan.chunks.count {
                        let task = Task { @MainActor [weak self] in
                            guard let self else { throw CancellationError() }
                            return try await self.synthesizeChunk(at: nextIndex, plan: plan, text: text, snapshot: snapshot, request: requestID)
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
                    runtime.playbackDrained(token: audio.drainToken)

                    guard let lookahead else { break }
                    let generationIdentity = generationTask.flatMap {
                        $0.request == requestID && $0.chunk == nextIndex ? $0.identity : nil
                    }
                    audio = try await lookahead.value
                    clearGeneration(request: requestID, chunk: nextIndex, identity: generationIdentity)
                    try validateAudio(audio.data)
                    try requireOwnership(requestID)
                    index = nextIndex
                }

                try requireOwnership(requestID)
                clearGeneration(request: requestID)
                activeRequest = nil
                self.playbackStarted = nil
            } catch {
                if activeRequest == requestID {
                    activeRequest = nil // invalidate before playback/helper cleanup
                    self.playbackStarted = nil
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

    private func synthesize(_ source: Substring, snapshot: NativeKokoroAssetSnapshot, request: UUID) async throws -> GeneratedAudio {
        let audio = try await runtime.synthesize(text: String(source), snapshot: snapshot)
        let drainToken = runtime.capturePlaybackDrainToken()
        try requireOwnership(request)
        try validateAudio(audio)
        return GeneratedAudio(data: audio, drainToken: drainToken)
    }

    private func synthesizeChunk(at index: Int, plan: ChunkPlan, text: String,
                                 snapshot: NativeKokoroAssetSnapshot, request: UUID) async throws -> GeneratedAudio {
        do {
            return try await synthesize(text[plan.chunks[index].range], snapshot: snapshot, request: request)
        } catch {
            guard isOverlongAudio(error), plan.chunks.count < ProgressiveTextChunker.maximumChunks else { throw error }
            let split = try chunker.split(plan.chunks[index], in: text)
            plan.chunks.replaceSubrange(index...index, with: split)
            for sequence in plan.chunks.indices { plan.chunks[sequence] = ProgressiveTextChunk(sequence: sequence, range: plan.chunks[sequence].range) }
            try requireOwnership(request)
            return try await synthesizeChunk(at: index, plan: plan, text: text, snapshot: snapshot, request: request)
        }
    }

    private func isOverlongAudio(_ error: Error) -> Bool {
        guard case NativeKokoroReadError.helperFailed(.samplesTooLong) = error else { return false }
        return true
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
        let start = ReadAloudTiming.now
        do {
            try player.play(wav: wav, tag: tag)
            timing("playback.schedule", ReadAloudTiming.now - start)
        }
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
        case .started(let tag):
            guard let pending = pendingPlaybackIdentity,
                  activeRequest == pending.request, pending.tag == tag else { return }
            let callback = playbackStarted
            playbackStarted = nil // First scheduling event only, even for progressive reads.
            callback?()
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
        playbackStarted = nil
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
