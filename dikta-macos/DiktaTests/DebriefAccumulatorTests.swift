import XCTest
@testable import Dikta

/// Covers the deterministic half of the rolling debrief: applying a delta, and
/// deduping. No engine, no network, no Foundation Models.
final class DebriefAccumulatorTests: XCTestCase {

    // MARK: - Helpers

    /// Similarity stub: 1.0 for pairs explicitly declared identical, else 0.
    /// Keeps dedupe tests independent of any real embedding model.
    private func stubSimilarity(pairs: [(String, String)]) -> (String, String) -> Double {
        { a, b in
            for pair in pairs where (pair.0 == a && pair.1 == b) || (pair.0 == b && pair.1 == a) {
                return 1.0
            }
            return 0.0
        }
    }

    private func delta(
        summary: String = "so far",
        new: [DebriefDelta.NewItem] = [],
        resolved: [Int] = [],
        corrections: [DebriefDelta.Correction] = []
    ) -> DebriefDelta {
        DebriefDelta(summary: summary, newItems: new, resolvedIds: resolved, corrections: corrections)
    }

    // MARK: - Applying deltas

    func testAppendAssignsFreshSequentialIds() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(
            delta(new: [
                .init(kind: .decision, text: "Go with Postgres"),
                .init(kind: .action, text: "Book the follow-up", owner: "Erik", due: "on Friday"),
                .init(kind: .openQuestion, text: "Who pays for the license"),
            ]),
            chunkIndex: 0
        )

        XCTAssertEqual(accumulator.state.items.map(\.id), [1, 2, 3])
        XCTAssertEqual(accumulator.state.nextId, 4)
        XCTAssertEqual(accumulator.state.items.map(\.sourceChunk), [0, 0, 0])
        XCTAssertEqual(accumulator.state.items[1].owner, "Erik")
        XCTAssertEqual(accumulator.state.items[1].due, "on Friday")
    }

    func testSummaryIsReplacedButNeverByAnEmptyOne() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(delta(summary: "first paragraph"), chunkIndex: 0)
        XCTAssertEqual(accumulator.state.summary, "first paragraph")

        accumulator.apply(delta(summary: "second paragraph"), chunkIndex: 1)
        XCTAssertEqual(accumulator.state.summary, "second paragraph")

        accumulator.apply(delta(summary: "   "), chunkIndex: 2)
        XCTAssertEqual(accumulator.state.summary, "second paragraph")
    }

    func testResolveByIdMarksResolvedAndRemovesItFromActive() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(
            delta(new: [
                .init(kind: .openQuestion, text: "Do we need a second server"),
                .init(kind: .decision, text: "Ship on Tuesday"),
            ]),
            chunkIndex: 0
        )
        accumulator.apply(delta(resolved: [1]), chunkIndex: 1)

        XCTAssertEqual(accumulator.state.items.count, 2, "resolved items stay in the list so ids stay stable")
        XCTAssertEqual(accumulator.state.activeItems.map(\.id), [2])
        XCTAssertTrue(accumulator.state.items[0].resolved)
    }

    func testCorrectionByIdReplacesTextOwnerAndDue() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(delta(new: [.init(kind: .action, text: "Send teh deck")]), chunkIndex: 0)
        accumulator.apply(
            delta(corrections: [.init(id: 1, text: "Send the deck", owner: "Anna", due: "tomorrow")]),
            chunkIndex: 1
        )

        XCTAssertEqual(accumulator.state.items[0].text, "Send the deck")
        XCTAssertEqual(accumulator.state.items[0].owner, "Anna")
        XCTAssertEqual(accumulator.state.items[0].due, "tomorrow")
    }

    func testUnknownIdsAreIgnoredAndLogged() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(delta(new: [.init(kind: .decision, text: "Ship on Tuesday")]), chunkIndex: 0)
        accumulator.apply(
            delta(resolved: [99], corrections: [.init(id: 42, text: "nonsense")]),
            chunkIndex: 1
        )

        XCTAssertEqual(accumulator.state.activeItems.count, 1)
        XCTAssertEqual(accumulator.state.items[0].text, "Ship on Tuesday")
        XCTAssertTrue(accumulator.events.contains { $0.contains("unknown or already-resolved id 99") })
        XCTAssertTrue(accumulator.events.contains { $0.contains("unknown id 42") })
    }

    func testPlaceholderShapedItemTextIsNeverAdded() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(
            delta(new: [
                .init(kind: .openQuestion, text: "null"),
                .init(kind: .decision, text: "  "),
                .init(kind: .decision, text: "Ship on Tuesday"),
            ]),
            chunkIndex: 0
        )

        XCTAssertEqual(accumulator.state.items.map(\.text), ["Ship on Tuesday"])
    }

    // MARK: - Dedupe

    func testExactDuplicateIsCollapsedIgnoringCaseAndPunctuation() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(delta(new: [.init(kind: .action, text: "Book the follow-up call.")]), chunkIndex: 0)
        accumulator.apply(delta(new: [.init(kind: .action, text: "  Book the Follow-Up call!  ")]), chunkIndex: 1)

        accumulator.dedupe(using: { _, _ in 0 })

        XCTAssertEqual(accumulator.state.activeItems.count, 1)
        XCTAssertEqual(accumulator.state.activeItems[0].id, 1, "the earlier item survives")
        XCTAssertEqual(accumulator.state.activeItems[0].text, "Book the follow-up call.")
    }

    func testNearDuplicateIsCollapsedViaInjectedSimilarity() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(delta(new: [.init(kind: .action, text: "Book the follow-up")]), chunkIndex: 0)
        accumulator.apply(delta(new: [.init(kind: .action, text: "Schedule the next call")]), chunkIndex: 1)

        accumulator.dedupe(
            using: stubSimilarity(pairs: [("Book the follow-up", "Schedule the next call")]),
            threshold: 0.9
        )

        XCTAssertEqual(accumulator.state.activeItems.map(\.id), [1])
        XCTAssertTrue(accumulator.events.contains { $0.contains("deduped 1 duplicate item(s)") })
    }

    func testSimilarityBelowThresholdKeepsBothItems() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(delta(new: [.init(kind: .action, text: "Book the follow-up")]), chunkIndex: 0)
        accumulator.apply(delta(new: [.init(kind: .action, text: "Review the Falcon repo")]), chunkIndex: 1)

        accumulator.dedupe(using: { _, _ in 0.5 }, threshold: 0.9)

        XCTAssertEqual(accumulator.state.activeItems.count, 2)
    }

    func testItemsOfDifferentKindsAreNeverMergedEvenWithIdenticalText() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(
            delta(new: [
                .init(kind: .decision, text: "Book the meeting"),
                .init(kind: .action, text: "Book the meeting"),
            ]),
            chunkIndex: 0
        )

        accumulator.dedupe(using: { _, _ in 1.0 }, threshold: 0.9)

        XCTAssertEqual(accumulator.state.activeItems.count, 2)
    }

    func testDedupeBackfillsMissingOwnerAndDueFromTheLaterDuplicate() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(delta(new: [.init(kind: .action, text: "Send the quote")]), chunkIndex: 0)
        accumulator.apply(
            delta(new: [.init(kind: .action, text: "send the quote", owner: "Erik", due: "on Friday")]),
            chunkIndex: 1
        )

        accumulator.dedupe(using: { _, _ in 0 })

        XCTAssertEqual(accumulator.state.activeItems.count, 1)
        let survivor = accumulator.state.activeItems[0]
        XCTAssertEqual(survivor.id, 1)
        XCTAssertEqual(survivor.owner, "Erik")
        XCTAssertEqual(survivor.due, "on Friday")
    }

    func testDedupeNeverOverwritesAnOwnerTheSurvivorAlreadyHas() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(delta(new: [.init(kind: .action, text: "Send the quote", owner: "Anna")]), chunkIndex: 0)
        accumulator.apply(delta(new: [.init(kind: .action, text: "Send the quote", owner: "Erik")]), chunkIndex: 1)

        accumulator.dedupe(using: { _, _ in 0 })

        XCTAssertEqual(accumulator.state.activeItems.map(\.owner), ["Anna"])
    }

    func testDedupeIgnoresResolvedItems() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(delta(new: [.init(kind: .decision, text: "Ship on Tuesday")]), chunkIndex: 0)
        accumulator.apply(delta(resolved: [1]), chunkIndex: 1)
        accumulator.apply(delta(new: [.init(kind: .decision, text: "Ship on Tuesday")]), chunkIndex: 2)

        accumulator.dedupe(using: { _, _ in 1.0 })

        XCTAssertEqual(accumulator.state.items.count, 2)
        XCTAssertEqual(accumulator.state.activeItems.map(\.id), [2])
    }

    /// Dedupe is quadratic, so the cheap checks have to carry it: a similarity
    /// call is spent at most once per unordered pair of ACTIVE items of the
    /// SAME kind, and never on a pair whose normalized texts already match.
    func testSimilarityIsCalledAtMostOncePerPairOfTheSameKind() {
        var accumulator = DebriefAccumulator()
        for index in 0..<5 {
            accumulator.apply(delta(new: [.init(kind: .action, text: "Action \(index)")]), chunkIndex: index)
            accumulator.apply(delta(new: [.init(kind: .decision, text: "Decision \(index)")]), chunkIndex: index)
        }

        var callCount = 0
        accumulator.dedupe(using: { _, _ in callCount += 1; return 0 })

        // 5 items of each of 2 kinds: at most 2 * 5*4/2 = 20 comparisons, and
        // never a cross-kind one.
        XCTAssertLessThanOrEqual(callCount, 20)
        XCTAssertEqual(accumulator.state.activeItems.count, 10)
    }

    func testRepeatedIdenticalTextsCostNoSimilarityCallsAtAll() {
        var accumulator = DebriefAccumulator()
        for index in 0..<6 {
            accumulator.apply(delta(new: [.init(kind: .action, text: "Book the follow-up")]), chunkIndex: index)
        }

        var callCount = 0
        accumulator.dedupe(using: { _, _ in callCount += 1; return 0 })

        XCTAssertEqual(callCount, 0, "exact-match dedupe must never reach the similarity function")
        XCTAssertEqual(accumulator.state.activeItems.count, 1)
    }

    // MARK: - Clearing an owner/due

    func testCorrectionClearsOwnerOrDueOnlyViaTheExplicitNullSentinel() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(
            delta(new: [
                .init(kind: .action, text: "Send the quote", owner: "Erik", due: "on Friday"),
                .init(kind: .action, text: "Call the supplier", owner: "Anna", due: "tomorrow"),
            ]),
            chunkIndex: 0
        )

        // Omitted fields keep what is there; the sentinel clears it.
        accumulator.apply(delta(corrections: [.init(id: 1, text: "Send the quote")]), chunkIndex: 1)
        XCTAssertEqual(accumulator.state.items[0].owner, "Erik")
        XCTAssertEqual(accumulator.state.items[0].due, "on Friday")

        accumulator.apply(
            delta(corrections: [.init(id: 2, text: "Call the supplier", owner: "null", due: "NULL")]),
            chunkIndex: 2
        )
        XCTAssertNil(accumulator.state.items[1].owner)
        XCTAssertNil(accumulator.state.items[1].due)
    }

    // MARK: - Rendering

    func testRenderedStateIsNumberedAndOmitsResolvedItems() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(
            delta(
                summary: "We talked about hosting.",
                new: [
                    .init(kind: .decision, text: "Go with Postgres"),
                    .init(kind: .action, text: "Book the follow-up", owner: "Erik", due: "on Friday"),
                    .init(kind: .openQuestion, text: "Who pays for the license"),
                ]
            ),
            chunkIndex: 0
        )
        accumulator.apply(delta(summary: "We talked about hosting.", resolved: [3]), chunkIndex: 1)

        let rendered = accumulator.state.rendered(language: "en")

        XCTAssertTrue(rendered.contains("[1] Go with Postgres"))
        XCTAssertTrue(rendered.contains("[2] Book the follow-up | owner: Erik | due: on Friday"))
        XCTAssertFalse(rendered.contains("[3]"), "resolved items are not shown back to the model")
        XCTAssertTrue(rendered.contains("OPEN QUESTIONS (numbered):\n(none)"))
        XCTAssertTrue(rendered.contains("We talked about hosting."))
    }

    func testRenderedEmptyStateSaysNoneEverywhere() {
        let rendered = DebriefState().rendered(language: "sv")

        XCTAssertTrue(rendered.contains("SUMMARY SO FAR:\n(none yet)"))
        XCTAssertTrue(rendered.contains("DECISIONS (numbered):\n(none)"))
        XCTAssertTrue(rendered.contains("ACTION ITEMS (numbered):\n(none)"))
    }

    // MARK: - Projection to DebriefSummary

    func testToDebriefSummaryBucketsActiveItemsByKind() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(
            delta(
                summary: "Short recap.",
                new: [
                    .init(kind: .decision, text: "Go with Postgres"),
                    .init(kind: .action, text: "Book the follow-up", owner: "Erik", due: "on Friday"),
                    .init(kind: .openQuestion, text: "Who pays for the license"),
                    .init(kind: .action, text: "Send the quote"),
                ]
            ),
            chunkIndex: 0
        )
        accumulator.apply(delta(summary: "Short recap.", resolved: [4]), chunkIndex: 1)

        let summary = accumulator.state.toDebriefSummary()

        XCTAssertEqual(summary.summary, "Short recap.")
        XCTAssertEqual(summary.decisions, ["Go with Postgres"])
        XCTAssertEqual(summary.actionItems, [DebriefActionItem(text: "Book the follow-up", owner: "Erik", due: "on Friday")])
        XCTAssertEqual(summary.openQuestions, ["Who pays for the license"])
    }

    /// The chunk transcripts carry "Me:"/"Them:" speaker labels, so a model
    /// that half-follows the ownership rule writes the LABEL as the owner. A
    /// participant who was never named must come out as a null owner, not as
    /// the literal "them" (nor a generic group, which the app's own
    /// `genericOwnerPlaceholders` already covers).
    func testSpeakerLabelOwnerIsNormalizedAwayEverywhere() {
        var accumulator = DebriefAccumulator()
        accumulator.apply(
            delta(new: [
                .init(kind: .action, text: "Send the contract", owner: "Them"),
                .init(kind: .action, text: "Prepare the invoice", owner: "dem"),
                .init(kind: .action, text: "Review the specs", owner: "the team"),
                .init(kind: .action, text: "Call the supplier", owner: "Erik"),
            ]),
            chunkIndex: 0
        )

        XCTAssertEqual(accumulator.state.items.map(\.owner), [nil, nil, nil, "Erik"])

        // And a "them" that reached the state some other way still never
        // renders: toDebriefSummary normalizes on the way out too.
        var state = DebriefState()
        state.items = [DebriefItem(id: 1, kind: .action, text: "Send the contract", owner: "them", sourceChunk: 0)]
        state.nextId = 2

        XCTAssertEqual(state.toDebriefSummary().actionItems, [DebriefActionItem(text: "Send the contract", owner: nil, due: nil)])
    }

    // MARK: - Monotonicity

    /// The property the whole design exists for: across many chunks the active
    /// item count only ever goes UP, except where this type itself lowers it
    /// (a resolve or a dedupe). Nothing a model returns can shrink the list.
    func testActiveCountNeverDecreasesWithoutAResolveOrDedupe() {
        var accumulator = DebriefAccumulator()
        var previousCount = 0

        for index in 0..<12 {
            accumulator.apply(
                delta(
                    summary: "recap after chunk \(index)",
                    new: [.init(kind: .action, text: "Task from chunk \(index)")]
                ),
                chunkIndex: index
            )
            accumulator.dedupe(using: { _, _ in 0 })

            let count = accumulator.state.activeItems.count
            XCTAssertGreaterThanOrEqual(count, previousCount, "active count dropped at chunk \(index)")
            previousCount = count
        }

        XCTAssertEqual(previousCount, 12)
    }
}
