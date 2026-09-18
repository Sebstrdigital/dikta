import XCTest
@testable import Dikta

/// `DebriefLiveSession` end to end, with a fake transcription engine, a fake
/// delta summarizer and the existing fake single-pass summarizer. Nothing here
/// touches WhisperKit, Ollama, Foundation Models, the network or the real
/// `~/Documents/Dikta`.
///
/// Chunk boundaries are forced with a deliberately tiny `ChunkingConfig`: a
/// 1-second target, a silence search window too short to ever hold a
/// `minSilenceSeconds` run, and no overlap. Every cut is therefore a hard cut
/// at exactly the target mark, so chunk count is a pure function of how many
/// samples were appended.
@MainActor
final class DebriefLiveSessionTests: XCTestCase {
    private var tempDir: URL!
    private var store: DebriefStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = DebriefStore(rootDirectory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        store = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func chunkEverySecond() -> ChunkingConfig {
        var config = ChunkingConfig()
        config.targetChunkSeconds = 1
        // Shorter than `minSilenceSeconds`, so no silence cut can ever win and
        // every boundary lands on the target mark.
        config.silenceSearchSeconds = 0.1
        config.overlapSeconds = 0
        return config
    }

    private func sampleSummary() -> DebriefSummary {
        DebriefSummary(
            summary: "Single pass summary.",
            decisions: [],
            actionItems: [],
            openQuestions: []
        )
    }

    private func audio(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    private func segment(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    private struct Fixture {
        let pipeline: DebriefPipeline
        let engine: FakeTranscriptionEngine
        let singlePass: FakeDebriefSummarizer
        let delta: FakeDeltaSummarizer
    }

    private func makeFixture(transcriptionTimeout: TimeInterval = 1800) -> Fixture {
        let engine = FakeTranscriptionEngine()
        let singlePass = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(sampleSummary()))
        let delta = FakeDeltaSummarizer()
        let pipeline = DebriefPipeline(
            engine: engine,
            summarizer: singlePass,
            store: store,
            transcriptionTimeout: transcriptionTimeout,
            chunking: chunkEverySecond(),
            makeDeltaSummarizer: { delta }
        )
        return Fixture(pipeline: pipeline, engine: engine, singlePass: singlePass, delta: delta)
    }

    // MARK: - Single chunk → single-pass, byte-identical behaviour

    func test_finish_singleChunk_usesSinglePassSummarizerAndNeverTouchesRolling() async throws {
        let fixture = makeFixture()
        fixture.engine.segmentsToReturn = [segment("So the migration meeting just wrapped up.", 0, 0.5)]

        let session = try fixture.pipeline.startLiveSession(
            tracks: [.me],
            language: "en",
            micSensitivity: .normal
        )
        session.append(audio(seconds: 0.5), track: .me)

        var stages: [DebriefStage] = []
        let result = try await session.finish { stages.append($0) }

        XCTAssertEqual(fixture.singlePass.summarizeCallCount, 1)
        XCTAssertEqual(
            fixture.singlePass.summarizeCalls.first?.transcript,
            "So the migration meeting just wrapped up."
        )
        XCTAssertEqual(fixture.singlePass.summarizeCalls.first?.language, "en")
        XCTAssertEqual(result.transcript, "So the migration meeting just wrapped up.")
        XCTAssertEqual(result.engineName, "Fake")
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")

        // The rolling summarizer must not have been called at all: chunk 0 is
        // held back precisely so a short recording never pays for it.
        XCTAssertTrue(fixture.delta.seenChunks.isEmpty, "\(fixture.delta.seenChunks)")
        XCTAssertEqual(fixture.delta.consolidateCallCount, 0)

        // Same stages, in the same order, as the pre-chunking path.
        XCTAssertEqual(stages, [.summarizing, .saving])
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.paths.transcript.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.paths.summary.path))
    }

    // MARK: - Several chunks → rolling

    func test_finish_threeChunks_ingestsEachChunkInOrderAndReturnsTheRollingSummary() async throws {
        let fixture = makeFixture()
        fixture.engine.segmentsPerCall = [
            [segment("first chunk", 0, 1)],
            [segment("second chunk", 0, 1)],
            [segment("third chunk", 0, 1)],
        ]
        fixture.delta.consolidationResult = ConsolidationDelta(summary: "Rolled up.", dropIds: [])

        let session = try fixture.pipeline.startLiveSession(
            tracks: [.me],
            language: "en",
            micSensitivity: .normal
        )
        session.append(audio(seconds: 3), track: .me)

        let result = try await session.finish { _ in }

        XCTAssertEqual(fixture.singlePass.summarizeCallCount, 0, "a multi-chunk run must not use the single-pass path")
        XCTAssertEqual(fixture.delta.seenChunks, ["first chunk", "second chunk", "third chunk"])
        XCTAssertEqual(fixture.delta.consolidateCallCount, 1)
        XCTAssertEqual(result.summary.summary, "Rolled up.")
        XCTAssertEqual(result.engineName, "Fake (rolling)")
        XCTAssertEqual(result.transcript, "first chunk second chunk third chunk")
    }

    // MARK: - Rendering

    func test_twoTrackSession_rendersALabeledTranscript() async throws {
        let fixture = makeFixture()
        // One chunk, two tracks: the chunk transcribes `.me` then `.them`.
        fixture.engine.segmentsPerCall = [
            [segment("Did you see the migration plan?", 0, 0.4)],
            [segment("Yes, it landed this morning.", 0.5, 0.9)],
        ]

        let session = try fixture.pipeline.startLiveSession(
            tracks: [.me, .them],
            language: "en",
            micSensitivity: .normal
        )
        session.append(audio(seconds: 0.5), track: .me)
        session.append(audio(seconds: 0.5), track: .them)

        let result = try await session.finish { _ in }

        XCTAssertEqual(
            result.transcript,
            "Me: Did you see the migration plan?\n\nThem: Yes, it landed this morning."
        )
        XCTAssertTrue(TwoTrackMerger.isLabeledTranscript(result.transcript))
    }

    func test_singleTrackSession_rendersAnUnlabeledTranscript() async throws {
        let fixture = makeFixture()
        fixture.engine.segmentsToReturn = [
            segment("First thought.", 0, 0.2),
            segment("Second thought.", 0.2, 0.4),
        ]

        let session = try fixture.pipeline.startLiveSession(
            tracks: [.me],
            language: "en",
            micSensitivity: .normal
        )
        session.append(audio(seconds: 0.5), track: .me)

        let result = try await session.finish { _ in }

        XCTAssertEqual(result.transcript, "First thought. Second thought.")
        XCTAssertFalse(TwoTrackMerger.isLabeledTranscript(result.transcript))
    }

    func test_renderChunk_singleTrackConcatenates_twoTracksLabel() {
        let segments: [DebriefTrack: [TranscriptSegment]] = [
            .me: [segment("  hello  ", 0, 1), segment("", 1, 2), segment("world", 2, 3)],
            .them: [segment("hi", 0.5, 1.5)],
        ]

        XCTAssertEqual(DebriefLiveSession.renderChunk(segments, tracks: [.me]), "hello world")
        XCTAssertEqual(
            DebriefLiveSession.renderChunk(segments, tracks: [.me, .them]),
            "Me: hello\n\nThem: hi\n\nMe: world"
        )
    }

    // MARK: - Timeout

    func test_finish_transcriptionTimeout_summarizesTheChunksThatCompletedAndRecordsTheIssue() async throws {
        // `finishTimeout` is `max(pipelineTimeout, floor)`, so the pipeline's
        // own budget has to be the small one for the floor to bite.
        let fixture = makeFixture(transcriptionTimeout: 0.1)
        fixture.engine.segmentsPerCall = [
            [segment("the part that made it", 0, 1)],
            [segment("the part that did not", 0, 1)],
        ]
        // Two chunks close during the append and their jobs run serially. The
        // first returns at once; the second is held open well past the floor
        // below, so which chunks are done at the cutoff is decided here rather
        // than by how fast the machine happens to be.
        fixture.engine.beforeSegmentsReturn = { callIndex in
            guard callIndex > 0 else { return }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }

        let session = try fixture.pipeline.startLiveSession(
            tracks: [.me],
            language: "en",
            micSensitivity: .normal,
            finishTimeoutFloor: 1
        )
        session.append(audio(seconds: 2), track: .me)

        let result = try await session.finish { _ in }

        XCTAssertEqual(result.transcript, "the part that made it")
        XCTAssertEqual(fixture.singlePass.summarizeCallCount, 1, "\(result.issues)")
        XCTAssertTrue(
            result.issues.contains { $0.contains("timed out") },
            "expected a timeout issue, got \(result.issues)"
        )
    }

    // MARK: - The pipeline's own entry points, above one chunk

    /// The long-import gap decision 11 exists to close: a recording longer
    /// than one chunk must not reach the engine (or the summarizer's context
    /// window) whole. `run(samples:)` has to route it through the live
    /// session, which means several `transcribeSegments` calls and a rolling
    /// summary — not one `transcribe` call and one single-pass summarize.
    func test_run_audioLongerThanOneChunk_goesThroughTheLiveSessionAndRollsUp() async throws {
        let fixture = makeFixture()
        fixture.engine.transcriptToReturn = "the whole-recording path must not be used"
        fixture.engine.segmentsPerCall = [
            [segment("opening", 0, 1)],
            [segment("middle", 0, 1)],
            [segment("closing", 0, 1)],
        ]
        fixture.delta.consolidationResult = ConsolidationDelta(summary: "Rolled up.", dropIds: [])

        // Three chunks at the 1-second target from `chunkEverySecond()`.
        let result = try await fixture.pipeline.run(
            samples: audio(seconds: 3),
            language: "en",
            micSensitivity: .normal
        ) { _ in }

        XCTAssertEqual(fixture.engine.transcribeCallCount, 0, "the whole-recording path must not run")
        XCTAssertEqual(fixture.engine.receivedSegmentSampleCounts.count, 3)
        XCTAssertEqual(fixture.delta.seenChunks, ["opening", "middle", "closing"])
        XCTAssertEqual(fixture.delta.consolidateCallCount, 1)
        XCTAssertEqual(fixture.singlePass.summarizeCallCount, 0)
        XCTAssertEqual(result.summary.summary, "Rolled up.")
        XCTAssertEqual(result.transcript, "opening middle closing")
        XCTAssertFalse(TwoTrackMerger.isLabeledTranscript(result.transcript))
    }

    /// Below the same threshold, `run(samples:)` keeps the pre-chunking
    /// behaviour exactly: one `transcribe` call, one single-pass summarize,
    /// rolling untouched.
    func test_run_audioUnderOneChunk_keepsTheWholeRecordingPath() async throws {
        let fixture = makeFixture()
        fixture.engine.transcriptToReturn = "a short debrief"

        let result = try await fixture.pipeline.run(
            samples: audio(seconds: 0.5),
            language: "en",
            micSensitivity: .normal
        ) { _ in }

        XCTAssertEqual(fixture.engine.transcribeCallCount, 1)
        XCTAssertTrue(fixture.engine.receivedSegmentSampleCounts.isEmpty)
        XCTAssertEqual(fixture.singlePass.summarizeCallCount, 1)
        XCTAssertTrue(fixture.delta.seenChunks.isEmpty)
        XCTAssertEqual(result.transcript, "a short debrief")
    }

    /// The same rule for a call already on disk: two long tracks are replayed
    /// through the live session, interleaved, and come out as one labeled
    /// transcript summarized by the rolling path.
    func test_runTwoTrack_tracksLongerThanOneChunk_goThroughTheLiveSessionAndStayLabeled() async throws {
        let paths = try store.createSession()
        for track in [DebriefTrack.me, .them] {
            let writer = try store.makeStreamingWriter(for: track, in: paths)
            try writer.append(audio(seconds: 3))
            try writer.close()
        }

        let fixture = makeFixture()
        fixture.engine.segmentsToReturn = [segment("a line", 0, 0.5)]
        fixture.delta.consolidationResult = ConsolidationDelta(summary: "Call rolled up.", dropIds: [])

        let result = try await fixture.pipeline.runTwoTrack(
            paths: paths,
            language: "en",
            micSensitivity: .normal
        ) { _ in }

        // Three chunks x two tracks: the whole-recording path would have made
        // exactly two calls, one per track.
        XCTAssertEqual(fixture.engine.receivedSegmentSampleCounts.count, 6)
        XCTAssertEqual(fixture.delta.seenChunks.count, 3)
        XCTAssertEqual(fixture.delta.consolidateCallCount, 1)
        XCTAssertEqual(fixture.singlePass.summarizeCallCount, 0)
        XCTAssertEqual(result.summary.summary, "Call rolled up.")
        XCTAssertTrue(
            TwoTrackMerger.isLabeledTranscript(result.transcript),
            "two-track output must stay labeled, got:\n\(result.transcript)"
        )
        XCTAssertTrue(result.transcript.contains("Them:"), result.transcript)
    }

    // MARK: - Re-running a crashed call from disk

    func test_callSessionFolder_recognisesAFolderOrEitherTrack_butNotASingleRecording() throws {
        let fileManager = FileManager.default
        let call = tempDir.appendingPathComponent("call-session")
        try fileManager.createDirectory(at: call, withIntermediateDirectories: true)
        let callPaths = DebriefSessionPaths(folder: call)
        for track in [DebriefTrack.me, .them] {
            try Data().write(to: callPaths.audioURL(for: track))
        }

        // Compared by path: deriving the folder from a WAV leaves a trailing
        // slash on the URL that the directory URL itself does not carry.
        XCTAssertEqual(MenuBarViewModel.callSessionFolder(for: call)?.path, call.path)
        XCTAssertEqual(MenuBarViewModel.callSessionFolder(for: callPaths.audioURL(for: .me))?.path, call.path)
        XCTAssertEqual(MenuBarViewModel.callSessionFolder(for: callPaths.audioURL(for: .them))?.path, call.path)

        // A single-track debrief session, and a stray recording, import as before.
        let mic = tempDir.appendingPathComponent("mic-session")
        try fileManager.createDirectory(at: mic, withIntermediateDirectories: true)
        let micPaths = DebriefSessionPaths(folder: mic)
        try Data().write(to: micPaths.audio)
        XCTAssertNil(MenuBarViewModel.callSessionFolder(for: mic))
        XCTAssertNil(MenuBarViewModel.callSessionFolder(for: micPaths.audio))

        // Half a call is not a call.
        let halfCall = tempDir.appendingPathComponent("half-call")
        try fileManager.createDirectory(at: halfCall, withIntermediateDirectories: true)
        try Data().write(to: DebriefSessionPaths(folder: halfCall).audioURL(for: .me))
        XCTAssertNil(MenuBarViewModel.callSessionFolder(for: halfCall))

        XCTAssertNil(MenuBarViewModel.callSessionFolder(for: tempDir.appendingPathComponent("nope.wav")))
    }

    // MARK: - Non-fatal ingest failure

    func test_finish_rollingIngestFailure_isRecordedButNeverFatal() async throws {
        let fixture = makeFixture()
        fixture.engine.segmentsPerCall = [
            [segment("first chunk", 0, 1)],
            [segment("second chunk", 0, 1)],
        ]
        // A non-`DeltaSummarizerError` skips the actor's own retry ladder and
        // reaches the live session's catch.
        fixture.delta.extractError = URLError(.notConnectedToInternet)
        fixture.delta.consolidationResult = ConsolidationDelta(summary: "Salvaged.", dropIds: [])

        let session = try fixture.pipeline.startLiveSession(
            tracks: [.me],
            language: "en",
            micSensitivity: .normal
        )
        session.append(audio(seconds: 2), track: .me)

        let result = try await session.finish { _ in }

        XCTAssertEqual(result.summary.summary, "Salvaged.")
        XCTAssertEqual(
            result.issues.filter { $0.contains("rolling ingest failed") }.count,
            2,
            "\(result.issues)"
        )
        XCTAssertEqual(fixture.singlePass.summarizeCallCount, 0)
    }
}
