import XCTest
@testable import Dikta

/// End-to-end tests for `DebriefPipeline` using a fake transcription engine, a
/// fake summarizer and a `DebriefStore` rooted in a temp directory. Nothing
/// here touches WhisperKit, Ollama, Foundation Models, the network, the real
/// `~/Documents/Dikta` folder or the pasteboard.
@MainActor
final class DebriefPipelineTests: XCTestCase {
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

    private func sampleSummary() -> DebriefSummary {
        DebriefSummary(
            summary: "We reviewed the migration plan.",
            decisions: ["Ship behind a flag"],
            actionItems: [DebriefActionItem(text: "Draft the rollout doc", owner: "Sebastian", due: "Friday")],
            openQuestions: ["Who owns the rollback?"]
        )
    }

    private func silence(seconds: Int = 1) -> [Float] {
        [Float](repeating: 0, count: 16_000 * seconds)
    }

    // MARK: - Happy path

    func test_run_writesAllThreeFilesAndReportsStagesInOrder() async throws {
        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = "So the migration meeting just wrapped up."
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(sampleSummary()))
        let pipeline = DebriefPipeline(engine: engine, summarizer: summarizer, store: store)

        var stages: [DebriefStage] = []
        let result = try await pipeline.run(
            samples: silence(),
            language: "en",
            micSensitivity: .normal
        ) { stage in
            stages.append(stage)
        }

        XCTAssertEqual(stages, [.transcribing, .summarizing, .saving])

        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: result.paths.audio.path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.paths.transcript.path))
        XCTAssertTrue(fileManager.fileExists(atPath: result.paths.summary.path))

        let savedTranscript = try String(contentsOf: result.paths.transcript, encoding: .utf8)
        XCTAssertEqual(savedTranscript, "So the migration meeting just wrapped up.")
        XCTAssertEqual(result.transcript, "So the migration meeting just wrapped up.")

        let savedSummary = try String(contentsOf: result.paths.summary, encoding: .utf8)
        XCTAssertEqual(savedSummary, result.renderedText)
        XCTAssertTrue(result.renderedText.contains("SUMMARY"), "rendered text was:\n\(result.renderedText)")

        XCTAssertEqual(result.engineName, "Fake")
        XCTAssertEqual(summarizer.summarizeCallCount, 1)
        XCTAssertEqual(summarizer.summarizeCalls.first?.language, "en")
    }

    func test_run_copiesOriginalFileWhenImported() async throws {
        // Reuse the store's own WAV writer to produce a real, readable source file.
        let sourcePaths = try store.createSession()
        try store.writeAudio(silence(), to: sourcePaths)

        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = "Imported recording."
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(sampleSummary()))
        let pipeline = DebriefPipeline(engine: engine, summarizer: summarizer, store: store)

        let result = try await pipeline.run(
            samples: silence(),
            language: "en",
            micSensitivity: .normal,
            originalFile: sourcePaths.audio
        ) { _ in }

        let original = result.paths.folder.appendingPathComponent("original.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func test_run_unsupportedLanguageRendersInEnglish() async throws {
        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = "Rapat sudah selesai."
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(sampleSummary()))
        let pipeline = DebriefPipeline(engine: engine, summarizer: summarizer, store: store)

        _ = try await pipeline.run(samples: silence(), language: "id", micSensitivity: .normal) { _ in }

        XCTAssertEqual(summarizer.summarizeCalls.first?.language, "en")
    }

    func test_renderLanguage_onlySwedishAndEnglishPassThrough() {
        XCTAssertEqual(DebriefPipeline.renderLanguage(for: "sv"), "sv")
        XCTAssertEqual(DebriefPipeline.renderLanguage(for: "en"), "en")
        XCTAssertEqual(DebriefPipeline.renderLanguage(for: "id"), "en")
        XCTAssertEqual(DebriefPipeline.renderLanguage(for: nil), "en")
    }

    // MARK: - Failure paths

    func test_run_emptyTranscript_throwsAndWritesNoSummary() async throws {
        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = "   \n  "
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(sampleSummary()))
        let pipeline = DebriefPipeline(engine: engine, summarizer: summarizer, store: store)

        var stages: [DebriefStage] = []
        await XCTAssertThrowsErrorAsync(
            try await pipeline.run(samples: silence(), language: "en", micSensitivity: .normal) { stages.append($0) }
        ) { error in
            guard case DebriefSummarizerError.emptyTranscript = error else {
                return XCTFail("expected .emptyTranscript, got \(error)")
            }
        }

        XCTAssertEqual(stages, [.transcribing], "summarizing/saving must not be reported")
        XCTAssertEqual(summarizer.summarizeCallCount, 0)

        // The session folder exists (audio + transcript were written first) but
        // must not contain a summary.
        let sessions = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let summaries = sessions.map { $0.appendingPathComponent("summary.txt") }
        for summary in summaries {
            XCTAssertFalse(FileManager.default.fileExists(atPath: summary.path))
        }
    }

    func test_run_whisperSilenceMarker_throwsEmptyTranscriptAndWritesNoSummary() async throws {
        // Whisper answers silence with a marker, not an empty string. Summarizing
        // it would produce a confident summary of nothing.
        for marker in ["[BLANK_AUDIO]", "[silence]", " [ Silence ] ", "(silence)", "[NO SPEECH]"] {
            let engine = FakeTranscriptionEngine()
            engine.transcriptToReturn = marker
            let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(sampleSummary()))
            let pipeline = DebriefPipeline(engine: engine, summarizer: summarizer, store: store)

            await XCTAssertThrowsErrorAsync(
                try await pipeline.run(samples: silence(), language: "en", micSensitivity: .normal) { _ in }
            ) { error in
                guard case DebriefSummarizerError.emptyTranscript = error else {
                    return XCTFail("expected .emptyTranscript for \(marker), got \(error)")
                }
            }
            XCTAssertEqual(summarizer.summarizeCallCount, 0, "marker: \(marker)")
        }

        let sessions = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        for session in sessions {
            let summary = session.appendingPathComponent("summary.txt")
            XCTAssertFalse(FileManager.default.fileExists(atPath: summary.path))
        }
    }

    func test_run_normalizesPlaceholderOwnerAndDue() async throws {
        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = "We agreed on the plan."
        let placeholderSummary = DebriefSummary(
            summary: "Plan agreed.",
            decisions: [],
            actionItems: [DebriefActionItem(text: "Write the doc", owner: "Not specified", due: "TBD")],
            openQuestions: []
        )
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(placeholderSummary))
        let pipeline = DebriefPipeline(engine: engine, summarizer: summarizer, store: store)

        let result = try await pipeline.run(samples: silence(), language: "en", micSensitivity: .normal) { _ in }

        XCTAssertNil(result.summary.actionItems.first?.owner)
        XCTAssertNil(result.summary.actionItems.first?.due)
        XCTAssertFalse(result.renderedText.contains("Not specified"), result.renderedText)
        XCTAssertFalse(result.renderedText.contains("TBD"), result.renderedText)
    }

    func test_run_transcriptionTimeout_throwsTranscriptionTimeoutError() async {
        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = "never returned in time"
        engine.transcribeDelay = 2.0
        let summarizer = FakeDebriefSummarizer(name: "Fake", available: true, result: .success(sampleSummary()))
        let pipeline = DebriefPipeline(
            engine: engine,
            summarizer: summarizer,
            store: store,
            transcriptionTimeout: 0.1
        )

        await XCTAssertThrowsErrorAsync(
            try await pipeline.run(samples: silence(), language: "en", micSensitivity: .normal) { _ in }
        ) { error in
            XCTAssertTrue(error is TranscriptionTimeoutError, "got \(error)")
        }

        XCTAssertEqual(summarizer.summarizeCallCount, 0)
    }

    func test_run_summarizerFailure_propagates() async {
        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = "A real transcript."
        let summarizer = FakeDebriefSummarizer(
            name: "Fake",
            available: true,
            result: .failure(DebriefSummarizerError.unavailable("no engine"))
        )
        let pipeline = DebriefPipeline(engine: engine, summarizer: summarizer, store: store)

        await XCTAssertThrowsErrorAsync(
            try await pipeline.run(samples: silence(), language: "en", micSensitivity: .normal) { _ in }
        )
    }

    // MARK: - Chained summarizer reporting

    func test_run_reportsChainedEngineName() async throws {
        let engine = FakeTranscriptionEngine()
        engine.transcriptToReturn = "A real transcript."
        let failing = FakeDebriefSummarizer(name: "First", available: true, result: .failure(DebriefSummarizerError.timeout))
        let working = FakeDebriefSummarizer(name: "Second", available: true, result: .success(sampleSummary()))
        let chained = ChainedDebriefSummarizer(engines: [failing, working])
        let pipeline = DebriefPipeline(engine: engine, summarizer: chained, store: store)

        let result = try await pipeline.run(samples: silence(), language: "en", micSensitivity: .normal) { _ in }

        XCTAssertEqual(result.engineName, "Second")
    }
}

/// Guards the debrief-mode overrides on `AudioRecorder`: the defaults must stay
/// exactly what normal dictation has always used.
final class AudioRecorderDebriefOverrideTests: XCTestCase {
    func test_defaults_matchNormalDictationBehaviour() {
        let recorder = AudioRecorder()
        XCTAssertTrue(recorder.silenceAutoStopEnabled)
        XCTAssertEqual(recorder.maxBufferSamples, AudioRecorder.defaultMaxBufferSamples)
        XCTAssertEqual(AudioRecorder.defaultMaxBufferSamples, 4_800_000)
    }

    func test_overridesAreIndependentPerInstance() {
        let debriefRecorder = AudioRecorder()
        debriefRecorder.silenceAutoStopEnabled = false
        debriefRecorder.maxBufferSamples = 16_000 * 60 * 120

        let normalRecorder = AudioRecorder()
        XCTAssertTrue(normalRecorder.silenceAutoStopEnabled)
        XCTAssertEqual(normalRecorder.maxBufferSamples, AudioRecorder.defaultMaxBufferSamples)
    }

    // MARK: - silenceAutoStopTrimCount

    private func loud(_ count: Int = 1024) -> [Float] {
        [Float](repeating: 0.5, count: count)
    }

    private func quiet(_ count: Int = 1024) -> [Float] {
        [Float](repeating: 0, count: count)
    }

    func test_trimCount_silenceShorterThanThreshold_doesNotFire() {
        let recorder = AudioRecorder()
        let t0 = Date()

        XCTAssertNil(recorder.silenceAutoStopTrimCount(samples: quiet(), now: t0))
        XCTAssertNil(recorder.silenceAutoStopTrimCount(samples: quiet(), now: t0.addingTimeInterval(5)))
        XCTAssertNil(recorder.silenceAutoStopTrimCount(samples: quiet(), now: t0.addingTimeInterval(9.9)))
    }

    func test_trimCount_silencePastThreshold_firesWithTrailingSilenceTrimmed() {
        let recorder = AudioRecorder()
        let t0 = Date()

        XCTAssertNil(recorder.silenceAutoStopTrimCount(samples: quiet(), now: t0))

        let trim = recorder.silenceAutoStopTrimCount(samples: quiet(), now: t0.addingTimeInterval(11))
        // 11 s of trailing silence at 16 kHz
        XCTAssertEqual(trim, 176_000)
    }

    func test_trimCount_speechResetsTheSilenceTimer() {
        let recorder = AudioRecorder()
        let t0 = Date()

        XCTAssertNil(recorder.silenceAutoStopTrimCount(samples: quiet(), now: t0))
        // Speech at t+9 restarts the clock...
        XCTAssertNil(recorder.silenceAutoStopTrimCount(samples: loud(), now: t0.addingTimeInterval(9)))
        // ...so silence at t+11 is only 0 s old and must not fire.
        XCTAssertNil(recorder.silenceAutoStopTrimCount(samples: quiet(), now: t0.addingTimeInterval(11)))
        XCTAssertNil(recorder.silenceAutoStopTrimCount(samples: quiet(), now: t0.addingTimeInterval(20)))
        XCTAssertNotNil(recorder.silenceAutoStopTrimCount(samples: quiet(), now: t0.addingTimeInterval(22)))
    }

    func test_trimCount_firingResetsSoItDoesNotRetriggerImmediately() {
        let recorder = AudioRecorder()
        let t0 = Date()

        XCTAssertNil(recorder.silenceAutoStopTrimCount(samples: quiet(), now: t0))
        XCTAssertNotNil(recorder.silenceAutoStopTrimCount(samples: quiet(), now: t0.addingTimeInterval(11)))
        // Next silent chunk starts a fresh window rather than firing again.
        XCTAssertNil(recorder.silenceAutoStopTrimCount(samples: quiet(), now: t0.addingTimeInterval(11.1)))
    }

    func test_trimCount_emptyChunkIsIgnored() {
        let recorder = AudioRecorder()
        XCTAssertNil(recorder.silenceAutoStopTrimCount(samples: [], now: Date()))
    }
}

/// Both paths must reject Whisper's silence markers identically.
final class TranscriptSanitizerTests: XCTestCase {
    func test_isEffectivelyEmpty_forBlankAndMarkers() {
        XCTAssertTrue(TranscriptSanitizer.isEffectivelyEmpty(""))
        XCTAssertTrue(TranscriptSanitizer.isEffectivelyEmpty("   \n  "))
        XCTAssertTrue(TranscriptSanitizer.isEffectivelyEmpty("[BLANK_AUDIO]"))
        XCTAssertTrue(TranscriptSanitizer.isEffectivelyEmpty("[silence]"))
        XCTAssertTrue(TranscriptSanitizer.isEffectivelyEmpty(" [ Silence ] "))
        XCTAssertTrue(TranscriptSanitizer.isEffectivelyEmpty("(silence)"))
        XCTAssertTrue(TranscriptSanitizer.isEffectivelyEmpty("[NO SPEECH]"))
    }

    func test_isEffectivelyEmpty_forRealSpeech() {
        XCTAssertFalse(TranscriptSanitizer.isEffectivelyEmpty("We agreed to ship on Friday."))
        XCTAssertFalse(TranscriptSanitizer.isEffectivelyEmpty("Tystnad i rummet."))
    }

    func test_matchedSilenceIndicator_namesTheMarker() {
        XCTAssertEqual(TranscriptSanitizer.matchedSilenceIndicator("[BLANK_AUDIO]"), "[blank_audio]")
        XCTAssertNil(TranscriptSanitizer.matchedSilenceIndicator("real speech"))
        XCTAssertNil(TranscriptSanitizer.matchedSilenceIndicator(""))
    }
}

/// Engines write "Not specified" where the schema asks for null.
final class DebriefSummaryNormalizationTests: XCTestCase {
    private func item(owner: String?, due: String?) -> DebriefActionItem {
        DebriefActionItem(text: "Do the thing", owner: owner, due: due)
    }

    func test_normalized_mapsEveryPlaceholderToNil() {
        let placeholders = [
            "Not specified", "TBD", "N/A", "n/a", "None", "Unknown", "null",
            "Ingen", "Ingen specificerad", "Ej angivet", "Okänd", "-", "–", "—", "  ", ""
        ]
        for placeholder in placeholders {
            let normalized = item(owner: placeholder, due: placeholder).normalized()
            XCTAssertNil(normalized.owner, "owner survived: \(placeholder)")
            XCTAssertNil(normalized.due, "due survived: \(placeholder)")
        }
    }

    func test_normalized_keepsRealValuesAndTrimsThem() {
        let normalized = item(owner: "  Sebastian ", due: " Friday ").normalized()
        XCTAssertEqual(normalized.owner, "Sebastian")
        XCTAssertEqual(normalized.due, "Friday")
        XCTAssertEqual(normalized.text, "Do the thing")
    }

    func test_normalized_leavesNilAlone() {
        let normalized = item(owner: nil, due: nil).normalized()
        XCTAssertNil(normalized.owner)
        XCTAssertNil(normalized.due)
    }

    func test_renderPlainText_afterNormalization_showsNoPlaceholderSuffix() {
        let summary = DebriefSummary(
            summary: "Sprint review.",
            decisions: [],
            actionItems: [item(owner: "Not specified", due: "N/A")],
            openQuestions: []
        ).normalized()

        let rendered = summary.renderPlainText(language: "en")
        XCTAssertTrue(rendered.contains("Do the thing"))
        XCTAssertFalse(rendered.contains("Not specified"), rendered)
        XCTAssertFalse(rendered.contains("N/A"), rendered)
        XCTAssertFalse(rendered.contains("due"), rendered)
    }

    func test_parser_normalizesPlaceholders() throws {
        let json = """
        {"summary": "s", "decisions": [], "openQuestions": [],
         "actionItems": [{"text": "t", "owner": "Not specified", "due": "TBD"}]}
        """
        let parsed = try DebriefSummaryParser.parse(json)
        XCTAssertNil(parsed.actionItems.first?.owner)
        XCTAssertNil(parsed.actionItems.first?.due)
    }

    // MARK: - Edge punctuation (probe finding: owner "Tomas.")

    func test_normalized_trimsTrailingPeriodFromOwner() {
        let normalized = item(owner: "Tomas.", due: nil).normalized()
        XCTAssertEqual(normalized.owner, "Tomas")
    }

    func test_normalized_trimsSurroundingPunctuationFromDue() {
        let normalized = item(owner: nil, due: ", Friday,").normalized()
        XCTAssertEqual(normalized.due, "Friday")
    }

    func test_normalized_trimmingPunctuationDoesNotEmptyARealValue() {
        let normalized = item(owner: "Erik", due: "17th September").normalized()
        XCTAssertEqual(normalized.owner, "Erik")
        XCTAssertEqual(normalized.due, "17th September")
    }

    // MARK: - Generic collective owner (probe finding: invented "Team")

    func test_normalized_dropsGenericCollectiveOwners() {
        let genericOwners = ["Team", "the team", "Everyone", "ALL", "Teamet", "alla"]
        for owner in genericOwners {
            let normalized = item(owner: owner, due: nil).normalized()
            XCTAssertNil(normalized.owner, "owner survived: \(owner)")
        }
    }

    func test_normalized_keepsARealNameThatIsNotGeneric() {
        let normalized = item(owner: "Sebastian", due: nil).normalized()
        XCTAssertEqual(normalized.owner, "Sebastian")
    }

    func test_normalized_genericCollectiveIsNotStrippedFromDue() {
        // "all" and "team" are legitimate English words that could appear in
        // a due phrase; the generic-collective list only ever applies to owner.
        let normalized = item(owner: nil, due: "before the team meeting").normalized()
        XCTAssertEqual(normalized.due, "before the team meeting")
    }

    // MARK: - Decision/action-item de-duplication (probe finding: same item in both lists)

    func test_summaryNormalized_removesDecisionThatDuplicatesAnActionItem() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: ["Schedule a new meeting for the gaming team."],
            actionItems: [DebriefActionItem(text: "Schedule a new meeting for the gaming team", owner: "Sebastian", due: nil)],
            openQuestions: []
        ).normalized()

        XCTAssertTrue(summary.decisions.isEmpty, "duplicate decision survived: \(summary.decisions)")
        XCTAssertEqual(summary.actionItems.count, 1)
        XCTAssertEqual(summary.actionItems.first?.text, "Schedule a new meeting for the gaming team")
    }

    /// Real defect, sv-ewave-mikael (see "Tuning round 2" in
    /// docs/review-2026-09/debrief-probe-2026-09-17.md): Foundation Models
    /// wrote the literal JSON string "null" as the sole `openQuestions`
    /// entry instead of an empty array. normalized() must drop it.
    func test_summaryNormalized_dropsLiteralNullOpenQuestion() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: [],
            actionItems: [],
            openQuestions: ["null"]
        ).normalized()

        XCTAssertEqual(summary.openQuestions, [])
    }

    /// An empty string and a placeholder-shaped decision must both be
    /// dropped, in order, leaving only the real one.
    func test_summaryNormalized_dropsEmptyAndPlaceholderDecisions_keepsOrder() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: ["", "None", "Real decision"],
            actionItems: [],
            openQuestions: []
        ).normalized()

        XCTAssertEqual(summary.decisions, ["Real decision"])
    }

    /// A placeholder-text action item ("null") must be removed outright, not
    /// just have its owner/due normalized.
    func test_summaryNormalized_removesActionItemWithPlaceholderText() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: [],
            actionItems: [
                DebriefActionItem(text: "null", owner: "Sebastian", due: "Friday"),
                DebriefActionItem(text: "Send the notes", owner: "Sebastian", due: "Friday")
            ],
            openQuestions: []
        ).normalized()

        XCTAssertEqual(summary.actionItems.count, 1)
        XCTAssertEqual(summary.actionItems.first?.text, "Send the notes")
    }

    /// "inga" (Swedish plural "none") isn't in
    /// `DebriefActionItem.placeholderValues` (an owner/due-focused set) but
    /// must still be treated as empty content for a whole decision/question.
    func test_summaryNormalized_dropsSwedishPluralNonePlaceholder() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: [],
            actionItems: [],
            openQuestions: ["Inga", "Verklig öppen fråga"]
        ).normalized()

        XCTAssertEqual(summary.openQuestions, ["Verklig öppen fråga"])
    }

    func test_summaryNormalized_keepsDistinctDecisionsAndActionItems() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: ["Align working hours with Swedish hours"],
            actionItems: [DebriefActionItem(text: "Book a new meeting", owner: "Sebastian", due: "one week from now")],
            openQuestions: []
        ).normalized()

        XCTAssertEqual(summary.decisions, ["Align working hours with Swedish hours"])
        XCTAssertEqual(summary.actionItems.count, 1)
    }

    /// Tuning round 2, real defect: the app's own summary.txt for a real
    /// recorded session put the same item in both lists, worded differently
    /// in each — "Ska ta fram en tidsram..." as a decision, "Skapa en
    /// tidsram..." as an action item — so the exact-string dedup above did
    /// not catch it (no exact substring in common). Jaccard similarity on
    /// words >= 3 characters is 0.75 for this pair — right at the (raised,
    /// see skeptic review) 0.75 threshold — and both token sets have well
    /// over 3 tokens, so normalized() must still drop the decision.
    func test_summaryNormalized_removesDecisionThatParaphrasesAnActionItem() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: ["Ska ta fram en tidsram för att hjälpa Anders med sina potentiella kunder"],
            actionItems: [
                DebriefActionItem(text: "Skapa en tidsram för att hjälpa Anders med sina potentiella kunder", owner: "jag", due: "imorgon")
            ],
            openQuestions: []
        ).normalized()

        XCTAssertTrue(summary.decisions.isEmpty, "paraphrased duplicate decision survived: \(summary.decisions)")
        XCTAssertEqual(summary.actionItems.count, 1)
    }

    /// A second, shorter real-shaped paraphrase pair above the 0.75
    /// threshold (4 of 4 tokens in the shorter text also appear in the
    /// longer one — Jaccard 0.8), confirming the fix isn't tuned to only the
    /// one real pair above.
    func test_summaryNormalized_removesASecondParaphraseAboveTheRaisedThreshold() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: ["Ska ta fram en tidsram för projektet"],
            actionItems: [DebriefActionItem(text: "Ta fram en tidsram för projektet", owner: "jag", due: nil)],
            openQuestions: []
        ).normalized()

        XCTAssertTrue(summary.decisions.isEmpty, "paraphrased duplicate decision survived: \(summary.decisions)")
        XCTAssertEqual(summary.actionItems.count, 1)
    }

    /// Skeptic review of tuning round 2: the original 0.5 Jaccard threshold
    /// and a weak single-pair negative test let two DISTINCT items collapse
    /// into one whenever they happened to share a few common words. These
    /// three pairs must all survive as two separate items at the raised 0.75
    /// threshold (the first is unrelated content; the second two are
    /// deliberately near-miss collisions that hit exactly 0.6 under the old
    /// scoring and would have wrongly deduped there).
    func test_summaryNormalized_doesNotTreatModeratelySimilarDistinctItemsAsAParaphrase() {
        let cases: [(decision: String, actionText: String)] = [
            ("We agreed the Falcon repository analysis should happen first", "Book the follow-up call with the client"),
            ("Boka möte med Erik", "Boka möte med Anna"),
            ("Review the Falcon repo", "Review the Falcon docs")
        ]

        for testCase in cases {
            let summary = DebriefSummary(
                summary: "Recap.",
                decisions: [testCase.decision],
                actionItems: [DebriefActionItem(text: testCase.actionText, owner: nil, due: nil)],
                openQuestions: []
            ).normalized()

            XCTAssertEqual(
                summary.decisions.count, 1,
                "wrongly deduped as a paraphrase: \"\(testCase.decision)\" vs \"\(testCase.actionText)\""
            )
            XCTAssertEqual(summary.actionItems.count, 1)
        }
    }

    /// The tokenizer must split on ANY whitespace (newline, tab), not just a
    /// literal space, or a decision/action pair separated by a line break
    /// instead of a space would be scored as near-total non-overlap.
    func test_summaryNormalized_paraphraseDetectionSplitsOnAnyWhitespace() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: ["Ska ta fram en tidsram\nför projektet"],
            actionItems: [DebriefActionItem(text: "Ta fram en tidsram\tför projektet", owner: "jag", due: nil)],
            openQuestions: []
        ).normalized()

        XCTAssertTrue(summary.decisions.isEmpty, "newline/tab-separated paraphrase should still be detected: \(summary.decisions)")
        XCTAssertEqual(summary.actionItems.count, 1)
    }
}

/// Tuning round 2: `DebriefSummary.validated(against:)` / `DebriefActionItem.validated(against:)`.
/// See DebriefSummary.swift and docs/review-2026-09/debrief-probe-2026-09-17.md
/// ("Tuning round 2") for what this method does and does not catch.
final class DebriefSummaryValidationTests: XCTestCase {
    func test_validated_nullsDueContainingAFabricatedIsoDateNotInTranscript() {
        let transcript = "Vi ska ta ett nytt möte om två veckor."
        let item = DebriefActionItem(text: "Ta fram en plan", owner: "Sebastian", due: "2024-09-17").validated(against: transcript)

        XCTAssertNil(item.due, "fabricated ISO date should be nulled since it never appears in the transcript")
    }

    func test_validated_nullsDueContainingABareFabricatedYearNotInTranscript() {
        let transcript = "Vi ska ta ett nytt möte om två veckor."
        let item = DebriefActionItem(text: "Ta fram en plan", owner: "Sebastian", due: "senast 2024").validated(against: transcript)

        XCTAssertNil(item.due, "fabricated bare year should be nulled since it never appears in the transcript")
    }

    func test_validated_keepsDueYearThatLiterallyAppearsInTranscript() {
        let transcript = "We'll follow up in 2027 once the contract renews."
        let item = DebriefActionItem(text: "Follow up", owner: "Sebastian", due: "2027").validated(against: transcript)

        XCTAssertEqual(item.due, "2027", "a year the speaker actually said must survive")
    }

    func test_validated_leavesNonDatePlaceholderDueAlone() {
        // "imorgon" (tomorrow) is a real, if possibly fabricated-by-the-model,
        // due phrase — it is not a year or ISO date, so validated() has no
        // basis to touch it. This is a known, documented limitation: only the
        // prompt (DebriefPromptBuilder/@Guide "due" wording) can prevent this
        // class of fabrication, not this post-processing step.
        let transcript = "Vi ska ta ett nytt möte om två veckor."
        let item = DebriefActionItem(text: "Se över faktureringsprocesserna", owner: "Sebastian", due: "Imorgon").validated(against: transcript)

        XCTAssertEqual(item.due, "Imorgon")
    }

    /// Documents a known limit of `validated(against:)`: it can only tell
    /// whether an owner string was said ANYWHERE in the transcript, not
    /// whether it was attached to the right task. In a real recorded
    /// session, the app assigned the speaker's own "I need to do an initial
    /// run..." task to their business partner's name — a real
    /// misattribution — but that name genuinely is in that transcript, so
    /// validated() must NOT null it. Only the prompt's grammatical-subject
    /// rule (see DebriefRealTranscriptTests) can fix this one.
    func test_validated_doesNotNullAnOwnerThatGenuinelyAppearsInTranscript_evenWhenMisattributed() {
        let transcript = "I just had a meeting with my business partner Marcus and we were talking about our product Falcon."
        let item = DebriefActionItem(
            text: "Conduct an initial run with agents on the repositories.",
            owner: "Marcus",
            due: "September 18th"
        ).validated(against: transcript)

        XCTAssertEqual(item.owner, "Marcus", "owner that is genuinely in the transcript must survive, even when misattributed")
    }

    func test_validated_nullsACapitalizedOwnerNeverSpokenAnywhereInTranscript() {
        let transcript = "I just had a meeting with my business partner Marcus and we were talking about our product Falcon."
        let item = DebriefActionItem(text: "Schedule another meeting", owner: "Team", due: nil).validated(against: transcript)

        // "Team" is already stripped to nil by normalized() before validated()
        // ever runs in the real pipeline, but validated() alone must also
        // null a genuinely invented capitalized name that normalized() has no
        // list for (e.g. a name-shaped hallucination, not a generic word).
        XCTAssertNil(item.owner)
    }

    func test_validated_leavesLowercaseOwnerAlone() {
        // "jag"/"me" are lowercase, not name-shaped, so validated() never
        // touches them regardless of transcript content.
        let transcript = "Anything at all."
        let item = DebriefActionItem(text: "Do the thing", owner: "jag", due: nil).validated(against: transcript)

        XCTAssertEqual(item.owner, "jag")
    }

    /// Skeptic review of tuning round 2: the prompt tells the model to use
    /// "me"/"jag" for the speaker's own tasks, but Foundation Models
    /// sometimes capitalizes it ("Me", "Jag") since it fills the owner field
    /// like a proper noun. Without an exemption, that capitalization made a
    /// legitimate self-reference look exactly like a name-shaped
    /// hallucination and validated() nulled it whenever the transcript
    /// (naturally) never contains the literal word "Me"/"Jag" as such. Both
    /// must survive regardless of transcript content.
    func test_validated_keepsCapitalizedFirstPersonOwner_evenWhenTheWordNeverAppearsInTranscript() {
        let transcript = "We discussed the roadmap and next steps for the quarter."
        let englishItem = DebriefActionItem(text: "Send the notes", owner: "Me", due: nil).validated(against: transcript)
        let swedishItem = DebriefActionItem(text: "Skicka anteckningarna", owner: "Jag", due: nil).validated(against: transcript)

        XCTAssertEqual(englishItem.owner, "Me")
        XCTAssertEqual(swedishItem.owner, "Jag")
    }

    /// An owner that merely LOOKS like a first-person word but isn't one of
    /// the exempted forms (a real, unknown capitalized name never spoken)
    /// must still be nulled — the exemption is a fixed small list, not a
    /// general "short capitalized word" carve-out.
    func test_validated_stillNullsAnUnknownCapitalizedNameNeverSpokenInTranscript() {
        let transcript = "We discussed the roadmap and next steps for the quarter."
        let item = DebriefActionItem(text: "Send the notes", owner: "Marcus", due: nil).validated(against: transcript)

        XCTAssertNil(item.owner, "an unrelated invented name must still be nulled")
    }

    /// Skeptic review of tuning round 2: the fabricated-date check used to
    /// compare the WHOLE `due` string against the transcript, so a due like
    /// "by 2027" would be nulled even though "2027" itself was genuinely
    /// said, just phrased differently around it. The check must compare only
    /// the matched year/ISO token, not the surrounding words.
    func test_validated_keepsDueWhoseYearAppearsInTranscriptEvenWhenSurroundingWordsDiffer() {
        let transcript = "We'll follow up in 2027 once the contract renews."
        let item = DebriefActionItem(text: "Follow up", owner: "Sebastian", due: "by 2027").validated(against: transcript)

        XCTAssertEqual(item.due, "by 2027", "the transcript genuinely contains the matched year token \"2027\"")
    }

    func test_summaryValidated_appliesToEveryActionItem() {
        let transcript = "Vi ska ta ett nytt möte om två veckor."
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: [],
            actionItems: [
                DebriefActionItem(text: "Ta fram en plan", owner: "Sebastian", due: "2024-09-17"),
                DebriefActionItem(text: "Boka möte", owner: "Sebastian", due: "om två veckor")
            ],
            openQuestions: []
        ).validated(against: transcript)

        XCTAssertNil(summary.actionItems[0].due, "fabricated year should be nulled")
        XCTAssertEqual(summary.actionItems[1].due, "om två veckor", "verbatim due that matches the transcript must survive")
    }
}

/// `AppConfig` must keep loading configs written before debrief mode existed.
final class AppConfigDebriefDecodingTests: XCTestCase {
    private let legacyJSON = """
    {
        "version": 3,
        "hotkeys": {
            "toggle": {"modifiers": ["shift", "ctrl"]},
            "push_to_talk": {"modifiers": ["cmd", "shift"]}
        },
        "output_mode": "general",
        "history": [],
        "whisper_model": "small",
        "llm_model": "gemma3",
        "language": "en"
    }
    """

    func test_decode_withoutDebriefKeys_usesDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(legacyJSON.utf8))

        XCTAssertFalse(config.debriefModeEnabled)
        XCTAssertEqual(config.debriefEngine, .auto)
        XCTAssertEqual(config.ollamaModel, "qwen3:4b")
        XCTAssertEqual(config.ollamaModel, AppConfig.defaultOllamaModel)
    }

    func test_roundTrip_preservesDebriefKeys() throws {
        var config = AppConfig.default
        config.debriefModeEnabled = true
        config.debriefEngine = .ollama
        config.ollamaModel = "gemma3:4b"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertTrue(decoded.debriefModeEnabled)
        XCTAssertEqual(decoded.debriefEngine, .ollama)
        XCTAssertEqual(decoded.ollamaModel, "gemma3:4b")
    }

    func test_encode_usesSnakeCaseKeys() throws {
        let data = try JSONEncoder().encode(AppConfig.default)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["debrief_mode_enabled"])
        XCTAssertNotNil(json["debrief_engine"])
        XCTAssertNotNil(json["ollama_model"])
    }
}

// MARK: - DebriefPromptBuilder language-specific examples

/// Tuning round 2 follow-up: `DebriefPromptBuilder.systemPrompt` used to show
/// BOTH languages' example literals in one shared string regardless of the
/// transcript's actual language (e.g. "we decided"/"vi bestämde" side by
/// side), which is the most likely cause of a real regression — an
/// all-English transcript (`en-cadec-gaming`) coming back with a Swedish
/// `due`/`owner` ("om två veckor"/"jag") after a prompt-trim. `systemPrompt`
/// now selects only the matching language's example literals via
/// `PromptExamples.forLanguage`; these tests guard against a future edit
/// reintroducing a cross-language literal.
final class DebriefPromptBuilderLanguageTests: XCTestCase {
    func test_systemPrompt_english_containsNoSwedishExampleLiterals() {
        let prompt = DebriefPromptBuilder.systemPrompt(language: "en")

        XCTAssertFalse(prompt.contains("jag"), "English prompt must not contain the Swedish example \"jag\"")
        XCTAssertFalse(prompt.contains("om två veckor"), "English prompt must not contain the Swedish example \"om två veckor\"")
        XCTAssertFalse(prompt.contains("vi bestämde"), "English prompt must not contain the Swedish example \"vi bestämde\"")
        XCTAssertFalse(prompt.contains("imorgon"), "English prompt must not contain the Swedish example \"imorgon\"")
    }

    func test_systemPrompt_swedish_containsNoEnglishExampleLiterals() {
        let prompt = DebriefPromptBuilder.systemPrompt(language: "sv")

        XCTAssertFalse(prompt.contains("one week from now"), "Swedish prompt must not contain the English example \"one week from now\"")
        XCTAssertFalse(prompt.contains("we decided"), "Swedish prompt must not contain the English example \"we decided\"")
        XCTAssertFalse(prompt.contains("we will have a meeting tomorrow"), "Swedish prompt must not contain the English example \"we will have a meeting tomorrow\"")
    }

    /// Any language other than "sv" defaults to the English examples,
    /// matching `DebriefPipeline.renderLanguage`'s own fallback.
    func test_systemPrompt_unsupportedLanguage_fallsBackToEnglishExamples() {
        let prompt = DebriefPromptBuilder.systemPrompt(language: "id")

        XCTAssertTrue(prompt.contains("one week from now"))
        XCTAssertFalse(prompt.contains("om två veckor"))
    }

    func test_systemPrompt_bothLanguages_mentionTranscriptLanguageOnlyRule() {
        XCTAssertTrue(DebriefPromptBuilder.systemPrompt(language: "en").contains("in the transcript's language only"))
        XCTAssertTrue(DebriefPromptBuilder.systemPrompt(language: "sv").contains("in the transcript's language only"))
    }

    func test_systemPrompt_rulesBlockStaysUnderWordBudgetPerLanguage() {
        for language in ["en", "sv"] {
            let prompt = DebriefPromptBuilder.systemPrompt(language: language)
            guard let rulesRange = prompt.range(of: "Rules:") else {
                XCTFail("no Rules: block found for language \(language)")
                continue
            }
            let rulesBlock = prompt[rulesRange.lowerBound...]
            let wordCount = rulesBlock.split(whereSeparator: { $0.isWhitespace }).count
            XCTAssertLessThanOrEqual(wordCount, 350, "Rules block for \(language) is \(wordCount) words, over the 350 budget")
        }
    }
}
