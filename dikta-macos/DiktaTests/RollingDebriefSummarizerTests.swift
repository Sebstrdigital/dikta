import XCTest
@testable import Dikta

/// Scripted `DeltaSummarizing` for tests. Returns a queued delta per
/// `extractDelta` call (or a default one built from the chunk text) and a fixed
/// consolidation delta. Never touches Foundation Models or the network.
final class FakeDeltaSummarizer: DeltaSummarizing, @unchecked Sendable {
    let name: String

    var available = true
    /// Deltas handed out by chunk index; when absent, `defaultDelta(for:index:)`
    /// is used instead.
    var queuedDeltas: [DebriefDelta] = []
    var consolidationResult = ConsolidationDelta(summary: "", dropIds: [])
    var extractError: Error?
    var consolidateError: Error?
    /// When set, any call whose rendered state + chunk exceeds this many
    /// characters throws `DeltaSummarizerError.contextWindowExceeded` — the
    /// knob for "a smaller view of the STATE would fit".
    var maxPromptCharacters: Int?
    /// When set, any call whose CHUNK alone exceeds this many characters throws
    /// the same error — the knob for "only a shorter chunk will fit".
    var maxChunkCharacters: Int?

    /// Chunk indices whose `extractDelta` call pauses — after recording
    /// "entered" but before doing any work — until the test calls
    /// `releaseGate(for:)`. This is what lets the ordering test prove
    /// serialization deterministically instead of racing a wall-clock delay.
    var gatedChunks: Set<Int> = []
    /// Fires the chunk index at the start of every `extractDelta` call, before
    /// any gating. A test awaits this to know the fake is now running a given
    /// chunk, rather than guessing with `Task.sleep`.
    let entered: AsyncStream<Int>
    private let enteredContinuation: AsyncStream<Int>.Continuation
    private let gateLock = NSLock()
    private var gateContinuationsByChunk: [Int: CheckedContinuation<Void, Never>] = [:]

    private(set) var seenStates: [DebriefState] = []
    private(set) var seenChunks: [String] = []
    private(set) var seenRenderStyles: [DebriefState.RenderStyle] = []
    private(set) var consolidateCallCount = 0

    init(name: String = "Fake") {
        self.name = name
        var continuation: AsyncStream<Int>.Continuation!
        self.entered = AsyncStream { continuation = $0 }
        self.enteredContinuation = continuation
    }

    func isAvailable() async -> Bool { available }

    /// Resumes a gated `extractDelta` call for `chunkIndex`. A no-op if that
    /// chunk was never gated, or has already been released.
    func releaseGate(for chunkIndex: Int) {
        gateLock.lock()
        let continuation = gateContinuationsByChunk.removeValue(forKey: chunkIndex)
        gateLock.unlock()
        continuation?.resume()
    }

    func extractDelta(
        state: DebriefState,
        chunk: String,
        chunkIndex: Int,
        language: String
    ) async throws -> DebriefDelta {
        enteredContinuation.yield(chunkIndex)
        if gatedChunks.contains(chunkIndex) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gateLock.lock()
                gateContinuationsByChunk[chunkIndex] = continuation
                gateLock.unlock()
            }
        }
        seenStates.append(state)
        seenChunks.append(chunk)
        seenRenderStyles.append(state.renderStyle)

        if let extractError { throw extractError }
        if let maxChunkCharacters, chunk.count > maxChunkCharacters {
            throw DeltaSummarizerError.contextWindowExceeded("fake chunk limit \(maxChunkCharacters)")
        }
        if let maxPromptCharacters,
           state.rendered(language: language).count + chunk.count > maxPromptCharacters {
            throw DeltaSummarizerError.contextWindowExceeded("fake prompt limit \(maxPromptCharacters)")
        }
        if chunkIndex < queuedDeltas.count { return queuedDeltas[chunkIndex] }
        return Self.defaultDelta(for: chunk, index: chunkIndex)
    }

    func consolidate(state: DebriefState, language: String) async throws -> ConsolidationDelta {
        consolidateCallCount += 1
        if let consolidateError { throw consolidateError }
        return consolidationResult
    }

    /// One new action item per chunk, so a run of N chunks yields N items.
    static func defaultDelta(for chunk: String, index: Int) -> DebriefDelta {
        DebriefDelta(
            summary: "Recap after chunk \(index).",
            newItems: [.init(kind: .action, text: "Task from chunk \(index): \(chunk)")]
        )
    }
}

final class RollingDebriefSummarizerTests: XCTestCase {

    private func makeSummarizer(
        _ fake: FakeDeltaSummarizer,
        similarity: @escaping (String, String) -> Double = { _, _ in 0 }
    ) -> RollingDebriefSummarizer {
        RollingDebriefSummarizer(summarizer: fake, similarity: similarity, language: "en")
    }

    // MARK: - Ingest

    func testItemCountIsMonotoneAcrossTwelveIngests() async throws {
        let fake = FakeDeltaSummarizer()
        let rolling = makeSummarizer(fake)

        var previousCount = 0
        for index in 0..<12 {
            try await rolling.ingest(chunkTranscript: "Me: chunk number \(index)", index: index)
            let count = await rolling.state.activeItems.count
            XCTAssertGreaterThanOrEqual(count, previousCount, "active count dropped at chunk \(index)")
            previousCount = count
        }

        XCTAssertEqual(previousCount, 12)
        let summary = await rolling.state.summary
        XCTAssertEqual(summary, "Recap after chunk 11.")
    }

    func testEachChunkSeesTheAccumulatedStateFromThePreviousOne() async throws {
        let fake = FakeDeltaSummarizer()
        let rolling = makeSummarizer(fake)

        try await rolling.ingest(chunkTranscript: "Me: first", index: 0)
        try await rolling.ingest(chunkTranscript: "Them: second", index: 1)

        XCTAssertEqual(fake.seenStates.count, 2)
        XCTAssertTrue(fake.seenStates[0].items.isEmpty)
        XCTAssertEqual(fake.seenStates[1].activeItems.count, 1, "the second call is handed what the first produced")
        XCTAssertEqual(fake.seenRenderStyles, [.full, .full])
    }

    func testBlankChunkIsSkippedWithoutCallingTheEngine() async throws {
        let fake = FakeDeltaSummarizer()
        let rolling = makeSummarizer(fake)

        try await rolling.ingest(chunkTranscript: "   \n ", index: 0)

        XCTAssertTrue(fake.seenChunks.isEmpty)
        let items = await rolling.state.items
        XCTAssertTrue(items.isEmpty)
    }

    func testDedupeRunsPerChunkSoTheModelNeverSeesARepeat() async throws {
        let fake = FakeDeltaSummarizer()
        fake.queuedDeltas = [
            DebriefDelta(summary: "a", newItems: [.init(kind: .action, text: "Book the follow-up")]),
            DebriefDelta(summary: "b", newItems: [.init(kind: .action, text: "book the follow-up")]),
        ]
        let rolling = makeSummarizer(fake)

        try await rolling.ingest(chunkTranscript: "chunk one", index: 0)
        try await rolling.ingest(chunkTranscript: "chunk two", index: 1)

        let active = await rolling.state.activeItems
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0].id, 1)
    }

    func testIngestPropagatesANonRetryableEngineFailure() async {
        let fake = FakeDeltaSummarizer()
        fake.extractError = DebriefSummarizerError.unavailable("no model")
        let rolling = makeSummarizer(fake)

        do {
            try await rolling.ingest(chunkTranscript: "Me: something", index: 0)
            XCTFail("expected ingest to rethrow the engine's error")
        } catch {
            XCTAssertTrue(error is DebriefSummarizerError)
        }
    }

    // MARK: - Serialization

    /// Two overlapping ingests must fold in CALL order: chunk 0's delta is
    /// computed against, and applied to, a state chunk 1 has not touched yet.
    ///
    /// Proven without any wall-clock delay: chunk 0 is gated inside
    /// `extractDelta`, so the test deterministically waits until the fake is
    /// running chunk 0 (via `entered`) before even starting chunk 1, then
    /// releases chunk 0. `RollingDebriefSummarizer.serialized(_:)` captures
    /// its queue tail synchronously when a call reaches the actor, so once
    /// chunk 0 is confirmed running, chunk 1 can only ever queue behind it —
    /// no race window, whatever the scheduler does with either `Task`.
    func testOverlappingIngestsSerializeInCallOrder() async throws {
        let fake = FakeDeltaSummarizer()
        fake.gatedChunks = [0]
        let rolling = makeSummarizer(fake)
        var enteredIterator = fake.entered.makeAsyncIterator()

        let first = Task { try await rolling.ingest(chunkTranscript: "Me: slow first chunk", index: 0) }
        let firstEntered = await enteredIterator.next()
        XCTAssertEqual(firstEntered, 0, "chunk 0 must be inside extractDelta before chunk 1 is even started")

        let second = Task { try await rolling.ingest(chunkTranscript: "Me: fast second chunk", index: 1) }
        fake.releaseGate(for: 0)

        try await first.value
        try await second.value

        let items = await rolling.state.items
        XCTAssertEqual(items.map(\.sourceChunk), [0, 1], "the slow first chunk must still land first")
        XCTAssertEqual(items.map(\.id), [1, 2])
    }

    // MARK: - Context-window ladder

    func testContextOverflowRetriesOnceWithACompactState() async throws {
        let fake = FakeDeltaSummarizer()
        let rolling = makeSummarizer(fake)

        // Build a state whose FULL render is long (owner/due + summary), then
        // set a budget only the compact render fits under.
        try await rolling.ingest(chunkTranscript: "Me: chunk zero", index: 0)
        let fullLength = await rolling.state.rendered(language: "en").count
        let compactLength = await rolling.state.compacted().rendered(language: "en").count
        XCTAssertLessThan(compactLength, fullLength, "the compact render must actually be smaller")

        let chunk = "Me: chunk one"
        fake.maxPromptCharacters = compactLength + chunk.count

        try await rolling.ingest(chunkTranscript: chunk, index: 1)

        XCTAssertEqual(fake.seenRenderStyles, [.full, .full, .compact])
        let items = await rolling.state.items
        XCTAssertEqual(items.count, 2, "the retry still folded chunk one in")
        let events = await rolling.events
        XCTAssertTrue(events.contains { $0.contains("retrying with a compact state") })
    }

    func testContextOverflowSplitsTheChunkWhenACompactStateIsNotEnough() async throws {
        let fake = FakeDeltaSummarizer()
        let rolling = makeSummarizer(fake)

        let chunk = "Me: first sentence of the chunk. Me: second sentence of the chunk."
        // Fits either half, never the whole chunk.
        fake.maxChunkCharacters = (chunk.count / 2) + 4

        try await rolling.ingest(chunkTranscript: chunk, index: 0)

        XCTAssertEqual(fake.seenRenderStyles, [.full, .compact, .compact, .compact])
        let items = await rolling.state.items
        XCTAssertEqual(items.count, 2, "both halves were ingested")
        let events = await rolling.events
        XCTAssertTrue(events.contains { $0.contains("splitting the chunk in half") })
    }

    func testAHalfThatStillOverflowsIsRecordedAndTheRunContinues() async throws {
        let fake = FakeDeltaSummarizer()
        fake.maxChunkCharacters = 1
        let rolling = makeSummarizer(fake)

        try await rolling.ingest(chunkTranscript: "Me: one sentence. Me: another sentence.", index: 0)
        try await rolling.ingest(chunkTranscript: "Me: later chunk.", index: 1)

        let items = await rolling.state.items
        XCTAssertTrue(items.isEmpty, "nothing could be extracted, but nothing threw either")
        let events = await rolling.events
        XCTAssertEqual(events.filter { $0.contains("half skipped") }.count, 4)
    }

    func testSplitAtSentenceBoundaryPrefersPunctuationThenWhitespace() {
        let sentences = RollingDebriefSummarizer.splitInHalfAtSentenceBoundary("One two three. Four five six.")
        XCTAssertEqual(sentences, ["One two three.", "Four five six."])

        let runOn = RollingDebriefSummarizer.splitInHalfAtSentenceBoundary("one two three four")
        XCTAssertEqual(runOn.count, 2)
        XCTAssertFalse(runOn.contains { $0.isEmpty })

        XCTAssertEqual(RollingDebriefSummarizer.splitInHalfAtSentenceBoundary("single"), ["single"])
    }

    // MARK: - Rendering budget

    func testRenderedItemTextIsTruncatedForTheModelButNotInTheState() async throws {
        let long = String(repeating: "word ", count: 120)
        var state = DebriefState()
        state.items = [DebriefItem(id: 1, kind: .decision, text: long, sourceChunk: 0)]
        state.nextId = 2

        let rendered = state.rendered(language: "en")
        XCTAssertTrue(rendered.contains("…"))
        XCTAssertLessThan(rendered.count, long.count)
        XCTAssertEqual(state.items[0].text, long, "the stored item keeps its full text")
        XCTAssertEqual(state.toDebriefSummary().decisions, [long])
    }

    func testCompactRenderDropsTheSummaryParagraphAndOwnerDue() {
        var state = DebriefState(summary: "A long paragraph about the meeting.")
        state.items = [DebriefItem(id: 1, kind: .action, text: "Send the quote", owner: "Erik", due: "on Friday", sourceChunk: 0)]
        state.nextId = 2

        let compact = state.compacted().rendered(language: "en")
        XCTAssertFalse(compact.contains("SUMMARY SO FAR"))
        XCTAssertFalse(compact.contains("owner: Erik"))
        XCTAssertFalse(compact.contains("due: on Friday"))
        XCTAssertTrue(compact.contains("[1] Send the quote"))
    }

    // MARK: - finish()

    func testFinishReplacesTheSummaryParagraphWithTheConsolidatedOne() async throws {
        let fake = FakeDeltaSummarizer()
        fake.consolidationResult = ConsolidationDelta(summary: "Final polished recap.", dropIds: [])
        let rolling = makeSummarizer(fake)

        try await rolling.ingest(chunkTranscript: "Me: chunk zero", index: 0)
        let summary = try await rolling.finish()

        XCTAssertEqual(fake.consolidateCallCount, 1)
        XCTAssertEqual(summary.summary, "Final polished recap.")
    }

    func testFinishAppliesDropsWithAReasonAndLogsEach() async throws {
        let fake = FakeDeltaSummarizer()
        fake.consolidationResult = ConsolidationDelta(
            summary: "Final recap.",
            dropIds: [.init(id: 3, reason: "transcription fragment, not an item")]
        )
        let rolling = makeSummarizer(fake)

        // 10 items -> cap allows 3 drops, so a single drop is applied.
        for index in 0..<10 {
            try await rolling.ingest(chunkTranscript: "Me: chunk \(index)", index: index)
        }
        let summary = try await rolling.finish()

        XCTAssertEqual(summary.actionItems.count, 9)
        let active = await rolling.state.activeItems
        XCTAssertFalse(active.contains { $0.id == 3 })
        let events = await rolling.events
        XCTAssertTrue(events.contains { $0.contains("dropped id 3 — transcription fragment, not an item") })
    }

    func testFinishIgnoresADropWithNoReason() async throws {
        let fake = FakeDeltaSummarizer()
        fake.consolidationResult = ConsolidationDelta(
            summary: "Final recap.",
            dropIds: [.init(id: 2, reason: "   ")]
        )
        let rolling = makeSummarizer(fake)

        for index in 0..<10 {
            try await rolling.ingest(chunkTranscript: "Me: chunk \(index)", index: index)
        }
        let summary = try await rolling.finish()

        XCTAssertEqual(summary.actionItems.count, 10)
        let events = await rolling.events
        XCTAssertTrue(events.contains { $0.contains("ignored drop of id 2 with no reason") })
    }

    func testConsolidationMayNotDropMoreThanThirtyPercentOfItems() async throws {
        let fake = FakeDeltaSummarizer()
        fake.consolidationResult = ConsolidationDelta(
            summary: "Final recap.",
            dropIds: (1...10).map { .init(id: $0, reason: "too vague") }
        )
        let rolling = makeSummarizer(fake)

        for index in 0..<10 {
            try await rolling.ingest(chunkTranscript: "Me: chunk \(index)", index: index)
        }
        let summary = try await rolling.finish()

        XCTAssertEqual(summary.actionItems.count, 7, "floor(0.3 * 10) = 3 drops applied, the remaining 7 ignored")
        let events = await rolling.events
        XCTAssertEqual(events.filter { $0.contains("over the 30% cap") }.count, 7)
    }

    /// `max(1, …)`: a two-item meeting would otherwise be capped at zero drops
    /// and could never shed a genuine non-item.
    func testAShortMeetingStillAllowsOneDrop() async throws {
        let fake = FakeDeltaSummarizer()
        fake.consolidationResult = ConsolidationDelta(
            summary: "Final recap.",
            dropIds: [.init(id: 1, reason: "stray fragment"), .init(id: 2, reason: "stray fragment")]
        )
        let rolling = makeSummarizer(fake)

        for index in 0..<2 {
            try await rolling.ingest(chunkTranscript: "Me: chunk \(index)", index: index)
        }
        let summary = try await rolling.finish()

        XCTAssertEqual(summary.actionItems.count, 1)
    }

    func testConsolidationDropOfAnUnknownIdIsIgnored() async throws {
        let fake = FakeDeltaSummarizer()
        fake.consolidationResult = ConsolidationDelta(
            summary: "Final recap.",
            dropIds: [.init(id: 999, reason: "not an item")]
        )
        let rolling = makeSummarizer(fake)

        for index in 0..<10 {
            try await rolling.ingest(chunkTranscript: "Me: chunk \(index)", index: index)
        }
        let summary = try await rolling.finish()

        XCTAssertEqual(summary.actionItems.count, 10)
        let events = await rolling.events
        XCTAssertTrue(events.contains { $0.contains("unknown or already-resolved id 999") })
    }

    func testFinishKeepsTheAccumulatedStateWhenConsolidationFails() async throws {
        let fake = FakeDeltaSummarizer()
        fake.consolidateError = DebriefSummarizerError.timeout
        let rolling = makeSummarizer(fake)

        for index in 0..<3 {
            try await rolling.ingest(chunkTranscript: "Me: chunk \(index)", index: index)
        }
        let summary = try await rolling.finish()

        XCTAssertEqual(summary.actionItems.count, 3)
        XCTAssertEqual(summary.summary, "Recap after chunk 2.")
        let events = await rolling.events
        XCTAssertTrue(events.contains { $0.contains("consolidation failed") })
    }

    func testFinishDedupesWithTheInjectedSimilarityFunction() async throws {
        let fake = FakeDeltaSummarizer()
        fake.queuedDeltas = [
            DebriefDelta(summary: "a", newItems: [.init(kind: .action, text: "Book the follow-up")]),
            DebriefDelta(summary: "b", newItems: [.init(kind: .action, text: "Schedule the next call", due: "on Friday")]),
        ]
        fake.consolidationResult = ConsolidationDelta(summary: "Final recap.", dropIds: [])
        let rolling = makeSummarizer(fake, similarity: { _, _ in 1.0 })

        try await rolling.ingest(chunkTranscript: "chunk one", index: 0)
        try await rolling.ingest(chunkTranscript: "chunk two", index: 1)
        let summary = try await rolling.finish()

        XCTAssertEqual(summary.actionItems, [DebriefActionItem(text: "Book the follow-up", owner: nil, due: "on Friday")])
    }

    func testFinishClearsTheSimilarityCache() async throws {
        let fake = FakeDeltaSummarizer()
        let provider = EmbeddingSimilarity(useEmbeddings: false)
        let rolling = RollingDebriefSummarizer(summarizer: fake, similarityProvider: provider, language: "en")

        try await rolling.ingest(chunkTranscript: "Me: chunk zero", index: 0)
        _ = try await rolling.finish()

        XCTAssertEqual(provider.cachedVectorCount, 0)
    }

    // MARK: - Prompts

    func testDeltaPromptReusesTheExistingRulesAndExplainsTheSpeakerLabels() {
        let english = DeltaPromptBuilder.deltaSystemPrompt(language: "en")
        XCTAssertTrue(english.contains("GRAMMATICAL SUBJECT"), "core rules are lifted from DebriefPromptBuilder")
        XCTAssertTrue(english.contains("\"Me:\""))
        XCTAssertTrue(english.contains("\"Them:\""))
        XCTAssertTrue(english.contains("owner is null"))
        XCTAssertTrue(english.contains("resolvedIds"))
        XCTAssertTrue(
            english.contains("send the exact string \"\(DebriefAccumulator.clearSentinel)\""),
            "the prompt must document how a correction clears an owner/due"
        )

        let swedish = DeltaPromptBuilder.deltaSystemPrompt(language: "sv")
        XCTAssertTrue(swedish.contains("\"jag\""), "the Swedish self-owner literal comes from the base prompt")
        XCTAssertFalse(swedish.contains("\"me\""), "no English owner literal leaks into the Swedish prompt")
    }

    func testConsolidationPromptForbidsMerging() {
        let prompt = DeltaPromptBuilder.consolidationSystemPrompt(language: "en")
        XCTAssertTrue(prompt.contains("Do NOT merge items"))
        XCTAssertTrue(prompt.contains("dropIds"))
    }

    // MARK: - Ollama delta JSON parsing

    func testOllamaDeltaParsesAValidResponse() throws {
        let json = """
        {"summary": "We talked about hosting.",
         "newDecisions": ["Go with Postgres"],
         "newActionItems": [{"text": "Book the follow-up", "owner": "Erik", "due": "on Friday"}],
         "newOpenQuestions": ["Who pays for the license"],
         "resolvedIds": [2, 5],
         "corrections": [{"id": 1, "text": "Go with Postgres 16", "owner": null, "due": null}]}
        """

        let delta = try DebriefDeltaParser.parseDelta(json)

        XCTAssertEqual(delta.summary, "We talked about hosting.")
        XCTAssertEqual(delta.newItems.count, 3)
        XCTAssertEqual(delta.newItems[0], .init(kind: .decision, text: "Go with Postgres"))
        XCTAssertEqual(delta.newItems[1], .init(kind: .action, text: "Book the follow-up", owner: "Erik", due: "on Friday"))
        XCTAssertEqual(delta.newItems[2], .init(kind: .openQuestion, text: "Who pays for the license"))
        XCTAssertEqual(delta.resolvedIds, [2, 5])
        XCTAssertEqual(delta.corrections, [.init(id: 1, text: "Go with Postgres 16")])
    }

    func testOllamaDeltaToleratesFencesProseExtraFieldsAndMissingLists() throws {
        let raw = """
        Sure, here you go:
        ```json
        {"summary": "Short recap.", "confidence": 0.8, "newDecisions": ["Ship on Tuesday"]}
        ```
        """

        let delta = try DebriefDeltaParser.parseDelta(raw)

        XCTAssertEqual(delta.summary, "Short recap.")
        XCTAssertEqual(delta.newItems, [.init(kind: .decision, text: "Ship on Tuesday")])
        XCTAssertTrue(delta.resolvedIds.isEmpty)
        XCTAssertTrue(delta.corrections.isEmpty)
    }

    func testOllamaDeltaAcceptsIdsAsNumericStrings() throws {
        let json = """
        {"summary": "Short recap.", "resolvedIds": ["2", "5", "not a number"],
         "corrections": [{"id": "7", "text": "Corrected"}, {"id": "x", "text": "dropped"}]}
        """

        let delta = try DebriefDeltaParser.parseDelta(json)

        XCTAssertEqual(delta.resolvedIds, [2, 5], "a non-numeric id is dropped, not fatal")
        XCTAssertEqual(delta.corrections, [.init(id: 7, text: "Corrected")])
    }

    func testOllamaDeltaWithMissingOrNullSummaryKeepsThePreviousParagraph() throws {
        for json in ["{\"newDecisions\": [\"Ship on Tuesday\"]}", "{\"summary\": null}"] {
            let delta = try DebriefDeltaParser.parseDelta(json)
            XCTAssertEqual(delta.summary, "")

            var accumulator = DebriefAccumulator()
            accumulator.apply(DebriefDelta(summary: "previous paragraph"), chunkIndex: 0)
            accumulator.apply(delta, chunkIndex: 1)
            XCTAssertEqual(accumulator.state.summary, "previous paragraph")
        }
    }

    func testOllamaDeltaThrowsOnMalformedOutput() {
        for raw in ["not json at all", "{ oops", "{\"summary\": \"ok\", \"newDecisions\": \"not an array\"}"] {
            XCTAssertThrowsError(try DebriefDeltaParser.parseDelta(raw), "should reject: \(raw)") { error in
                guard case DebriefSummarizerError.badResponse = error else {
                    return XCTFail("expected .badResponse, got \(error)")
                }
            }
        }
    }

    func testOllamaConsolidationParsesDropsAndTreatsAMissingReasonAsEmpty() throws {
        let json = """
        {"summary": "Final recap.", "dropIds": [{"id": 4, "reason": "stray fragment"}, {"id": "5"}]}
        """

        let consolidation = try DebriefDeltaParser.parseConsolidation(json)

        XCTAssertEqual(consolidation.summary, "Final recap.")
        XCTAssertEqual(consolidation.dropIds, [.init(id: 4, reason: "stray fragment"), .init(id: 5, reason: "")])
    }

    // MARK: - Factory

    func testFactorySelectsTheEngineMatchingTheConfiguredKind() {
        XCTAssertTrue(DeltaSummarizerFactory.make(kind: .ollama, ollamaModel: "llama3") is OllamaDeltaSummarizer)
        XCTAssertTrue(DeltaSummarizerFactory.make(kind: .heuristic, ollamaModel: "llama3") is HeuristicDeltaSummarizer)

        let auto = DeltaSummarizerFactory.make(kind: .auto, ollamaModel: "llama3")
        guard let chained = auto as? ChainedDeltaSummarizer else {
            return XCTFail("auto should produce a ChainedDeltaSummarizer")
        }
        XCTAssertEqual(Array(chained.engineNames.suffix(2)), ["Ollama", "Heuristic"])

        // .foundationModels falls back to the heuristic engine wherever the
        // framework is missing (the macOS 15 CI runner), so only the negative
        // is asserted unconditionally.
        XCTAssertFalse(DeltaSummarizerFactory.make(kind: .foundationModels, ollamaModel: "llama3") is OllamaDeltaSummarizer)
    }

    func testChainedSkipsUnavailableEnginesAndPinsTheFirstThatWorks() async throws {
        let unavailable = FakeDeltaSummarizer(name: "Unavailable")
        unavailable.available = false
        let failing = FakeDeltaSummarizer(name: "Failing")
        failing.extractError = DebriefSummarizerError.timeout
        let working = FakeDeltaSummarizer(name: "Working")

        let chained = ChainedDeltaSummarizer(engines: [unavailable, failing, working])
        let delta = try await chained.extractDelta(state: DebriefState(), chunk: "Me: hello", chunkIndex: 0, language: "en")

        XCTAssertEqual(chained.lastUsedEngineName, "Working")
        XCTAssertEqual(delta.newItems.count, 1)
        XCTAssertTrue(unavailable.seenChunks.isEmpty)
    }

    // MARK: - Heuristic wrapper

    func testHeuristicWrapperTurnsPerChunkItemsIntoNewItemsAndNeverResolves() async throws {
        let engine = HeuristicDeltaSummarizer()
        let delta = try await engine.extractDelta(
            state: DebriefState(),
            chunk: "We decided to use Postgres. I will book the follow-up. It is unclear who pays.",
            chunkIndex: 0,
            language: "en"
        )

        XCTAssertFalse(delta.newItems.isEmpty, "the heuristic engine should bucket something out of this chunk")
        XCTAssertTrue(delta.resolvedIds.isEmpty)
        XCTAssertTrue(delta.corrections.isEmpty)
        XCTAssertFalse(delta.summary.isEmpty)

        var state = DebriefState(summary: "kept", items: [], nextId: 1)
        state.items = [DebriefItem(id: 1, kind: .action, text: "Book it", sourceChunk: 0)]
        let consolidation = try await engine.consolidate(state: state, language: "en")
        XCTAssertEqual(consolidation.summary, "kept")
        XCTAssertTrue(consolidation.dropIds.isEmpty)
    }

    func testHeuristicWrapperDrivesARollingRunEndToEnd() async throws {
        let rolling = RollingDebriefSummarizer(
            summarizer: HeuristicDeltaSummarizer(),
            similarity: EmbeddingSimilarity.jaccard,
            language: "en"
        )

        try await rolling.ingest(chunkTranscript: "Me: We decided to use Postgres.", index: 0)
        try await rolling.ingest(chunkTranscript: "Me: I will book the follow-up meeting.", index: 1)
        let summary = try await rolling.finish()

        let itemCount = summary.decisions.count + summary.actionItems.count + summary.openQuestions.count
        XCTAssertGreaterThanOrEqual(itemCount, 2, "expected the heuristic engine to bucket something from both chunks")
    }

    // MARK: - Similarity

    func testJaccardFallbackScoresParaphrasesAboveUnrelatedPairs() {
        let identical = EmbeddingSimilarity.jaccard("Book the follow-up call", "book the follow-up call!")
        let overlapping = EmbeddingSimilarity.jaccard("Book the follow-up call", "Book the follow-up meeting")
        let unrelated = EmbeddingSimilarity.jaccard("Book the follow-up call", "Review the Falcon repo")

        XCTAssertEqual(identical, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(overlapping, unrelated)
        XCTAssertLessThan(unrelated, 0.3, "only the shared function word \"the\" overlaps")
        XCTAssertEqual(EmbeddingSimilarity.jaccard("", ""), 0.0, accuracy: 0.0001)
    }

    func testSimilarityProviderWithoutEmbeddingsFallsBackToJaccardAndCachesNothing() {
        let provider = EmbeddingSimilarity(useEmbeddings: false)

        XCTAssertEqual(
            provider.similarity("Book the follow-up call", "Book the follow-up meeting"),
            EmbeddingSimilarity.jaccard("Book the follow-up call", "Book the follow-up meeting"),
            accuracy: 0.0001
        )
        XCTAssertEqual(provider.cachedVectorCount, 0)
    }
}
