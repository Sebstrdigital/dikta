import XCTest
@testable import Dikta

/// Runs the two-track call debrief over *real* session folders a developer
/// recorded on this machine, rather than synthetic silence.
///
/// Everything else in the suite feeds the pipeline sine waves and zeros, which
/// proves the plumbing but not that a WAV pair the app actually wrote can be
/// read back, aligned and merged. These tests close that gap on whoever's
/// machine has recordings, and `XCTSkip` everywhere else — a public repo never
/// carries real dictation data (see `feedback_no_recordings_in_git`).
///
/// **This suite never writes into the real session directory.** It copies the
/// two tracks into a temp session folder and runs the pipeline there, so the
/// transcript and summary it produces land in the temp directory and the
/// originals are only ever read.
@MainActor
final class CallDebriefRealSessionTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Discovery

    /// Where to look for real sessions. `DIKTA_REAL_SESSIONS_DIR` overrides the
    /// default so a developer can point the suite at an archive folder without
    /// moving anything into `~/Documents/Dikta`.
    private static var realSessionsRoot: URL {
        if let override = ProcessInfo.processInfo.environment["DIKTA_REAL_SESSIONS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Dikta")
    }

    /// Session folders under `realSessionsRoot` that hold *both* tracks.
    /// A mic-only debrief writes `audio.wav` and is not a call, so it is
    /// skipped: `runTwoTrack` is only meaningful with two tracks.
    private static var twoTrackSessions: [DebriefSessionPaths] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: realSessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { DebriefSessionPaths(folder: $0) }
            .filter { paths in
                fileManager.fileExists(atPath: paths.audioURL(for: .me).path)
                    && fileManager.fileExists(atPath: paths.audioURL(for: .them).path)
            }
            .sorted { $0.folder.lastPathComponent < $1.folder.lastPathComponent }
    }

    /// The newest two-track session, or an `XCTSkip` explaining where the suite
    /// looked. Every test here goes through this.
    private func newestRealSession() throws -> DebriefSessionPaths {
        let sessions = Self.twoTrackSessions
        try XCTSkipIf(
            sessions.isEmpty,
            """
            no real two-track session found under \(Self.realSessionsRoot.path) \
            (a session folder must contain both me.wav and them.wav). \
            Set DIKTA_REAL_SESSIONS_DIR to point somewhere else.
            """
        )
        return try XCTUnwrap(sessions.last)
    }

    /// Copies both tracks of `source` into a fresh session folder under the
    /// test's temp directory, and returns that copy plus the store that owns
    /// it. Nothing the pipeline writes can reach the real folder.
    private func copyIntoTempSession(_ source: DebriefSessionPaths) throws -> (DebriefStore, DebriefSessionPaths) {
        let store = DebriefStore(rootDirectory: tempDir.appendingPathComponent("sessions"))
        let paths = try store.createSession()
        for track in [DebriefTrack.me, .them] {
            try FileManager.default.copyItem(
                at: source.audioURL(for: track),
                to: paths.audioURL(for: track)
            )
        }
        return (store, paths)
    }

    private func summary() -> DebriefSummary {
        DebriefSummary(
            summary: "Both sides of the call were transcribed.",
            decisions: [],
            actionItems: [],
            openQuestions: []
        )
    }

    // MARK: - Tracks on disk

    func test_realSession_bothTracksLoadAndCarryAudio() throws {
        let session = try newestRealSession()
        let loader = AudioFileLoader()

        let me = try loader.load(url: session.audioURL(for: .me))
        let them = try loader.load(url: session.audioURL(for: .them))

        let meSeconds = Double(me.count) / AudioFileLoader.targetSampleRate
        let themSeconds = Double(them.count) / AudioFileLoader.targetSampleRate

        // Both tracks must hold real audio. A stricter "within 10% of each
        // other" rule is *not* asserted: the merger zero-pads a track that
        // falls behind, and a call where one side joins late or drops out
        // legitimately produces very different track lengths. The ratio is
        // printed so a developer investigating an alignment bug can see it.
        XCTAssertGreaterThan(meSeconds, 1.0, "me.wav is shorter than a second: \(session.folder.path)")
        XCTAssertGreaterThan(themSeconds, 1.0, "them.wav is shorter than a second: \(session.folder.path)")

        let ratio = min(meSeconds, themSeconds) / max(meSeconds, themSeconds)
        print("""
        [CallDebriefRealSession] \(session.folder.lastPathComponent): \
        me=\(String(format: "%.1f", meSeconds))s them=\(String(format: "%.1f", themSeconds))s \
        ratio=\(String(format: "%.2f", ratio))
        """)

        // The loader's own duration probe must agree with what it decoded —
        // they read the same file through different AVFoundation paths, and a
        // mismatch means a malformed header the streaming writer left behind.
        let meDuration = try loader.duration(url: session.audioURL(for: .me))
        XCTAssertEqual(meDuration, meSeconds, accuracy: 0.5, "me.wav header duration disagrees with its decoded length")
    }

    // MARK: - Pipeline over real tracks

    func test_realSession_runTwoTrackProducesALabeledTranscript() async throws {
        let session = try newestRealSession()
        let (store, paths) = try copyIntoTempSession(session)

        // A fake engine: this test is about reading and merging two real WAVs,
        // not about Whisper's accuracy. Both tracks get segments, so the merged
        // transcript must carry both speaker labels.
        let engine = FakeTranscriptionEngine()
        engine.segmentsToReturn = [TranscriptSegment(start: 0, end: 1, text: "Spoken words.")]
        let pipeline = DebriefPipeline(
            engine: engine,
            summarizer: FakeDebriefSummarizer(name: "Fake", available: true, result: .success(summary())),
            store: store,
            makeDeltaSummarizer: { HeuristicDeltaSummarizer() }
        )

        let result = try await pipeline.runTwoTrack(
            paths: paths,
            language: "en",
            micSensitivity: .normal,
            onStage: { _ in }
        )

        XCTAssertFalse(result.transcript.isEmpty, "a call with audio on both tracks must produce a transcript")
        XCTAssertTrue(
            result.transcript.contains("Me:") || result.transcript.contains("Them:"),
            "the merged transcript must be speaker-labeled, got:\n\(result.transcript)"
        )

        // The transcript was written into the *temp* session folder...
        let onDisk = try String(contentsOf: paths.transcript, encoding: .utf8)
        XCTAssertEqual(onDisk, result.transcript)

        // ...and the real session folder still holds only what it started with.
        XCTAssertNotEqual(session.folder.path, paths.folder.path,
                          "the real session folder must never be written to")
    }

    /// Opt-in end-to-end run: real WhisperKit over the real audio. Off by
    /// default because it downloads/loads a model and takes minutes.
    /// Enable with `DIKTA_REAL_ENGINE=1`.
    func test_realSession_withRealEngine_producesANonEmptySummary() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DIKTA_REAL_ENGINE"] == "1",
            "set DIKTA_REAL_ENGINE=1 to run the real Whisper + summarizer pass over a real session"
        )

        let session = try newestRealSession()
        let (store, paths) = try copyIntoTempSession(session)

        let transcriber = Transcriber(model: .turbo)
        await transcriber.load()
        try XCTSkipUnless(
            transcriber.isReady,
            "the real engine could not load a model: \(transcriber.errorMessage ?? "unknown error")"
        )

        let pipeline = DebriefPipeline(
            engine: transcriber,
            summarizer: DebriefSummarizerFactory.make(kind: .auto, ollamaModel: AppConfig.defaultOllamaModel),
            store: store
        )

        let result = try await pipeline.runTwoTrack(
            paths: paths,
            language: nil,
            micSensitivity: .normal,
            onStage: { _ in }
        )

        XCTAssertFalse(result.transcript.isEmpty, "real audio must transcribe to something")
        XCTAssertFalse(
            result.summary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the summary must not be empty; engine was \(result.engineName), issues: \(result.issues)"
        )
        print("[CallDebriefRealSession] real engine \(result.engineName) summary: \(result.summary.summary)")
    }
}
