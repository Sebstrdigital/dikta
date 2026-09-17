/// DebriefRealTranscriptTests — exercises the debrief pipeline two ways:
///
/// 1. Against REAL recorded transcripts, read at runtime from a local,
///    gitignored location — never committed, per the project's hard rule
///    that recordings, transcripts, summaries, and probe outputs never go
///    into git (the repo is public). The location defaults to
///    `DebriefStore.defaultRoot` (`~/Documents/Dikta`) and can be
///    overridden with the `DIKTA_REAL_SESSIONS_DIR` environment variable.
///    Every `<session>/transcript.txt` found there is exercised with
///    generic, content-agnostic assertions — nothing about a specific
///    person, company, or recording is asserted here. If the directory is
///    missing or has no sessions, these tests skip via `XCTSkip` rather than
///    fail, since they depend on data that only exists on a machine that has
///    actually recorded something.
/// 2. Against SYNTHETIC transcripts (made-up names, unrelated to any real
///    recording) that reproduce specific defect shapes found while tuning
///    against real input. These are ordinary, always-committable regression
///    tests.
///
/// See docs/validation.md and feedback_test_real_input.md in project memory
/// for the project rule that debrief/formatter tests should exercise real
/// STT output, and docs/review-2026-09/debrief-probe-2026-09-17.md for the
/// (scrubbed) write-up of what real-input tuning found.

import XCTest
@testable import Dikta

final class DebriefRealTranscriptTests: XCTestCase {
    // MARK: - Real sessions, read at runtime (never committed)

    private static var realSessionsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["DIKTA_REAL_SESSIONS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return DebriefStore.defaultRoot
    }

    /// Every non-empty `<session>/transcript.txt` found under
    /// `realSessionsDirectory`. Returns `[]` if the directory does not exist
    /// or has no sessions.
    private static func realTranscripts() -> [String] {
        let fm = FileManager.default
        guard let sessions = try? fm.contentsOfDirectory(at: realSessionsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return sessions.compactMap { session -> String? in
            let transcriptURL = session.appendingPathComponent("transcript.txt")
            guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func requireRealTranscripts() throws -> [String] {
        let transcripts = Self.realTranscripts()
        guard !transcripts.isEmpty else {
            throw XCTSkip("no local real sessions found under \(Self.realSessionsDirectory.path) — set DIKTA_REAL_SESSIONS_DIR or record a session to run this test")
        }
        return transcripts
    }

    private func detectedLanguage(_ transcript: String) -> String {
        let swedishLetters = CharacterSet(charactersIn: "åäöÅÄÖ")
        return transcript.unicodeScalars.contains(where: swedishLetters.contains) ? "sv" : "en"
    }

    /// For every locally available real transcript, the heuristic summarizer
    /// must produce at least one action item or decision, and must never put
    /// the same item's text in both lists.
    func test_heuristic_onRealTranscripts_producesContentWithoutCrossListDuplication() async throws {
        let transcripts = try requireRealTranscripts()
        let summarizer = HeuristicDebriefSummarizer()

        for transcript in transcripts {
            let summary = try await summarizer.summarize(transcript: transcript, language: detectedLanguage(transcript))

            XCTAssertFalse(
                summary.decisions.isEmpty && summary.actionItems.isEmpty,
                "expected at least one decision or action item for a real transcript"
            )

            let decisionKeys = Set(summary.decisions.map { DebriefActionItem.dedupeKey($0) })
            for actionItem in summary.actionItems {
                XCTAssertFalse(
                    decisionKeys.contains(DebriefActionItem.dedupeKey(actionItem.text)),
                    "action item duplicated in decisions: \(actionItem.text)"
                )
            }
        }
    }

    func test_heuristic_onRealTranscripts_isAlwaysAvailableAndSucceeds() async throws {
        let transcripts = try requireRealTranscripts()
        let summarizer = HeuristicDebriefSummarizer()
        let available = await summarizer.isAvailable()
        XCTAssertTrue(available)

        for transcript in transcripts {
            let summary = try await summarizer.summarize(transcript: transcript, language: detectedLanguage(transcript))
            XCTAssertFalse(summary.summary.isEmpty)
        }
    }

    /// `validated(against:)` must never leave a year-shaped due date that
    /// does not appear anywhere in its own transcript, and must never leave
    /// an owner that was not genuinely spoken in the transcript (first-person
    /// pronouns are exempt, since the speaker never "names" themselves that
    /// way).
    func test_validated_onRealTranscripts_neverLeavesAFabricatedYearOrAbsentOwner() async throws {
        let transcripts = try requireRealTranscripts()
        let summarizer = HeuristicDebriefSummarizer()
        let firstPersonOwners: Set<String> = ["jag", "i", "me"]

        for transcript in transcripts {
            let summary = try await summarizer
                .summarize(transcript: transcript, language: detectedLanguage(transcript))
                .normalized()
                .validated(against: transcript)

            for actionItem in summary.actionItems {
                if let due = actionItem.due, due.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil {
                    XCTAssertTrue(
                        transcript.contains(due),
                        "year-shaped due \"\(due)\" does not appear in its own transcript"
                    )
                }
                if let owner = actionItem.owner, !firstPersonOwners.contains(owner.lowercased()) {
                    XCTAssertTrue(
                        transcript.localizedCaseInsensitiveContains(owner),
                        "owner \"\(owner)\" does not appear anywhere in its own transcript"
                    )
                }
            }
        }
    }

    // MARK: - Known defects, reproduced with synthetic (made-up) transcripts

    /// A made-up transcript in the same shape as the real sessions that
    /// exposed this defect during tuning (see "Tuning round 1" in
    /// docs/review-2026-09/debrief-probe-2026-09-17.md): two people
    /// discussing a project, one of them away for part of the summer, and a
    /// plan to reconvene. None of the names below correspond to any real
    /// recording.
    static let syntheticProjectTranscript = """
    Okay, so I just came out from a business meeting with the project team and it was me, Sebastian and Freja today, 17th September. We were discussing how Lumen is performing and what their direction is. The general consensus is that Lumen is performing good. Freja has been away a lot this summer, but in general she's managed to stay on top of things anyway. I asked Freja again if there is anything available for me to do and she was going to come back to me, so we decided that I should book a new meeting for us one week from now.
    """

    /// On this synthetic transcript, the "book a new meeting" clause
    /// contains "decided", which `HeuristicDebriefSummarizer`'s existing
    /// decision-before-action priority (see its doc comment: openQuestion >
    /// decision > action, one bucket per segment) routes to `decisions`
    /// instead of `actionItems`. This test checks the meeting mention
    /// survives in EITHER list, and — the part that matters — that it never
    /// appears in both, which is guaranteed by that same one-bucket-per-segment
    /// design.
    func test_heuristic_onSyntheticTranscript_capturesMeetingWithoutDuplication() async throws {
        let summarizer = HeuristicDebriefSummarizer()
        let summary = try await summarizer.summarize(transcript: Self.syntheticProjectTranscript, language: "en")

        let mentionsMeeting = summary.decisions.contains { $0.localizedCaseInsensitiveContains("meeting") }
            || summary.actionItems.contains { $0.text.localizedCaseInsensitiveContains("meeting") }
        XCTAssertTrue(mentionsMeeting, "expected the 'book a new meeting' segment to survive somewhere in the summary")

        let decisionKeys = Set(summary.decisions.map { DebriefActionItem.dedupeKey($0) })
        for actionItem in summary.actionItems {
            XCTAssertFalse(
                decisionKeys.contains(DebriefActionItem.dedupeKey(actionItem.text)),
                "action item duplicated in decisions: \(actionItem.text)"
            )
        }
    }

    /// Reproduces, in one `DebriefSummary`, three defects actually seen
    /// across real session summaries during tuning (see "Tuning round 1" in
    /// docs/review-2026-09/debrief-probe-2026-09-17.md): an item duplicated
    /// across decisions and actionItems, a generic collective owner ("Team")
    /// no one named, and an owner with a stray trailing period. `normalized()`
    /// must fix all three in a single pass.
    func test_normalized_fixesAllThreeRealSummaryDefectsTogether() {
        let summary = DebriefSummary(
            summary: "Recap of the Lumen meeting with Freja.",
            decisions: ["Schedule a new meeting for the project team."],
            actionItems: [
                DebriefActionItem(text: "Schedule a new meeting for the project team.", owner: "Sebastian", due: "one week from now"),
                DebriefActionItem(text: "Discuss further opportunities on the project", owner: "Freja.", due: nil),
                DebriefActionItem(text: "Follow up on staffing", owner: "Team", due: nil)
            ],
            openQuestions: []
        ).normalized()

        XCTAssertTrue(summary.decisions.isEmpty, "duplicate decision survived: \(summary.decisions)")
        XCTAssertEqual(summary.actionItems.count, 3, "normalized() must not drop or merge action items, only fix their fields")
        XCTAssertEqual(summary.actionItems[0].text, "Schedule a new meeting for the project team.")
        XCTAssertEqual(summary.actionItems[1].owner, "Freja", "trailing period should be trimmed off the owner")
        XCTAssertNil(summary.actionItems[2].owner, "generic \"Team\" owner should be dropped")
    }

    /// A made-up transcript reproducing the "misattributed but genuinely
    /// spoken owner" defect class (see "Tuning round 2" in
    /// docs/review-2026-09/debrief-probe-2026-09-17.md): the speaker's own
    /// task gets attributed to a business partner whose name is genuinely in
    /// the transcript.
    static let syntheticPartnerTranscript = """
    I just had a meeting with my business partner Marcus and we were talking about our product Nova. We are going to do an analysis of where we are at right now, and what the gap is between what Nova is now and what it needs to be in order to be a production ready product that's possible to sell and is scalable. And we will have a meeting tomorrow the 18th of September and I need to do an initial run with some agents on the repositories to see what's going on.
    """

    /// `validated(against:)` is a narrow, mechanical safety net — it checks
    /// whether an owner/due was said ANYWHERE in the transcript, not whether
    /// it was attached to the right task, so it must NOT null a
    /// genuinely-spoken name even when it's misattributed. Only the prompt's
    /// grammatical-subject rule can fix the actual misattribution; this test
    /// documents that limit rather than asserting a fix this method cannot
    /// provide.
    func test_validated_onSyntheticPartnerSummary_doesNotNullTheGenuineButMisattributedOwner() {
        let defectiveSummary = DebriefSummary(
            summary: "Marcus and I met to discuss our product Nova.",
            decisions: ["We will analyze Nova's current state and identify the gaps to become a production-ready product."],
            actionItems: [
                DebriefActionItem(text: "Conduct an initial run with agents on the repositories.", owner: "Marcus", due: "September 18th"),
                DebriefActionItem(text: "Schedule another meeting.", owner: "Marcus", due: "September 18th")
            ],
            openQuestions: ["How will we measure the gaps and identify the necessary improvements?"]
        )

        let validated = defectiveSummary.normalized().validated(against: Self.syntheticPartnerTranscript)

        XCTAssertEqual(validated.actionItems[0].owner, "Marcus", "misattributed but genuinely-spoken owner survives validated() — a known limit, see doc comment above")
        XCTAssertEqual(validated.actionItems[1].owner, "Marcus")
        // "September 18th" has no 4-digit year or ISO date shape, so
        // validated() never inspects it either way — it survives regardless
        // of transcript content, another documented limit of this method.
        XCTAssertEqual(validated.actionItems[0].due, "September 18th")
    }

    /// A made-up Swedish transcript reproducing the "fabricated year in due"
    /// defect class (see "Tuning round 2" in
    /// docs/review-2026-09/debrief-probe-2026-09-17.md): the model invented a
    /// due date year that was never spoken. `validated(against:)` must null
    /// it.
    static let syntheticSwedishTranscript = """
    Jag, Sebastian, hade precis ett möte med Freja från Lumen och vi pratade om hur sommaren har varit och hon nämnde att de har haft en del utmaningar och farten har inte gått så snabbt som de hade tänkt sig. Vi ska ta ett nytt möte om två veckor där jag ska komma upp med en plan. Så dagens datum, den 17 september, så jag ska boka in ett nytt möte om två veckor och jag ska ta fram en plan för hur vi ska gå tillväga med implementationerna. Utöver det så ska jag se över våra faktureringsprocesser så att rätt konto används.
    """

    func test_validated_onSyntheticSwedishSummary_nullsTheFabricatedYearInDue() {
        let defectiveSummary = DebriefSummary(
            summary: "Jag hade ett möte med Freja från Lumen.",
            decisions: ["Boka nytt möte med Freja den 17 september om två veckor"],
            actionItems: [
                DebriefActionItem(text: "Ta fram en plan för implementationerna", owner: "Sebastian", due: "2024-09-17"),
                DebriefActionItem(text: "Se över våra faktureringsprocesser", owner: "Sebastian", due: "2024-09-17")
            ],
            openQuestions: []
        )

        let validated = defectiveSummary.normalized().validated(against: Self.syntheticSwedishTranscript)

        XCTAssertNil(validated.actionItems[0].due, "fabricated year 2024 never appears in the transcript")
        XCTAssertNil(validated.actionItems[1].due, "fabricated year 2024 never appears in the transcript")
        // The owner IS genuinely spoken ("Jag, Sebastian, hade precis...") so
        // it must survive.
        XCTAssertEqual(validated.actionItems[0].owner, "Sebastian")
    }

    /// A due of "17 september" alone (no year, no ISO shape) — unlike
    /// "2024-09-17" above — contains no digit pattern `validated(against:)`
    /// looks for at all, so it is left untouched EVEN THOUGH it is really
    /// just the meeting's own date being reused for an unrelated task's
    /// deadline (the same defect class the original prompt bug produced, see
    /// "Tuning round 1" in docs/review-2026-09/debrief-probe-2026-09-17.md).
    /// "17 september" does literally appear in this transcript, so even a
    /// literal-substring check would keep it — but the point of this test is
    /// that validated() would keep it either way, because the pattern check
    /// never triggers. Only the prompt's "never reuse an unrelated date"
    /// rule can catch this; it is documented here, not asserted as fixed.
    func test_validated_leavesADueThatReusesTheMeetingsOwnDateAlone_becauseItHasNoYearOrIsoShape() {
        let item = DebriefActionItem(text: "Ta fram en plan för implementationerna", owner: "Sebastian", due: "17 september")
            .validated(against: Self.syntheticSwedishTranscript)

        XCTAssertEqual(item.due, "17 september", "no digit-year/ISO pattern to check — validated() cannot detect this fabrication class")
    }
}
