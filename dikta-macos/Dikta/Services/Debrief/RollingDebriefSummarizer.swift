import Foundation

/// Builds a `DebriefSummary` incrementally, one transcript chunk at a time,
/// without ever letting the model regenerate the item list.
///
/// The ownership split (decision 8, `tasks/decisions-call-debrief.md`) is:
/// - the MODEL sees a numbered state and proposes a delta — new items,
///   resolved ids, corrections, and a rewritten summary paragraph;
/// - SWIFT owns the list: it assigns ids, applies the delta, and does all
///   deduplication itself.
///
/// The spike behind that split found naive rolling regeneration had lost every
/// action item by chunk 2, while a code-side accumulator stayed monotone; and
/// that model-proposed MERGES were mostly wrong (unrelated items paired, real
/// duplicates split) while model-proposed "this is not an item" DROPS were
/// reasonable. So the model may drop, and may never merge.
///
/// An `actor`, because chunks arrive from a live transcription pipeline and two
/// `ingest` calls can overlap; and because a delta is only meaningful against
/// the state it was computed from, overlapping calls are additionally chained
/// through `serialized(_:)` so they run to completion in CALL order rather than
/// interleaving at their `await` points (actor reentrancy alone would allow the
/// second chunk to fold in while the first is still waiting on the model).
actor RollingDebriefSummarizer {
    /// Fraction of the active items one consolidation pass may drop. Anything
    /// beyond this is ignored and logged — a model asking to delete half the
    /// meeting is the probe's "undeclared drop" failure wearing a reason field.
    static let maxDropFraction = 0.3

    private let summarizer: DeltaSummarizing
    private let similarity: (String, String) -> Double
    private let resetSimilarityCache: () -> Void
    private let language: String
    private let dedupeThreshold: Double

    private var accumulator: DebriefAccumulator
    /// Tail of the serial chain: each queued operation awaits its predecessor.
    private var queueTail: Task<Void, Never>?

    /// The accumulated state: readable between chunks for a live "so far" view,
    /// and for tests.
    var state: DebriefState { accumulator.state }

    /// Everything the accumulator and this type ignored, collapsed, or retried,
    /// in order.
    var events: [String] { accumulator.events }

    init(
        summarizer: DeltaSummarizing,
        similarity: @escaping (String, String) -> Double,
        language: String,
        dedupeThreshold: Double = 0.9,
        initialState: DebriefState = DebriefState(),
        resetSimilarityCache: @escaping () -> Void = {}
    ) {
        self.summarizer = summarizer
        self.similarity = similarity
        self.language = language
        self.dedupeThreshold = dedupeThreshold
        self.accumulator = DebriefAccumulator(state: initialState)
        self.resetSimilarityCache = resetSimilarityCache
    }

    /// Convenience init pairing the summarizer with an `EmbeddingSimilarity`
    /// whose memoization cache is cleared when the meeting ends.
    init(
        summarizer: DeltaSummarizing,
        similarityProvider: EmbeddingSimilarity,
        language: String,
        dedupeThreshold: Double = 0.9,
        initialState: DebriefState = DebriefState()
    ) {
        self.init(
            summarizer: summarizer,
            similarity: similarityProvider.callable(),
            language: language,
            dedupeThreshold: dedupeThreshold,
            initialState: initialState,
            resetSimilarityCache: { similarityProvider.clearCache() }
        )
    }

    // MARK: - Ingest

    /// Feeds one chunk of transcript through the engine and folds the resulting
    /// delta into the state, then dedupes.
    ///
    /// Deduping every chunk (rather than only at the end) keeps the numbered
    /// state the model reads short and free of repeats, which is what stops it
    /// re-proposing an item it already contributed.
    func ingest(chunkTranscript: String, index: Int) async throws {
        try await serialized { try await self.performIngest(chunkTranscript: chunkTranscript, index: index) }
    }

    private func performIngest(chunkTranscript: String, index: Int) async throws {
        let trimmed = chunkTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try await ingestOne(chunk: trimmed, index: index, state: accumulator.state)
            return
        } catch let error as DeltaSummarizerError {
            accumulator.record("chunk \(index): \(error.localizedDescription) — retrying with a compact state")
            _ = error
        }

        // Ladder step 1: same chunk, smaller view of the state (ids + text only).
        do {
            try await ingestOne(chunk: trimmed, index: index, state: accumulator.state.compacted())
            return
        } catch is DeltaSummarizerError {
            accumulator.record("chunk \(index): still too long with a compact state — splitting the chunk in half")
        }

        // Ladder step 2: split the chunk at a sentence boundary and ingest both
        // halves against the compact state. A half that still fails is recorded
        // and skipped: losing one half of one chunk beats losing the meeting.
        let halves = Self.splitInHalfAtSentenceBoundary(trimmed)
        guard halves.count == 2 else {
            accumulator.record("chunk \(index): too long and not splittable — chunk skipped")
            return
        }

        for (offset, half) in halves.enumerated() {
            do {
                try await ingestOne(chunk: half, index: index, state: accumulator.state.compacted())
            } catch let error as DeltaSummarizerError {
                accumulator.record("chunk \(index) half \(offset + 1): \(error.localizedDescription) — half skipped")
            }
        }
    }

    /// One engine call plus the deterministic fold. Non-context errors (network
    /// down, model unavailable) propagate unchanged — only
    /// `DeltaSummarizerError` is retryable.
    private func ingestOne(chunk: String, index: Int, state: DebriefState) async throws {
        let delta = try await summarizer.extractDelta(
            state: state,
            chunk: chunk,
            chunkIndex: index,
            language: language
        )
        accumulator.apply(delta, chunkIndex: index)
        accumulator.dedupe(using: similarity, threshold: dedupeThreshold)
    }

    /// Splits `text` into two roughly equal halves at the sentence boundary
    /// nearest the midpoint, falling back to the nearest whitespace boundary
    /// for an unpunctuated run-on (which speech-to-text produces often enough
    /// to matter). Returns a single element when there is nothing to split on.
    static func splitInHalfAtSentenceBoundary(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count > 1 else { return [text] }
        let midpoint = characters.count / 2

        func nearestIndex(where predicate: (Character) -> Bool) -> Int? {
            for offset in 0..<characters.count {
                let forward = midpoint + offset
                if forward < characters.count - 1, predicate(characters[forward]) { return forward }
                let backward = midpoint - offset
                if backward > 0, predicate(characters[backward]) { return backward }
            }
            return nil
        }

        let boundary = nearestIndex(where: { ".!?".contains($0) })
            ?? nearestIndex(where: { $0.isWhitespace })
        guard let boundary else { return [text] }

        let first = String(characters[...boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        let second = String(characters[(boundary + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !second.isEmpty else { return [text] }
        return [first, second]
    }

    // MARK: - finish()

    /// Closes the meeting: a final dedupe, one consolidation pass, then a last
    /// dedupe (a correction applied during consolidation can create a new
    /// duplicate), and projects the result into `DebriefSummary`.
    ///
    /// A consolidation failure is logged and swallowed rather than losing the
    /// whole meeting: every item already survives in the accumulator, and the
    /// summary paragraph from the last chunk is still there. Cancellation is
    /// still propagated.
    func finish() async throws -> DebriefSummary {
        try await serialized { try await self.performFinish() }
    }

    private func performFinish() async throws -> DebriefSummary {
        accumulator.dedupe(using: similarity, threshold: dedupeThreshold)

        do {
            let consolidation = try await summarizer.consolidate(state: accumulator.state, language: language)
            applyConsolidation(consolidation)
        } catch let error as CancellationError {
            throw error
        } catch {
            accumulator.record("consolidation failed, keeping accumulated state: \(String(describing: error))")
        }

        accumulator.dedupe(using: similarity, threshold: dedupeThreshold)
        let summary = accumulator.state.toDebriefSummary()
        resetSimilarityCache()
        return summary
    }

    /// Applies a consolidation delta: the summary paragraph is replaced, and
    /// drops are applied in order up to the 30 % cap — `max(1, floor(0.3 * n))`
    /// once at least one item exists, so a short meeting can still shed one
    /// genuine non-item instead of being capped at zero.
    ///
    /// A drop with an empty reason is never applied: an unexplained drop is
    /// indistinguishable from the model silently shrinking the list, which is
    /// the exact failure this whole design exists to prevent.
    private func applyConsolidation(_ consolidation: ConsolidationDelta) {
        let activeCount = accumulator.state.activeItems.count
        let allowedDrops = (activeCount >= 1 && !consolidation.dropIds.isEmpty)
            ? max(1, Int((Double(activeCount) * Self.maxDropFraction).rounded(.down)))
            : 0
        var appliedDrops = 0

        for drop in consolidation.dropIds {
            guard !drop.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                accumulator.record("consolidation: ignored drop of id \(drop.id) with no reason given")
                continue
            }
            guard appliedDrops < allowedDrops else {
                accumulator.record(
                    "consolidation: ignored drop of id \(drop.id) (\(drop.reason)) — over the \(Int(Self.maxDropFraction * 100))% cap of \(allowedDrops) of \(activeCount) items"
                )
                continue
            }
            guard accumulator.markResolved(drop.id) else {
                accumulator.record("consolidation: ignored drop of unknown or already-resolved id \(drop.id)")
                continue
            }
            accumulator.record("consolidation: dropped id \(drop.id) — \(drop.reason)")
            appliedDrops += 1
        }

        let trimmedSummary = consolidation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            accumulator.setSummary(trimmedSummary)
        }
    }

    // MARK: - Serialization

    /// Runs `body` after every operation enqueued before it. The chain is
    /// extended synchronously, on the actor, so the order operations run in is
    /// the order their calls reached the actor. A failed operation does not
    /// fail its successors.
    private func serialized<T>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task<T, Error> {
            _ = await previous?.result
            return try await body()
        }
        queueTail = Task { _ = await task.result }
        return try await task.value
    }
}
