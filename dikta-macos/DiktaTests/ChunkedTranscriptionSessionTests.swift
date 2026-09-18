import XCTest
@testable import Dikta

// MARK: - Synthetic audio with a decodable second marker

/// Builds 16 kHz mono audio where every whole second carries its own absolute
/// index as a DC amplitude, so a fake engine can report which second of the
/// *session* it was handed. That makes chunk ownership checkable end to end.
enum MarkerAudio {
    static let sampleRate = 16_000

    /// One second of "speech" whose amplitude encodes `second`.
    static func voiced(_ second: Int) -> [Float] {
        [Float](repeating: 0.1 + 0.001 * Float(second), count: sampleRate)
    }

    /// `count` seconds of digital silence (RMS 0).
    static func silence(seconds count: Int) -> [Float] {
        [Float](repeating: 0, count: sampleRate * count)
    }

    /// `seconds` of voiced audio, indices 0..<seconds, with `silentSeconds`
    /// replaced by silence.
    static func session(seconds: Int, silentSeconds: Set<Int> = []) -> [Float] {
        var out: [Float] = []
        for second in 0..<seconds {
            out += silentSeconds.contains(second) ? silence(seconds: 1) : voiced(second)
        }
        return out
    }

    /// Fractional tail, voiced, marker index `second`.
    static func partial(_ second: Int, seconds: Double) -> [Float] {
        [Float](repeating: 0.1 + 0.001 * Float(second), count: Int(Double(sampleRate) * seconds))
    }

    /// Inverse of `voiced`: one segment per full second of the samples passed,
    /// timestamps relative to those samples, text = the absolute session second
    /// recovered from the marker. Silent seconds produce nothing.
    static func decode(_ samples: [Float]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var index = 0
        while (index + 1) * sampleRate <= samples.count {
            let slice = samples[(index * sampleRate)..<((index + 1) * sampleRate)]
            let mean = slice.reduce(Float(0)) { $0 + abs($1) } / Float(sampleRate)
            if mean > 0.05 {
                let second = Int(((mean - 0.1) / 0.001).rounded())
                segments.append(TranscriptSegment(start: Double(index), end: Double(index) + 1, text: "\(second)"))
            }
            index += 1
        }
        return segments
    }
}

enum MarkerEngineError: Error, LocalizedError {
    case boom
    var errorDescription: String? { "boom" }
}

/// Engine double that decodes `MarkerAudio` and records what it was handed.
@MainActor
final class MarkerTranscriptionEngine: TranscriptionEngine {
    var isLoading = false
    var isReady = true
    var errorMessage: String?
    var downloadProgress: Double?

    func load() async {}
    func reload(model: WhisperModel) async throws {}
    func transcribe(_ audioSamples: [Float], language: String?, micSensitivity: MicSensitivity) async throws -> String { "" }

    /// `transcribeSegments` call indices that should throw.
    var failingCalls: Set<Int> = []
    /// When non-nil, every call whose samples came from this track throws.
    /// The session hands tracks to the engine in declaration order, so the
    /// call index modulo the track count identifies the track.
    var failingTrackStride: (offset: Int, stride: Int)?
    /// Artificial delay per call index.
    var delays: [Int: TimeInterval] = [:]

    private(set) var receivedSampleCounts: [Int] = []
    private(set) var receivedPrompts: [String?] = []
    private(set) var callCount = 0

    func transcribeSegments(
        _ samples: [Float],
        language: String?,
        micSensitivity: MicSensitivity,
        promptText: String?
    ) async throws -> [TranscriptSegment] {
        let call = callCount
        callCount += 1
        receivedSampleCounts.append(samples.count)
        receivedPrompts.append(promptText)
        if let delay = delays[call], delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if failingCalls.contains(call) { throw MarkerEngineError.boom }
        if let rule = failingTrackStride, call % rule.stride == rule.offset { throw MarkerEngineError.boom }
        return MarkerAudio.decode(samples)
    }
}

/// Engine double that replays a fixed script, for exact boundary arithmetic.
@MainActor
final class ScriptedTranscriptionEngine: TranscriptionEngine {
    var isLoading = false
    var isReady = true
    var errorMessage: String?
    var downloadProgress: Double?

    func load() async {}
    func reload(model: WhisperModel) async throws {}
    func transcribe(_ audioSamples: [Float], language: String?, micSensitivity: MicSensitivity) async throws -> String { "" }

    /// Segments returned per call index, timestamps relative to the samples passed.
    var scripts: [[TranscriptSegment]] = []
    private(set) var callCount = 0

    func transcribeSegments(
        _ samples: [Float],
        language: String?,
        micSensitivity: MicSensitivity,
        promptText: String?
    ) async throws -> [TranscriptSegment] {
        defer { callCount += 1 }
        return callCount < scripts.count ? scripts[callCount] : []
    }
}

// MARK: - Tests

@MainActor
final class ChunkedTranscriptionSessionTests: XCTestCase {

    private func makeConfig(
        target: TimeInterval,
        search: TimeInterval = 1,
        minSilence: TimeInterval = 0.4,
        overlap: TimeInterval = 1,
        promptContinuation: Bool = false,
        promptTailWords: Int = 30,
        staleTrack: TimeInterval = 10
    ) -> ChunkingConfig {
        var config = ChunkingConfig()
        config.targetChunkSeconds = target
        config.silenceSearchSeconds = search
        config.minSilenceSeconds = minSilence
        config.silenceRMS = 0.01
        config.overlapSeconds = overlap
        config.promptContinuation = promptContinuation
        config.promptTailWords = promptTailWords
        config.staleTrackSeconds = staleTrack
        return config
    }

    private func texts(_ transcript: ChunkedTranscript, _ track: DebriefTrack) -> [String] {
        (transcript.segments[track] ?? []).map(\.text)
    }

    // MARK: Defaults

    func testConfigDefaultsMatchTheDesign() {
        let config = ChunkingConfig()
        XCTAssertEqual(config.targetChunkSeconds, 300)
        XCTAssertEqual(config.silenceSearchSeconds, 30)
        XCTAssertEqual(config.minSilenceSeconds, 0.4)
        XCTAssertEqual(config.silenceRMS, 0.01)
        XCTAssertEqual(config.overlapSeconds, 3)
        XCTAssertFalse(config.promptContinuation)
        XCTAssertEqual(config.promptTailWords, 30)
        XCTAssertEqual(config.staleTrackSeconds, 10)
    }

    // MARK: Cut selection

    /// Seconds 3 and 4 are silent, inside the ±1 s window around the 4 s
    /// target: the cut lands on the centre of that run (4.0) with no overlap.
    /// The next chunk has no silence in range, so it is a hard cut with ears.
    func testSilenceAlignedCutChosenWhenGapExistsOtherwiseHardCut() async throws {
        let engine = MarkerTranscriptionEngine()
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me],
            language: "en",
            micSensitivity: .normal,
            config: makeConfig(target: 4, search: 2)
        )

        session.append(MarkerAudio.session(seconds: 10, silentSeconds: [3, 4]), track: .me)
        let transcript = try await session.finish()

        XCTAssertEqual(transcript.chunks.count, 3)

        XCTAssertTrue(transcript.chunks[0].cutAtSilence)
        XCTAssertFalse(transcript.chunks[0].overlapped)
        XCTAssertEqual(transcript.chunks[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(transcript.chunks[0].endSeconds, 4, accuracy: 0.001)

        XCTAssertFalse(transcript.chunks[1].cutAtSilence)
        XCTAssertTrue(transcript.chunks[1].overlapped)
        XCTAssertEqual(transcript.chunks[1].startSeconds, 4, accuracy: 0.001)
        XCTAssertEqual(transcript.chunks[1].endSeconds, 8, accuracy: 0.001)

        XCTAssertEqual(transcript.chunks[2].startSeconds, 8, accuracy: 0.001)
        XCTAssertEqual(transcript.chunks[2].endSeconds, 10, accuracy: 0.001)

        // Silent seconds 3 and 4 produce nothing; everything else appears once.
        XCTAssertEqual(texts(transcript, .me), ["0", "1", "2", "5", "6", "7", "8", "9"])
    }

    /// Both tracks are sliced at the same absolute sample index even when their
    /// buffers arrive in different block sizes.
    func testCutIndexIsIdenticalAcrossTwoTracks() async throws {
        let engine = MarkerTranscriptionEngine()
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me, .them],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2)
        )

        session.append(MarkerAudio.session(seconds: 9), track: .me)
        let them = MarkerAudio.session(seconds: 9)
        let half = MarkerAudio.sampleRate / 2
        for block in stride(from: 0, to: them.count, by: half) {
            session.append(Array(them[block..<min(block + half, them.count)]), track: .them)
        }
        let transcript = try await session.finish()

        XCTAssertEqual(transcript.chunks.count, 5)
        let counts = engine.receivedSampleCounts
        XCTAssertEqual(counts.count, transcript.chunks.count * 2)
        // Calls alternate me/them per chunk; same chunk ⇒ same sample count.
        for chunk in 0..<transcript.chunks.count {
            XCTAssertEqual(counts[chunk * 2], counts[chunk * 2 + 1], "chunk \(chunk) sliced differently per track")
        }
        XCTAssertEqual(texts(transcript, .me), texts(transcript, .them))
    }

    // MARK: No loss / no duplicate

    /// 24 s of continuous speech with no silence anywhere: every chunk is a
    /// hard cut with 1 s ears. The union of the returned texts must be exactly
    /// the set of second indices, each appearing once.
    func testHardCutChunksLoseAndDuplicateNothing() async throws {
        let engine = MarkerTranscriptionEngine()
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2)
        )

        session.append(MarkerAudio.session(seconds: 24), track: .me)
        let transcript = try await session.finish()

        XCTAssertGreaterThanOrEqual(transcript.chunks.count, 10)
        XCTAssertTrue(transcript.chunks.dropLast().allSatisfy { $0.overlapped })

        let returned = texts(transcript, .me)
        XCTAssertEqual(returned, (0..<24).map(String.init), "segments must be complete, in order, with no repeats")
        XCTAssertEqual(Set(returned).count, returned.count, "a second was transcribed twice")

        // Nominal ranges tile the session with no gap and no overlap.
        for (index, chunk) in transcript.chunks.enumerated() where index > 0 {
            XCTAssertEqual(chunk.startSeconds, transcript.chunks[index - 1].endSeconds, accuracy: 0.001)
        }
        XCTAssertEqual(transcript.chunks.first?.startSeconds ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(transcript.chunks.last?.endSeconds ?? -1, 24, accuracy: 0.001)
    }

    // MARK: Midpoint ownership

    /// A segment belongs to the chunk containing its midpoint; a midpoint that
    /// lands exactly on the boundary belongs to the later chunk (ranges are
    /// half-open).
    func testMidpointOwnershipAtChunkBoundaries() async throws {
        let engine = ScriptedTranscriptionEngine()
        // Chunk 0 nominal [0,2), engine fed [0,3). Chunk 1 nominal [2,4),
        // engine fed [1,5) so its timestamps are offset by 1 s.
        engine.scripts = [
            [
                TranscriptSegment(start: 0.5, end: 1.4, text: "c0-inside"),
                TranscriptSegment(start: 1.5, end: 2.5, text: "c0-midpoint-on-end"),
                TranscriptSegment(start: 2.2, end: 2.8, text: "c0-after-end")
            ],
            [
                TranscriptSegment(start: 0.9, end: 1.1, text: "c1-midpoint-on-start"),
                TranscriptSegment(start: 0.0, end: 0.5, text: "c1-before-start"),
                TranscriptSegment(start: 2.9, end: 3.1, text: "c1-midpoint-on-end")
            ],
            [
                TranscriptSegment(start: 0.1, end: 0.9, text: "c2-inside")
            ]
        ]
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2)
        )

        session.append(MarkerAudio.session(seconds: 5), track: .me)
        let transcript = try await session.finish()

        XCTAssertEqual(transcript.chunks.map(\.startSeconds), [0, 2, 4])
        // c0-midpoint-on-end has midpoint 2.0 == chunk 0's end ⇒ chunk 1 owns
        // that instant, so chunk 0 drops it. c1-midpoint-on-start has absolute
        // midpoint 2.0 and is kept. No instant is owned twice.
        XCTAssertEqual(texts(transcript, .me), ["c0-inside", "c1-midpoint-on-start", "c2-inside"])
    }

    // MARK: Final partial chunk

    func testFinalPartialChunkAboveHalfASecondBecomesItsOwnChunk() async throws {
        let engine = MarkerTranscriptionEngine()
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2)
        )

        session.append(MarkerAudio.session(seconds: 5), track: .me)
        let transcript = try await session.finish()

        XCTAssertEqual(transcript.chunks.count, 3)
        XCTAssertEqual(transcript.chunks[2].startSeconds, 4, accuracy: 0.001)
        XCTAssertEqual(transcript.chunks[2].endSeconds, 5, accuracy: 0.001)
        XCTAssertFalse(transcript.chunks[2].overlapped)
        XCTAssertEqual(texts(transcript, .me), ["0", "1", "2", "3", "4"])
    }

    func testFinalRemnantShorterThanHalfASecondIsFoldedIntoPreviousChunk() async throws {
        let engine = MarkerTranscriptionEngine()
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2, overlap: 0.2)
        )

        session.append(MarkerAudio.session(seconds: 2), track: .me)
        session.append(MarkerAudio.partial(2, seconds: 0.3), track: .me)
        let transcript = try await session.finish()

        XCTAssertEqual(transcript.chunks.count, 1, "0.3 s must not get a chunk of its own")
        XCTAssertEqual(transcript.chunks[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(transcript.chunks[0].endSeconds, 2.3, accuracy: 0.001, "the remnant is folded in, leaving no gap")
    }

    func testRemnantShorterThanHalfASecondIsDroppedWhenItIsTheOnlyAudio() async throws {
        let engine = MarkerTranscriptionEngine()
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2)
        )

        session.append(MarkerAudio.partial(0, seconds: 0.3), track: .me)
        let transcript = try await session.finish()

        XCTAssertTrue(transcript.chunks.isEmpty)
        XCTAssertEqual(transcript.segments[.me], [])
        XCTAssertEqual(engine.callCount, 0)
    }

    // MARK: Single track

    func testSingleTrackSessionReturnsOnlyThatTrack() async throws {
        let engine = MarkerTranscriptionEngine()
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.them],
            language: nil,
            micSensitivity: .headset,
            config: makeConfig(target: 2)
        )

        session.append(MarkerAudio.session(seconds: 6), track: .them)
        // Audio for a track the session does not own is ignored.
        session.append(MarkerAudio.session(seconds: 6), track: .me)
        let transcript = try await session.finish()

        XCTAssertEqual(Set(transcript.segments.keys), [.them])
        XCTAssertEqual(texts(transcript, .them), ["0", "1", "2", "3", "4", "5"])
    }

    // MARK: Errors

    func testEngineErrorOnOneChunkIsRecordedAndTheSessionContinues() async throws {
        let engine = MarkerTranscriptionEngine()
        engine.failingCalls = [1]
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2)
        )

        session.append(MarkerAudio.session(seconds: 8), track: .me)
        let transcript = try await session.finish()

        XCTAssertEqual(transcript.chunks.count, 4)
        XCTAssertNotNil(transcript.chunks[1].errors[.me])
        XCTAssertTrue(transcript.chunks[0].errors.isEmpty)
        XCTAssertTrue(transcript.chunks[3].errors.isEmpty)
        // Only the failed chunk's seconds (2, 3) are missing.
        XCTAssertEqual(texts(transcript, .me), ["0", "1", "4", "5", "6", "7"])
    }

    func testFinishThrowsOnlyWhenEveryChunkFailed() async {
        let engine = MarkerTranscriptionEngine()
        engine.failingCalls = [0, 1, 2, 3]
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2)
        )

        session.append(MarkerAudio.session(seconds: 8), track: .me)
        do {
            _ = try await session.finish()
            XCTFail("finish() should throw when every chunk failed")
        } catch {
            XCTAssertTrue("\(error)".contains("allChunksFailed"), "unexpected error: \(error)")
        }
    }


    // MARK: Lagging, dead and failing tracks

    /// Them stops 20 % early. Every sample Me recorded is still transcribed and
    /// Them is padded with silence, so sample index keeps meaning time.
    func testShorterTrackIsPaddedAndTheLongerTrackIsFullyTranscribed() async throws {
        let engine = MarkerTranscriptionEngine()
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me, .them],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2, staleTrack: 1)
        )

        // Both tracks stream together; Them stops 2 s (20 %) early.
        for second in 0..<10 {
            session.append(MarkerAudio.voiced(second), track: .me)
            if second < 8 { session.append(MarkerAudio.voiced(second), track: .them) }
        }
        let transcript = try await session.finish()

        XCTAssertEqual(texts(transcript, .me), (0..<10).map(String.init), "no sample of the longer track may be lost")
        XCTAssertEqual(texts(transcript, .them), (0..<8).map(String.init))
        XCTAssertEqual(transcript.chunks.last?.endSeconds ?? -1, 10, accuracy: 0.001)
        let paddedThem = transcript.chunks.reduce(0.0) { $0 + ($1.paddedSeconds[.them] ?? 0) }
        XCTAssertEqual(paddedThem, 2, accuracy: 0.05, "Them must be padded to the leader's length")
        XCTAssertEqual(transcript.chunks.reduce(0.0) { $0 + ($1.paddedSeconds[.me] ?? 0) }, 0, accuracy: 0.001)
    }

    /// A declared track that never produces a sample must not stall the session.
    func testDeclaredTrackThatNeverAppendsDoesNotStallTheSession() async throws {
        let engine = MarkerTranscriptionEngine()
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me, .them],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2, staleTrack: 1)
        )

        session.append(MarkerAudio.session(seconds: 8), track: .me)
        let transcript = try await session.finish()

        XCTAssertEqual(texts(transcript, .me), (0..<8).map(String.init))
        XCTAssertEqual(transcript.segments[.them], [], "a dead track contributes silence, not an error")
        XCTAssertGreaterThan(transcript.chunks.count, 1, "the dead track must not block cutting")
        XCTAssertGreaterThan(transcript.chunks.reduce(0.0) { $0 + ($1.paddedSeconds[.them] ?? 0) }, 0)
    }

    /// One track failing on every chunk still returns the other track in full.
    func testTrackFailingEveryChunkStillReturnsTheOtherTrack() async throws {
        let engine = MarkerTranscriptionEngine()
        // Tracks are handed to the engine in declaration order: .me is even,
        // .them is odd. Fail every .them call.
        engine.failingTrackStride = (offset: 1, stride: 2)
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me, .them],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2)
        )

        session.append(MarkerAudio.session(seconds: 8), track: .me)
        session.append(MarkerAudio.session(seconds: 8), track: .them)
        let transcript = try await session.finish()

        XCTAssertEqual(texts(transcript, .me), (0..<8).map(String.init))
        XCTAssertEqual(transcript.segments[.them], [])
        XCTAssertTrue(transcript.chunks.allSatisfy { $0.errors[.them] != nil })
        XCTAssertTrue(transcript.chunks.allSatisfy { $0.errors[.me] == nil })
    }

    // MARK: Ordering and callbacks

    func testFinishReturnsChunksAndSegmentsInOrderDespiteASlowFirstJob() async throws {
        let engine = MarkerTranscriptionEngine()
        engine.delays = [0: 0.3]
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2)
        )

        let lock = NSLock()
        var callbackOrder: [Int] = []
        session.onChunkTranscribed = { result in
            lock.lock(); callbackOrder.append(result.info.index); lock.unlock()
        }

        session.append(MarkerAudio.session(seconds: 8), track: .me)
        let transcript = try await session.finish()

        XCTAssertEqual(transcript.chunks.map(\.index), Array(0..<transcript.chunks.count))
        let starts = (transcript.segments[.me] ?? []).map(\.start)
        XCTAssertEqual(starts, starts.sorted())
        XCTAssertEqual(texts(transcript, .me), ["0", "1", "2", "3", "4", "5", "6", "7"])

        lock.lock(); let order = callbackOrder; lock.unlock()
        XCTAssertEqual(order, Array(0..<transcript.chunks.count), "onChunkTranscribed must fire in chunk order")
        XCTAssertNotNil(transcript.chunks[0].transcribeWallSeconds[.me])
        XCTAssertGreaterThan(transcript.chunks[0].transcribeWallSeconds[.me] ?? 0, 0.2)
    }

    // MARK: Prompt continuation

    func testPromptTailIsNotPassedWhenContinuationIsOff() async throws {
        let engine = MarkerTranscriptionEngine()
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2)
        )

        session.append(MarkerAudio.session(seconds: 8), track: .me)
        _ = try await session.finish()

        XCTAssertFalse(engine.receivedPrompts.isEmpty)
        XCTAssertTrue(engine.receivedPrompts.allSatisfy { $0 == nil })
    }

    func testPromptTailIsPassedFromTheSecondChunkWhenContinuationIsOn() async throws {
        let engine = MarkerTranscriptionEngine()
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2, promptContinuation: true, promptTailWords: 2)
        )

        session.append(MarkerAudio.session(seconds: 8), track: .me)
        _ = try await session.finish()

        XCTAssertGreaterThanOrEqual(engine.receivedPrompts.count, 3)
        XCTAssertNil(engine.receivedPrompts[0], "the first chunk has no predecessor")
        XCTAssertEqual(engine.receivedPrompts[1], "0 1")
        XCTAssertEqual(engine.receivedPrompts[2], "2 3")
    }

    // MARK: Back-pressure

    func testAppendReturnsImmediatelyWhileAJobIsSlow() async throws {
        let engine = MarkerTranscriptionEngine()
        engine.delays = [0: 0.3, 1: 0.3]
        let session = ChunkedTranscriptionSession(
            engine: engine,
            tracks: [.me],
            language: nil,
            micSensitivity: .normal,
            config: makeConfig(target: 2)
        )

        let started = Date()
        for second in 0..<8 {
            session.append(MarkerAudio.voiced(second), track: .me)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.15, "append must not wait on transcription (took \(elapsed)s)")

        let transcript = try await session.finish()
        XCTAssertEqual(texts(transcript, .me), ["0", "1", "2", "3", "4", "5", "6", "7"])
    }
}
