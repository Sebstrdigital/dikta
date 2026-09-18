import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Measures how a ROLLING meeting summary (summary_i = FM(summary_{i-1}, chunk_i))
// drifts over many chunk iterations, compared against a single consolidation
// pass and a map-reduce baseline — see tasks/decisions-call-debrief.md,
// decision 8 and Spike item 3 ("Rolling summary quality: summary + chunk ->
// summary over ~12 iterations on one real 1h recording. Does it drift/dedupe
// badly?").
//
// This is a THROWAWAY SPIKE probe, standalone from debrief-probe.swift and
// deliberately self-contained: it does NOT import or compile against
// dikta-macos/Dikta/ — the domain model, prompt rules, and @Generable schema
// below are copies/adaptations of DebriefSummary.swift, DebriefSummarizer.swift
// (DebriefPromptBuilder) and FoundationModelsDebriefSummarizer.swift, trimmed
// and reshaped for the rolling/map-reduce/single-pass comparison this probe
// needs. Nothing under dikta-macos/Dikta/ is modified or linked.
//
// PRIVACY: real transcripts (~/Documents/Dikta/<timestamp>/transcript.txt) are
// read locally to build the corpora below but are never printed verbatim to
// stdout beyond individual action-item/decision/question TEXT inside the
// per-run JSON dump — that JSON goes to bench/results/rolling-summary/, which
// is gitignored (see dikta-macos/.gitignore: "bench/probes/debrief-corpus/"
// and "bench/results/*"). Only structural metrics (counts, word counts,
// timings) are meant to leave this directory into any report.
//
// ---- Compile (adapted from debrief-probe.swift's documented command in
// docs/review-2026-09/debrief-probe-2026-09-17.md — this probe has no
// dependency on dikta-macos/Dikta/ sources, so only this one file is needed) ----
//
//   swiftc -O -parse-as-library -target arm64-apple-macos26.0 \
//     dikta-macos/bench/probes/rolling-summary-probe.swift \
//     -o /tmp/rolling-summary-probe -framework FoundationModels
//
// ---- Run ----
//
//   /tmp/rolling-summary-probe > dikta-macos/bench/results/rolling-summary/run.log 2>&1
//
// Flags (all optional):
//   --sessions-dir <dir>   default ~/Documents/Dikta — reads <dir>/*/transcript.txt
//   --chunk-words <N>      default 750 (~5 min of speech, matching decision 8's
//                          chunk size). See main() for why this run overrides
//                          it down for the available (short) real transcripts.

// MARK: - Domain model

/// A single follow-up task. Mirrors `DebriefActionItem` (dikta-macos/Dikta/Models/DebriefSummary.swift).
struct ActionItem: Codable, Equatable {
    var text: String
    var owner: String?
    var due: String?
}

/// Mirrors `DebriefSummary`'s shape exactly (same 4 fields) so every FM call in
/// this probe — single-pass, rolling-update, consolidation, map-reduce chunk,
/// map-reduce merge — targets the identical schema the app itself uses.
struct RollingSummary: Codable, Equatable {
    var summary: String
    var decisions: [String]
    var actionItems: [ActionItem]
    var openQuestions: [String]

    static let empty = RollingSummary(summary: "", decisions: [], actionItems: [], openQuestions: [])
}

/// Normalization rules copied from `DebriefActionItem`/`DebriefSummary`
/// (dikta-macos/Dikta/Models/DebriefSummary.swift) — placeholder values FM
/// substitutes instead of null, generic collective owners, edge-punctuation
/// trimming, and a dedupe key for comparing two item strings as "the same
/// item". Kept as a copy rather than an import per this probe's "must not
/// link the app" constraint.
enum Normalize {
    static let placeholderValues: Set<String> = [
        "not specified", "tbd", "n/a", "na", "none", "unknown", "null",
        "ingen", "ingen specificerad", "ingen angiven", "ej angivet",
        "ej specificerat", "okänd", "-", "–", "—"
    ]

    static let genericOwnerPlaceholders: Set<String> = [
        "team", "the team", "everyone", "all", "teamet", "alla"
    ]

    private static let edgePunctuation: Set<Character> = [".", ",", ";", ":"]

    private static func trimmedOfEdgePunctuation(_ value: String) -> String {
        var result = Substring(value)
        func isTrimmable(_ c: Character) -> Bool { c.isWhitespace || edgePunctuation.contains(c) }
        while let first = result.first, isTrimmable(first) { result.removeFirst() }
        while let last = result.last, isTrimmable(last) { result.removeLast() }
        return String(result)
    }

    static func field(_ value: String?, extraPlaceholders: Set<String> = []) -> String? {
        guard let value else { return nil }
        let trimmed = trimmedOfEdgePunctuation(value.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.isEmpty { return nil }
        let lowercased = trimmed.lowercased()
        if placeholderValues.contains(lowercased) || extraPlaceholders.contains(lowercased) { return nil }
        return trimmed
    }

    /// Normalized comparison key for "is this the same item as that one":
    /// lowercased, punctuation stripped, whitespace-trimmed.
    static func dedupeKey(_ text: String) -> String {
        let lowercased = text.lowercased()
        let withoutPunctuation = String(lowercased.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) })
        return withoutPunctuation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let emptyContentPlaceholders = placeholderValues.union(["inga"])

    static func isEmptyOrPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return emptyContentPlaceholders.contains(trimmed.lowercased())
    }
}

// MARK: - Delta-mode accumulator (ablation A)

/// Which of the three item lists an `AccumulatedItem` belongs to. Delta mode
/// numbers items across all three categories in one shared id space so a
/// single `resolvedItemIds`/`corrections` id list (as the model sees it) can
/// reference any of them.
enum ItemCategory {
    case decision, action, question
}

/// One item tracked by the delta-mode accumulator. `resolved` items are kept
/// (not deleted) so ids stay stable and a resolved item's original text is
/// still available for the "over-eager resolution" check against single-pass.
struct AccumulatedItem {
    let id: Int
    let category: ItemCategory
    var text: String
    var owner: String? = nil
    var due: String? = nil
    var resolved: Bool = false
}

/// Deterministic accumulator for delta mode: the model never re-emits the
/// whole state, only what changed (new items / resolved ids / corrections);
/// this struct applies that delta in plain Swift. Because items are only
/// ever added or explicitly marked resolved — never silently dropped by a
/// re-generation — `activeItems.count` cannot decrease except by an id the
/// model explicitly listed in `resolvedItemIds`, unlike naive rolling mode
/// where the whole state is regenerated (and can silently lose items) each
/// iteration.
struct Accumulator {
    private(set) var items: [AccumulatedItem] = []
    private var nextId = 1
    /// The free-text summary paragraph, fully regenerated each iteration
    /// (per the ablation spec: "summary text is cheap to lose; items are
    /// not" — so only the summary field, not the item lists, is allowed to
    /// be a full re-generation each step).
    var summaryText: String = ""

    var activeItems: [AccumulatedItem] { items.filter { !$0.resolved } }

    mutating func addDecision(_ text: String) {
        items.append(AccumulatedItem(id: nextId, category: .decision, text: text))
        nextId += 1
    }

    mutating func addAction(_ item: ActionItem) {
        items.append(AccumulatedItem(id: nextId, category: .action, text: item.text, owner: item.owner, due: item.due))
        nextId += 1
    }

    mutating func addQuestion(_ text: String) {
        items.append(AccumulatedItem(id: nextId, category: .question, text: text))
        nextId += 1
    }

    /// Marks `id` resolved if it exists and is currently active. Returns
    /// whether it actually changed anything, so callers can count only real
    /// resolutions (a hallucinated or already-resolved id is a no-op).
    @discardableResult
    mutating func markResolved(_ id: Int) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id && !$0.resolved }) else { return false }
        items[idx].resolved = true
        return true
    }

    @discardableResult
    mutating func applyCorrection(id: Int, text: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        items[idx].text = text
        return true
    }

    func toRollingSummary() -> RollingSummary {
        RollingSummary(
            summary: summaryText,
            decisions: activeItems.filter { $0.category == .decision }.map(\.text),
            actionItems: activeItems.filter { $0.category == .action }.map { ActionItem(text: $0.text, owner: $0.owner, due: $0.due) },
            openQuestions: activeItems.filter { $0.category == .question }.map(\.text)
        )
    }

    /// Applies a DELTA-shaped consolidation result (see `DeltaConsolidationDeltaGenerable`):
    /// merge-group member ids are marked resolved and replaced by one new
    /// item (category taken from the first surviving member; the
    /// merge-group's owner/due, if any, only matters for an `.action`
    /// category item), drop ids are marked resolved directly, and any id
    /// mentioned in NEITHER list is left completely untouched. Unlike
    /// `deltaConsolidate`'s free-form `DeltaConsolidationGenerable`, there is
    /// no way for an item to vanish here without appearing in one of the two
    /// returned lists — the "no undeclared drops" guarantee is structural,
    /// not a post-hoc count check. Returns the merge-group sizes (for
    /// reporting) and the raw drop reasons (for local classification).
    mutating func applyDeltaConsolidation(_ result: DeltaConsolidationDeltaGenerable) -> (mergeGroupSizes: [Int], dropReasons: [String]) {
        var mergeGroupSizes: [Int] = []
        for group in result.mergeGroups {
            let members = group.ids.compactMap { id in items.first(where: { $0.id == id && !$0.resolved }) }
            guard !members.isEmpty else { continue }
            let category = members[0].category
            for member in members { markResolved(member.id) }
            switch category {
            case .decision: addDecision(group.mergedText)
            case .action:
                addAction(ActionItem(
                    text: group.mergedText,
                    owner: Normalize.field(group.owner, extraPlaceholders: Normalize.genericOwnerPlaceholders),
                    due: Normalize.field(group.due)
                ))
            case .question: addQuestion(group.mergedText)
            }
            mergeGroupSizes.append(members.count)
        }

        var dropReasons: [String] = []
        for drop in result.dropIds where markResolved(drop.id) {
            dropReasons.append(drop.reason)
        }

        summaryText = result.rewrittenSummary
        return (mergeGroupSizes, dropReasons)
    }

    /// Numbered plain-text rendering of the ACTIVE state, fed to the model so
    /// `resolvedItemIds`/`corrections` in its next delta response can
    /// reference real ids. Resolved items are omitted — the model should
    /// never re-resolve or correct something already resolved.
    func structuredTextWithIds() -> String {
        let decisionsActive = activeItems.filter { $0.category == .decision }
        let actionsActive = activeItems.filter { $0.category == .action }
        let questionsActive = activeItems.filter { $0.category == .question }

        var lines: [String] = []
        lines.append("SUMMARY SO FAR:")
        lines.append(summaryText.isEmpty ? "(none yet)" : summaryText)
        lines.append("")
        lines.append("DECISIONS (numbered):")
        lines.append(decisionsActive.isEmpty ? "(none)" : decisionsActive.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n"))
        lines.append("")
        lines.append("ACTION ITEMS (numbered):")
        if actionsActive.isEmpty {
            lines.append("(none)")
        } else {
            lines.append(actionsActive.map { item -> String in
                var line = "[\(item.id)] \(item.text)"
                if let owner = item.owner { line += " | owner: \(owner)" }
                if let due = item.due { line += " | due: \(due)" }
                return line
            }.joined(separator: "\n"))
        }
        lines.append("")
        lines.append("OPEN QUESTIONS (numbered):")
        lines.append(questionsActive.isEmpty ? "(none)" : questionsActive.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }
}

extension RollingSummary {
    /// Cleaned copy: placeholder/empty entries dropped, owner/due placeholder
    /// values mapped to nil, edge punctuation trimmed. Applied to every FM
    /// result before it's used/printed/carried forward, matching what
    /// `DebriefSummary.normalized()` does for the real app.
    func normalized() -> RollingSummary {
        let cleanedItems = actionItems
            .map { item in
                ActionItem(
                    text: item.text,
                    owner: Normalize.field(item.owner, extraPlaceholders: Normalize.genericOwnerPlaceholders),
                    due: Normalize.field(item.due)
                )
            }
            .filter { !Normalize.isEmptyOrPlaceholder($0.text) }
        let cleanedDecisions = decisions.filter { !Normalize.isEmptyOrPlaceholder($0) }
        let cleanedQuestions = openQuestions.filter { !Normalize.isEmptyOrPlaceholder($0) }
        return RollingSummary(summary: summary, decisions: cleanedDecisions, actionItems: cleanedItems, openQuestions: cleanedQuestions)
    }

    /// Plain-text rendering of this state, fed back into the NEXT rolling-update
    /// or consolidation call as "the summary so far" — deliberately using
    /// fixed English scaffolding labels (SUMMARY/DECISIONS/...) regardless of
    /// transcript language, since these are structural markers for the model's
    /// context, not user-facing output; the actual field CONTENT stays in
    /// whatever language the model wrote it in.
    func structuredText() -> String {
        var lines: [String] = []
        lines.append("SUMMARY:")
        lines.append(summary.isEmpty ? "(none yet)" : summary)
        lines.append("")
        lines.append("DECISIONS:")
        lines.append(decisions.isEmpty ? "(none)" : decisions.map { "- \($0)" }.joined(separator: "\n"))
        lines.append("")
        lines.append("ACTION ITEMS:")
        if actionItems.isEmpty {
            lines.append("(none)")
        } else {
            lines.append(actionItems.map { item -> String in
                var line = "- \(item.text)"
                if let owner = item.owner { line += " | owner: \(owner)" }
                if let due = item.due { line += " | due: \(due)" }
                return line
            }.joined(separator: "\n"))
        }
        lines.append("")
        lines.append("OPEN QUESTIONS:")
        lines.append(openQuestions.isEmpty ? "(none)" : openQuestions.map { "- \($0)" }.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Foundation Models schema

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct MeetingSummaryGenerable {
    @Guide(description: "A 2 to 5 sentence FIRST-PERSON summary, never third-person (\"the speaker\"), written in the same language as the text you were given. If the speaker names themselves as an aside, that name IS the speaker, not a separate third person. Something already true or already done before this content is context, not a decision or action.")
    var summary: String

    @Guide(description: "ONLY things explicitly agreed or concluded, using committal language actually spoken — a conditional or either/or still being weighed is NOT a decision, it belongs in openQuestions instead. A future task like scheduling or booking something is an actionItem, not a decision, even if phrased as an agreement to do it later. Empty array if none. Never repeat an item that belongs in actionItems.")
    var decisions: [String]

    @Guide(description: "Things someone still has to do — scheduling, sending, booking, following up. An event already arranged as a settled fact is NOT an action item. Empty array if none mentioned. Never repeat an item that belongs in decisions, even worded differently there.")
    var actionItems: [ActionItemGenerable]

    @Guide(description: "Unresolved points or either/or options actually voiced, including a conditional still being weighed. Never invent a question that was not raised. Empty array if none.")
    var openQuestions: [String]

    @available(macOS 26.0, *)
    @Generable
    struct ActionItemGenerable {
        @Guide(description: "The task to do, written in the same language as the text you were given")
        var text: String

        @Guide(description: "The GRAMMATICAL SUBJECT of this task as spoken: a first-person self-reference means the speaker (use their own stated name if given, else the language's own first-person word); a third person named as subject means that person. Never assign the speaker's own task to someone else. Null when not spoken; never a generic group like \"Team\" or \"Everyone\", and never a placeholder such as \"Not specified\", \"TBD\", \"N/A\" or \"Unknown\"")
        var owner: String?

        @Guide(description: "The deadline for THIS task, copied VERBATIM exactly as spoken; NEVER convert to a calendar date, NEVER add or invent a year, NEVER add a weekday unless the speaker said that weekday themselves; do not reuse an unrelated date mentioned elsewhere; null when not spoken; never a placeholder such as \"Not specified\", \"TBD\", \"N/A\" or \"Unknown\"")
        var due: String?
    }

    func toRollingSummary() -> RollingSummary {
        RollingSummary(
            summary: summary,
            decisions: decisions,
            actionItems: actionItems.map { ActionItem(text: $0.text, owner: $0.owner, due: $0.due) },
            openQuestions: openQuestions
        )
    }
}

// --- Ablation A schemas: delta mode never re-emits the whole state, only
// what changed, so `Accumulator` (see "Delta-mode accumulator" above) can
// apply it deterministically in Swift instead of trusting a full
// regeneration each iteration. Reuses `MeetingSummaryGenerable.ActionItemGenerable`
// for the action-item shape rather than duplicating it. ---

@available(macOS 26.0, *)
@Generable
struct DeltaGenerable {
    @Guide(description: "An updated 2 to 5 sentence FIRST-PERSON summary of the WHOLE meeting so far, incorporating this new chunk. Unlike the fields below, this one is fully regenerated each time, not a delta.")
    var updatedSummary: String

    @Guide(description: "Decisions that are genuinely NEW in this chunk — never restate a decision already in the numbered list you were given, even worded differently. Empty array if none.")
    var newDecisions: [String]

    @Guide(description: "Action items that are genuinely NEW in this chunk — never restate one already in the numbered list. Empty array if none.")
    var newActionItems: [MeetingSummaryGenerable.ActionItemGenerable]

    @Guide(description: "Open questions that are genuinely NEW in this chunk — never restate one already in the numbered list. Empty array if none.")
    var newOpenQuestions: [String]

    @Guide(description: "The numeric ids, from the numbered list you were given, of existing items this chunk explicitly resolves, completes, answers, or makes obsolete. Do NOT include an id just because this chunk fails to repeat it — only when the chunk actually says that item is done, answered, or no longer applies. Empty array if none.")
    var resolvedItemIds: [Int]

    @Guide(description: "Corrections to an existing numbered item's wording, only when this chunk shows that item's existing wording was wrong or incomplete. Most items need no correction — leave this empty unless a correction is clearly warranted.")
    var corrections: [CorrectionGenerable]

    @available(macOS 26.0, *)
    @Generable
    struct CorrectionGenerable {
        @Guide(description: "The id, from the numbered list you were given, of the existing item being corrected")
        var id: Int

        @Guide(description: "The corrected replacement text for that item, in the same language as the rest of your output")
        var text: String
    }
}

@available(macOS 26.0, *)
@Generable
struct DeltaConsolidationGenerable {
    @Guide(description: "Final 2 to 5 sentence FIRST-PERSON summary of the whole meeting.")
    var finalSummary: String

    @Guide(description: "Final cleaned decisions, after merging any near-duplicates found in the numbered list you were given. Empty array if none.")
    var decisions: [String]

    @Guide(description: "Final cleaned action items, after merging any near-duplicates. Empty array if none.")
    var actionItems: [MeetingSummaryGenerable.ActionItemGenerable]

    @Guide(description: "Final cleaned open questions, after merging any near-duplicates. Empty array if none.")
    var openQuestions: [String]

    @Guide(description: "Every pair of ids, from the numbered list you were given, that you merged together into ONE final item. Only list a pair if you genuinely combined those two into one — merging two items is different from simply dropping one, and a drop must not be recorded here.")
    var mergedPairs: [MergedPairGenerable]

    @available(macOS 26.0, *)
    @Generable
    struct MergedPairGenerable {
        @Guide(description: "First id, from the numbered list you were given, that was merged")
        var idA: Int

        @Guide(description: "Second id, from the numbered list you were given, that was merged with idA")
        var idB: Int
    }
}

// --- Ablation "delta-consolidate": the FINAL consolidation is also a delta,
// not a full re-emission — so `Accumulator.applyDeltaConsolidation` can apply
// it with a structural "no undeclared drops" guarantee, unlike
// `DeltaConsolidationGenerable` above (free-form output, checked only after
// the fact by comparing counts). ---

@available(macOS 26.0, *)
@Generable
struct DeltaConsolidationDeltaGenerable {
    @Guide(description: "A fresh 2 to 5 sentence FIRST-PERSON summary of the whole meeting.")
    var rewrittenSummary: String

    @Guide(description: "Groups of ids, from the numbered list you were given, that are the SAME real-world decision/action/question said more than once — each group becomes ONE final item. Only group ids that are genuinely duplicates of each other; never invent an id that wasn't in the numbered list. Empty array if there are no duplicates.")
    var mergeGroups: [MergeGroupGenerable]

    @Guide(description: "Ids, from the numbered list you were given, to drop entirely because they have zero real content left (a stray fragment) — each with a short reason. Do not include an id here if it already appears in mergeGroups. Empty array if none should be dropped.")
    var dropIds: [DropGenerable]

    @available(macOS 26.0, *)
    @Generable
    struct MergeGroupGenerable {
        @Guide(description: "The ids, from the numbered list you were given, that are all the same item and should become one")
        var ids: [Int]
        @Guide(description: "The single merged text for this item, in the same language as the rest of your output")
        var mergedText: String
        @Guide(description: "Owner for this merged item, only if it's an action item and an owner is known; null otherwise")
        var owner: String?
        @Guide(description: "Due date for this merged item, only if it's an action item and one is known, copied verbatim; null otherwise")
        var due: String?
    }

    @available(macOS 26.0, *)
    @Generable
    struct DropGenerable {
        @Guide(description: "The id, from the numbered list you were given, of the item to drop")
        var id: Int
        @Guide(description: "A short reason this item should be dropped")
        var reason: String
    }
}
#endif

// MARK: - Prompt builder

/// System/user prompts for all five FM call sites this probe exercises. Every
/// prompt shares one `coreRules` block, derived directly from
/// `DebriefPromptBuilder.systemPrompt`'s `Rules:` section
/// (dikta-macos/Dikta/Services/Debrief/DebriefSummarizer.swift:144-175) —
/// same rules (grammatical-subject owner, verbatim due, decision/action
/// mutual exclusivity, no invented facts, null not placeholder), condensed
/// and made mode-agnostic (the app's version says "IN the meeting"; this
/// probe's callers may be handed a chunk, a rolling summary-so-far, or a set
/// of chunk summaries, so the wording says "in what you were given" instead).
/// Each mode then layers its own framing on top — this framing is the actual
/// subject of the probe (does rolling-update framing hold up over many
/// iterations better/worse than map-reduce or a single pass) and is written
/// fresh here rather than copied from anywhere, per the task.
enum PromptBuilder {
    private static func coreRules(language: String) -> String {
        let due = language == "sv" ? "\"om två veckor\", \"imorgon\"" : "\"one week from now\", \"tomorrow\""
        let committal = language == "sv" ? "\"vi bestämde\", \"vi kör på\"" : "\"we decided\", \"we'll go with\""
        return """
        Rules:
        - Write every field in the SAME language as the text you are given.
        - decisions: ONLY things explicitly agreed or concluded, using committal language actually spoken (e.g. \(committal)). A conditional or either/or still being weighed is an openQuestion, not a decision. A future task (scheduling, booking, sending, following up) is always an actionItem, never a decision, even phrased as an agreement to do it later.
        - actionItems: owner is the GRAMMATICAL SUBJECT of the task as spoken — a first-person self-reference means the speaker; a third person named as the subject means that person. Never assign the speaker's own task to someone else. due is copied VERBATIM as spoken (e.g. \(due)) — NEVER converted to a calendar date, NEVER given a year or weekday that wasn't said. owner is only a person actually named, never a generic group like "Team"/"Everyone"; owner and due are null when not spoken.
        - Every item is EITHER a decision OR an actionItem, never both, never restated in each place.
        - openQuestions: unresolved points or either/or options actually voiced. Never invent one.
        - Never invent facts, owners, dates, or years absent from what you were given. owner/due must be null, never a placeholder such as "Not specified", "TBD", "N/A", "None" or "Unknown".
        - Spell every name/company only ONE way, even if it appears spelled more than one way in what you were given.
        """
    }

    // --- Single pass: one call over the whole transcript, the naive baseline. ---

    static func singlePassSystem(language: String) -> String {
        """
        You are an assistant that summarizes a spoken post-meeting debrief. The transcript is the speaker's own first-person account of a meeting they just left. Punctuation may be missing or inconsistent (speech-to-text).

        \(coreRules(language: language))
        """
    }

    static func singlePassUser(transcript: String, language: String) -> String {
        "Transcript (language: \(language)):\n\n\(transcript)"
    }

    // --- Map-reduce chunk pass: each chunk summarized in isolation, no continuity. ---

    static func mapReduceChunkSystem(language: String) -> String {
        """
        You are summarizing ONE SEGMENT of a longer spoken meeting transcript, not the whole meeting. The segment boundary does not align with topic or sentence structure — this segment may start or end mid-thought. Extract only what is actually said IN THIS SEGMENT; do not guess at what came before or after it.

        \(coreRules(language: language))
        """
    }

    static func mapReduceChunkUser(chunk: String, language: String, index: Int, total: Int) -> String {
        "Segment \(index + 1) of \(total) of a spoken meeting (language: \(language)):\n\n\(chunk)"
    }

    // --- Map-reduce merge pass: one call over all per-chunk summaries. ---

    static func mapReduceMergeSystem(language: String) -> String {
        """
        You are given several partial summaries, each covering one segment of ONE spoken meeting, in chronological order. Merge them into a single final summary: combine them into one coherent account of the whole meeting; when two segment summaries describe the same decision/action/question in different words, keep it once, not twice; keep every real owner and due date already present in the segment summaries; drop an item that has no real content left (an isolated fragment). Do not invent anything beyond what the segment summaries already state.

        \(coreRules(language: language))
        """
    }

    static func mapReduceMergeUser(chunkSummaries: [RollingSummary], language: String) -> String {
        let sections = chunkSummaries.enumerated().map { index, summary in
            "--- Segment \(index + 1) summary ---\n\(summary.structuredText())"
        }
        return "Segment summaries of one spoken meeting (language: \(language)), in order:\n\n\(sections.joined(separator: "\n\n"))"
    }

    // --- Rolling update: summary-so-far + next chunk -> updated summary. ---

    static func rollingUpdateSystem(language: String) -> String {
        """
        You maintain a ROLLING summary of an ONGOING spoken meeting that is still being transcribed live, chunk by chunk. You are given the summary of everything captured so far (it may say "(none yet)" if this is the first chunk) and the NEXT chunk of new transcript text that continues directly after it.

        Update the summary to include the new chunk:
        - Keep every decision, action item, and open question already in the summary so far, UNLESS this new chunk explicitly resolves or contradicts one — if a chunk resolves an open question, move it to decisions or actionItems as appropriate instead of leaving it as a question; if a chunk contradicts something already captured, update it to match the new chunk rather than keeping the stale version.
        - Add any new decision, action item, or open question actually raised in this chunk.
        - Do NOT restate an item already captured in the summary so far as if it were new — carry it forward unchanged instead of duplicating it in different words.
        - Do NOT drop an already-captured item just because this chunk doesn't mention it again.
        - Base every fact ONLY on the summary so far and this new chunk — never on anything else.

        \(coreRules(language: language))
        """
    }

    static func rollingUpdateUser(previous: RollingSummary, chunk: String, language: String, chunkIndex: Int, totalChunks: Int) -> String {
        """
        Summary of the meeting so far:

        \(previous.structuredText())

        Next chunk (\(chunkIndex + 1) of \(totalChunks)) of the transcript (language: \(language)):

        \(chunk)
        """
    }

    // --- Consolidation: final rolling summary -> cleaned final summary. ---

    static func consolidationSystem(language: String) -> String {
        """
        You are given the final rolling summary of a now-COMPLETE spoken meeting, built up incrementally chunk by chunk over the course of the meeting. Produce a clean, FINAL version of it:
        - Merge and deduplicate any decision, action item, or open question that appears more than once, or that is a near-duplicate paraphrase of another item, into a single entry.
        - Keep every real owner and due date that is already present.
        - Drop any item that has no clear support left — a stray fragment, or something too vague to be a real, actionable item.
        - Do not invent anything new; only clean up what is already there.

        \(coreRules(language: language))
        """
    }

    static func consolidationUser(final: RollingSummary, language: String) -> String {
        "Rolling summary to consolidate (language: \(language)):\n\n\(final.structuredText())"
    }

    // --- Ablation B: prior state in the SESSION INSTRUCTIONS instead of the
    // user turn. Same rollingUpdateSystem rules, just relocated; the user
    // turn becomes the new chunk only. Isolates whether position (system vs.
    // user) affects how reliably the model carries state forward. ---

    static func rollingUpdatePriorInInstructionsSystem(language: String, previous: RollingSummary) -> String {
        """
        \(rollingUpdateSystem(language: language))

        Summary of the meeting so far:

        \(previous.structuredText())
        """
    }

    static func rollingUpdatePriorInInstructionsUser(chunk: String, language: String, chunkIndex: Int, totalChunks: Int) -> String {
        "Next chunk (\(chunkIndex + 1) of \(totalChunks)) of the transcript (language: \(language)):\n\n\(chunk)"
    }

    // --- Ablation A: delta mode. The model never re-emits the whole state —
    // see DeltaGenerable and Accumulator above for why. ---

    static func deltaSystem(language: String) -> String {
        """
        You maintain the state of an ONGOING spoken meeting as a NUMBERED list of items (decisions / action items / open questions), built up chunk by chunk. You are given the current numbered state (it may say "(none)" for a list if nothing is in it yet) and the NEXT chunk of new transcript text that continues directly after it.

        Unlike a normal summary update, you do NOT re-write the whole state. You output ONLY what changed:
        - updatedSummary: a fresh short summary of the whole meeting so far — this one field is fully regenerated each time.
        - newDecisions / newActionItems / newOpenQuestions: ONLY items genuinely NEW in this chunk — never restate an item already in the numbered list, even worded differently.
        - resolvedItemIds: ids of existing items this chunk explicitly resolves, completes, answers, or makes obsolete. Never include an id just because this chunk doesn't repeat it.
        - corrections: only when this chunk shows an existing item's wording was wrong or incomplete.

        \(coreRules(language: language))
        """
    }

    static func deltaUser(accumulator: Accumulator, chunk: String, language: String, chunkIndex: Int, totalChunks: Int) -> String {
        """
        Current state of the meeting so far:

        \(accumulator.structuredTextWithIds())

        Next chunk (\(chunkIndex + 1) of \(totalChunks)) of the transcript (language: \(language)):

        \(chunk)
        """
    }

    static func deltaConsolidationSystem(language: String) -> String {
        """
        You are given the FINAL accumulated state of a now-COMPLETE spoken meeting, as a numbered list of items built up incrementally, chunk by chunk. Produce a clean final version:
        - Merge a near-duplicate item (the same real-world decision/action/question stated more than once) into a single entry — for EVERY such merge, list the ids of the items you combined in mergedPairs. Do not merge two items that are not genuinely the same thing just to shorten the list.
        - Keep every real owner and due date already present.
        - Only drop an item with zero real content left (a stray fragment); do this sparingly — most items should either survive unchanged or be recorded as a merge.
        - Do not invent anything new — only clean up what is already there.

        \(coreRules(language: language))
        """
    }

    static func deltaConsolidationUser(accumulator: Accumulator, language: String) -> String {
        "Final accumulated state to consolidate (language: \(language)):\n\n\(accumulator.structuredTextWithIds())"
    }

    // --- Ablation "delta-consolidate": same input (accumulator.structuredTextWithIds(),
    // via deltaConsolidationUser above) as deltaConsolidationSystem, but the
    // model outputs a DELTA over the numbered state instead of a full
    // re-emission — see DeltaConsolidationDeltaGenerable. ---

    static func deltaConsolidateAsDeltaSystem(language: String) -> String {
        """
        You are given the FINAL accumulated state of a now-COMPLETE spoken meeting, as a numbered list of items built up incrementally, chunk by chunk. Unlike a normal consolidation, you do NOT rewrite the whole list. You output ONLY:
        - rewrittenSummary: a fresh short summary of the whole meeting.
        - mergeGroups: groups of ids that are the SAME real-world decision/action/question, each becoming one final item.
        - dropIds: ids with zero real content left (a stray fragment), each with a short reason.

        Every id you were given that is in NEITHER list is kept exactly as it is. Be conservative: only merge ids that are genuinely the same thing, and only drop an id that is genuinely empty of content — never drop or merge an id just to shorten the list, and never put the same id in both mergeGroups and dropIds.

        \(coreRules(language: language))
        """
    }
}

// MARK: - Foundation Models calls

#if canImport(FoundationModels)
@available(macOS 26.0, *)
func callFM(system: String, user: String) async throws -> RollingSummary {
    let session = LanguageModelSession(instructions: system)
    // Greedy (argmax) sampling, same label and rationale as the app's
    // FoundationModelsDebriefSummarizer.swift:12-33 — deterministic output so
    // a run of this probe is representative, not a lucky/unlucky sample.
    let options = GenerationOptions(sampling: .greedy)
    let response = try await session.respond(to: user, generating: MeetingSummaryGenerable.self, options: options)
    return response.content.toRollingSummary().normalized()
}

@available(macOS 26.0, *)
func singlePass(transcript: String, language: String) async throws -> RollingSummary {
    try await callFM(system: PromptBuilder.singlePassSystem(language: language), user: PromptBuilder.singlePassUser(transcript: transcript, language: language))
}

@available(macOS 26.0, *)
func mapReduceChunkPass(chunk: String, language: String, index: Int, total: Int) async throws -> RollingSummary {
    try await callFM(
        system: PromptBuilder.mapReduceChunkSystem(language: language),
        user: PromptBuilder.mapReduceChunkUser(chunk: chunk, language: language, index: index, total: total)
    )
}

@available(macOS 26.0, *)
func mapReduceMerge(chunkSummaries: [RollingSummary], language: String) async throws -> RollingSummary {
    try await callFM(
        system: PromptBuilder.mapReduceMergeSystem(language: language),
        user: PromptBuilder.mapReduceMergeUser(chunkSummaries: chunkSummaries, language: language)
    )
}

@available(macOS 26.0, *)
func rollingUpdate(previous: RollingSummary, chunk: String, language: String, chunkIndex: Int, totalChunks: Int) async throws -> RollingSummary {
    try await callFM(
        system: PromptBuilder.rollingUpdateSystem(language: language),
        user: PromptBuilder.rollingUpdateUser(previous: previous, chunk: chunk, language: language, chunkIndex: chunkIndex, totalChunks: totalChunks)
    )
}

@available(macOS 26.0, *)
func consolidate(final: RollingSummary, language: String) async throws -> RollingSummary {
    try await callFM(system: PromptBuilder.consolidationSystem(language: language), user: PromptBuilder.consolidationUser(final: final, language: language))
}

// --- Ablation B ---

@available(macOS 26.0, *)
func rollingUpdatePriorInInstructions(previous: RollingSummary, chunk: String, language: String, chunkIndex: Int, totalChunks: Int) async throws -> RollingSummary {
    try await callFM(
        system: PromptBuilder.rollingUpdatePriorInInstructionsSystem(language: language, previous: previous),
        user: PromptBuilder.rollingUpdatePriorInInstructionsUser(chunk: chunk, language: language, chunkIndex: chunkIndex, totalChunks: totalChunks)
    )
}

// --- Ablation A ---

/// Unlike `callFM`, does not go through `RollingSummary` — delta mode's
/// response shape is a delta, not a full state, so `Accumulator` applies it
/// directly (see the driver in "Drivers" below).
@available(macOS 26.0, *)
func deltaUpdate(accumulator: Accumulator, chunk: String, language: String, chunkIndex: Int, totalChunks: Int) async throws -> DeltaGenerable {
    let session = LanguageModelSession(instructions: PromptBuilder.deltaSystem(language: language))
    let options = GenerationOptions(sampling: .greedy)
    let user = PromptBuilder.deltaUser(accumulator: accumulator, chunk: chunk, language: language, chunkIndex: chunkIndex, totalChunks: totalChunks)
    let response = try await session.respond(to: user, generating: DeltaGenerable.self, options: options)
    return response.content
}

/// Returns the consolidated `RollingSummary` plus how many merge pairs the
/// model explicitly listed, so the driver can check the "count may not drop
/// by more than what's listed as merged" constraint from the ablation spec.
@available(macOS 26.0, *)
func deltaConsolidate(accumulator: Accumulator, language: String) async throws -> (summary: RollingSummary, mergedPairCount: Int) {
    let session = LanguageModelSession(instructions: PromptBuilder.deltaConsolidationSystem(language: language))
    let options = GenerationOptions(sampling: .greedy)
    let user = PromptBuilder.deltaConsolidationUser(accumulator: accumulator, language: language)
    let response = try await session.respond(to: user, generating: DeltaConsolidationGenerable.self, options: options)
    let content = response.content
    let summary = RollingSummary(
        summary: content.finalSummary,
        decisions: content.decisions,
        actionItems: content.actionItems.map { item in
            ActionItem(
                text: item.text,
                owner: Normalize.field(item.owner, extraPlaceholders: Normalize.genericOwnerPlaceholders),
                due: Normalize.field(item.due)
            )
        },
        openQuestions: content.openQuestions
    ).normalized()
    return (summary, content.mergedPairs.count)
}

// --- Ablation "delta-consolidate" ---

@available(macOS 26.0, *)
func deltaConsolidateAsDelta(accumulator: Accumulator, language: String) async throws -> DeltaConsolidationDeltaGenerable {
    let session = LanguageModelSession(instructions: PromptBuilder.deltaConsolidateAsDeltaSystem(language: language))
    let options = GenerationOptions(sampling: .greedy)
    let user = PromptBuilder.deltaConsolidationUser(accumulator: accumulator, language: language)
    let response = try await session.respond(to: user, generating: DeltaConsolidationDeltaGenerable.self, options: options)
    return response.content
}

/// Buckets a `LanguageModelSession.GenerationError` into the failure classes
/// the task asks this probe to watch for (context overflow, guardrail
/// refusal, parse failure), for a short, greppable label on each error line.
/// The full error is still printed separately via string interpolation for
/// the underlying detail.
@available(macOS 26.0, *)
func classifyError(_ error: Error) -> String {
    if let generationError = error as? LanguageModelSession.GenerationError {
        switch generationError {
        case .exceededContextWindowSize: return "context-overflow"
        case .guardrailViolation: return "guardrail-refusal"
        case .refusal: return "guardrail-refusal"
        case .decodingFailure: return "parse-failure"
        case .assetsUnavailable: return "assets-unavailable"
        case .unsupportedGuide: return "unsupported-guide"
        case .unsupportedLanguageOrLocale: return "unsupported-language"
        case .rateLimited: return "rate-limited"
        case .concurrentRequests: return "concurrent-requests"
        @unknown default: return "unknown-generation-error"
        }
    }
    if error is CancellationError { return "cancelled" }
    return "error(\(type(of: error)))"
}
#endif

// MARK: - Chunking

/// Splits `text` into sentences, breaking after `.`, `!`, or `?` followed by
/// whitespace. Falls back to treating the whole text as one "sentence" if no
/// terminator is found — real dictated transcripts are often sparsely
/// punctuated (see debrief-probe.swift's header), so `splitIntoChunks`' hard
/// word-split fallback is what actually keeps chunk sizes bounded in that case.
func splitIntoSentences(_ text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+"#) else { return [text] }
    let range = NSRange(text.startIndex..., in: text)
    var sentences: [String] = []
    var lastEnd = text.startIndex
    regex.enumerateMatches(in: text, range: range) { match, _, _ in
        guard let match, let matchRange = Range(match.range, in: text) else { return }
        let sentence = text[lastEnd..<matchRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if !sentence.isEmpty { sentences.append(sentence) }
        lastEnd = matchRange.upperBound
    }
    let remainder = text[lastEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
    if !remainder.isEmpty { sentences.append(remainder) }
    return sentences.isEmpty ? [text] : sentences
}

func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).count
}

/// Splits `text` into chunks of roughly `targetWords` words each, breaking
/// only at sentence boundaries so a sentence is never split across two chunks
/// — except when a single "sentence" itself is more than 2x `targetWords`
/// (an unpunctuated dictated run-on), which is then hard-split on word
/// boundaries as a last resort. Mirrors decision 8's ~5 min / ~750 word
/// chunk size and the chunk-boundary rule in
/// tasks/decisions-call-debrief.md ("no words lost or duplicated") in
/// spirit — this probe works on already-final transcript text, not live
/// audio, so there is no silence-boundary detection to reuse here.
func splitIntoChunks(_ text: String, targetWords: Int) -> [String] {
    let sentences = splitIntoSentences(text)
    var chunks: [String] = []
    var current: [String] = []
    var currentWords = 0

    func flush() {
        guard !current.isEmpty else { return }
        chunks.append(current.joined(separator: " "))
        current = []
        currentWords = 0
    }

    for sentence in sentences {
        let sentenceWords = wordCount(sentence)
        if sentenceWords > targetWords * 2 {
            flush()
            let words = sentence.split(separator: " ")
            var i = 0
            while i < words.count {
                let end = min(i + targetWords, words.count)
                chunks.append(words[i..<end].joined(separator: " "))
                i = end
            }
            continue
        }
        if currentWords + sentenceWords > targetWords, !current.isEmpty {
            flush()
        }
        current.append(sentence)
        currentWords += sentenceWords
    }
    flush()
    return chunks
}

// MARK: - Transcript loading + language detection

/// Trivial Swedish-vs-English detector, copied from debrief-probe.swift's
/// `detectLanguage` (bench/probes/debrief-probe.swift:190-206) so both probes
/// classify real session transcripts the same way.
func detectLanguage(_ text: String) -> String {
    let svStopWords: Set<String> = ["och", "att", "är", "det", "jag", "ska"]
    let enStopWords: Set<String> = ["the", "and", "is", "to", "i", "will"]
    let tokens = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    var svCount = 0
    var enCount = 0
    for token in tokens {
        if svStopWords.contains(token) { svCount += 1 }
        if enStopWords.contains(token) { enCount += 1 }
    }
    return svCount > enCount ? "sv" : "en"
}

struct TranscriptFile {
    let id: String // session folder name, e.g. a timestamp
    let words: Int
    let language: String
    let text: String
}

/// Loads one `TranscriptFile` per `<dir>/*/transcript.txt`, sorted by folder
/// name (timestamps sort chronologically). Skips a session folder with no
/// transcript or an empty one. Mirrors debrief-probe.swift's
/// `loadSessionSamples` (bench/probes/debrief-probe.swift:212-237), extended
/// with a word count since this probe needs it for the chunking/stand-in
/// decision, not just for routing to the right prompt language.
func loadTranscriptFiles(from dir: String) -> [TranscriptFile] {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { return [] }
    var result: [TranscriptFile] = []
    for entry in entries.sorted() {
        let sessionDir = (dir as NSString).appendingPathComponent(entry)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionDir, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
        let transcriptPath = (sessionDir as NSString).appendingPathComponent("transcript.txt")
        guard let rawText = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else { continue }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        result.append(TranscriptFile(id: entry, words: wordCount(trimmed), language: detectLanguage(trimmed), text: trimmed))
    }
    return result
}

// MARK: - Metrics

/// Normalized decision/actionItem-text/openQuestion keys for one summary
/// state, tagged by category so a decision and an action item that happen to
/// normalize to the same key are never counted as "the same item" across
/// categories — only within one.
struct ItemKeySet {
    var decisionKeys: Set<String>
    var actionKeys: Set<String>
    var questionKeys: Set<String>

    static func from(_ summary: RollingSummary) -> ItemKeySet {
        ItemKeySet(
            decisionKeys: Set(summary.decisions.map(Normalize.dedupeKey)),
            actionKeys: Set(summary.actionItems.map { Normalize.dedupeKey($0.text) }),
            questionKeys: Set(summary.openQuestions.map(Normalize.dedupeKey))
        )
    }

    static let empty = ItemKeySet(decisionKeys: [], actionKeys: [], questionKeys: [])

    var totalCount: Int { decisionKeys.count + actionKeys.count + questionKeys.count }

    /// Count of items in `self` whose normalized key also appears in `previous`
    /// (same category) — i.e. items carried forward from the previous iteration.
    func carriedCount(from previous: ItemKeySet) -> Int {
        decisionKeys.intersection(previous.decisionKeys).count
            + actionKeys.intersection(previous.actionKeys).count
            + questionKeys.intersection(previous.questionKeys).count
    }

    /// Count of items in `previous` whose normalized key does NOT appear in
    /// `self` (same category) — i.e. items dropped since the previous iteration.
    func droppedCount(from previous: ItemKeySet) -> Int {
        previous.decisionKeys.subtracting(decisionKeys).count
            + previous.actionKeys.subtracting(actionKeys).count
            + previous.questionKeys.subtracting(questionKeys).count
    }
}

/// Count of action items with a non-nil `due` (post-`normalized()`, so a
/// placeholder like "Not specified" has already been mapped to nil).
func withDueCount(_ summary: RollingSummary) -> Int {
    summary.actionItems.filter { $0.due != nil }.count
}

/// Count of duplicate entries WITHIN one summary state — items in the same
/// category (decisions / actionItem texts / openQuestions) whose normalized
/// key collides with another item in that same category. `keys.count -
/// Set(keys).count` is the number of "extra" occurrences beyond the first.
func duplicateItemCount(_ summary: RollingSummary) -> Int {
    func extraCount(_ items: [String]) -> Int {
        let keys = items.map(Normalize.dedupeKey)
        return keys.count - Set(keys).count
    }
    return extraCount(summary.decisions) + extraCount(summary.actionItems.map(\.text)) + extraCount(summary.openQuestions)
}

private let firstPersonOwners: Set<String> = ["me", "i", "myself", "jag", "mig", "själv"]

/// Whether `word` appears in `text` as a whole word, case-insensitively.
/// Copied from `DebriefActionItem.containsWholeWord`
/// (dikta-macos/Dikta/Models/DebriefSummary.swift:114-121).
func containsWholeWord(_ word: String, in text: String) -> Bool {
    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
        return text.localizedCaseInsensitiveContains(word)
    }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

/// Count of action items whose `owner` is set, is not a first-person
/// self-reference, and does not appear as a whole word anywhere in
/// `transcript` — i.e. a name the model wrote that the speaker never said.
/// Broader than `DebriefActionItem.validated(against:)`'s check (that one is
/// also restricted to a capitalized-single-word shape); this probe's task is
/// just "owner is not a name that appears in the transcript", counts only.
func ownerNotInTranscriptCount(_ summary: RollingSummary, transcript: String) -> Int {
    summary.actionItems.filter { item in
        guard let owner = item.owner, !firstPersonOwners.contains(owner.lowercased()) else { return false }
        return !containsWholeWord(owner, in: transcript)
    }.count
}

private let dateVocabulary: Set<String> = [
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    "january", "february", "march", "april", "may", "june", "july", "august",
    "september", "october", "november", "december",
    "måndag", "tisdag", "onsdag", "torsdag", "fredag", "lördag", "söndag",
    "januari", "februari", "mars", "maj", "juni", "juli", "augusti",
    "oktober"
]

/// Tokens inside `due` that look date-shaped: contain a digit, or match a
/// weekday/month name (en+sv). A relative phrase like "next week"/"imorgon"
/// has none of these and is intentionally left unjudged — this probe can only
/// check a date-shaped token against the transcript, not whether a vague
/// relative phrase is itself plausible.
func dateShapedTokens(_ due: String) -> [String] {
    due
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
        .filter { $0.contains(where: { $0.isNumber }) || dateVocabulary.contains($0.lowercased()) }
}

/// Count of action items with a `due` containing at least one date-shaped
/// token (digit, weekday, or month name) that does not appear, as a whole
/// word, anywhere in `transcript` — an invented date/weekday/day-number.
func inventedDueCount(_ summary: RollingSummary, transcript: String) -> Int {
    summary.actionItems.filter { item in
        guard let due = item.due else { return false }
        let tokens = dateShapedTokens(due)
        guard !tokens.isEmpty else { return false }
        return tokens.contains { !containsWholeWord($0, in: transcript) }
    }.count
}

func totalItemCount(_ summary: RollingSummary) -> Int {
    summary.decisions.count + summary.actionItems.count + summary.openQuestions.count
}

/// Same duplicate check as `duplicateItemCount(_:RollingSummary)`, but
/// against an `Accumulator`'s currently-active items directly (used to report
/// "duplicates before/after" the delta-consolidate ablation's consolidation
/// step, without needing to round-trip through `RollingSummary` first).
func duplicateItemCountAmongActive(_ accumulator: Accumulator) -> Int {
    func extraCount(_ items: [String]) -> Int {
        let keys = items.map(Normalize.dedupeKey)
        return keys.count - Set(keys).count
    }
    let active = accumulator.activeItems
    return extraCount(active.filter { $0.category == .decision }.map(\.text))
        + extraCount(active.filter { $0.category == .action }.map(\.text))
        + extraCount(active.filter { $0.category == .question }.map(\.text))
}

/// Best-effort local classification of a model-written drop `reason` string
/// into one of four buckets, by keyword. Never printed verbatim in any
/// report — only the resulting bucket counts are, per this probe's
/// data-handling rule (see file header).
func classifyDropReason(_ reason: String) -> String {
    let lowered = reason.lowercased()
    if lowered.contains("duplicate") || lowered.contains("dupe") || lowered.contains("same as") || lowered.contains("already") {
        return "duplicate"
    }
    if lowered.contains("resolved") || lowered.contains("answered") || lowered.contains("done") || lowered.contains("completed") || lowered.contains("no longer") || lowered.contains("obsolete") {
        return "resolved"
    }
    if lowered.contains("not an action") || lowered.contains("not a decision") || lowered.contains("not a question") || lowered.contains("not an item") || lowered.contains("not real") || lowered.contains("fragment") || lowered.contains("no content") || lowered.contains("vague") || lowered.contains("empty") {
        return "not an item"
    }
    return "other"
}

// MARK: - Output helpers

func printFlush(_ s: String) {
    print(s)
    fflush(stdout)
}

func jsonString(_ summary: RollingSummary) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(summary), let str = String(data: data, encoding: .utf8) else {
        return "<failed to encode RollingSummary as JSON>"
    }
    return str
}

// MARK: - Drivers

#if canImport(FoundationModels)
/// Single-pass baseline: one FM call over the entire corpus text. Records
/// word count and, on failure, which `GenerationError` case fired (context
/// overflow being the one this whole probe exists to work around, per
/// decision 8: "Foundation Models ~4k ctx cannot take a 1h transcript").
@available(macOS 26.0, *)
func runSinglePass(text: String, language: String) async -> RollingSummary? {
    let words = wordCount(text)
    let start = Date()
    do {
        let result = try await singlePass(transcript: text, language: language)
        let elapsed = Date().timeIntervalSince(start)
        printFlush("SINGLE-PASS lang=\(language) words=\(words) elapsed=\(String(format: "%.2f", elapsed))s decisions=\(result.decisions.count) actions=\(result.actionItems.count) questions=\(result.openQuestions.count) withDue=\(withDueCount(result))")
        printFlush("SINGLE-PASS-JSON lang=\(language)\n\(jsonString(result))")
        return result
    } catch {
        let elapsed = Date().timeIntervalSince(start)
        printFlush("SINGLE-PASS lang=\(language) words=\(words) elapsed=\(String(format: "%.2f", elapsed))s ERROR class=\(classifyError(error)) detail=\(error)")
        return nil
    }
}

/// Rolling mode: summary_0 = empty; summary_i = FM(summary_{i-1}, chunk_i);
/// then one consolidation pass over summary_n. Prints one line per chunk
/// iteration with every metric the task's definition of done asks for
/// (chunk word count, item counts, carried/dropped vs the previous iteration,
/// items with a due date, elapsed seconds, error class) plus the full JSON of
/// each intermediate state so drift is inspectable in the log file (never in
/// the report).
@available(macOS 26.0, *)
func runRollingMode(chunks: [String], language: String) async -> RollingSummary? {
    var current = RollingSummary.empty
    var previousKeys = ItemKeySet.empty
    printFlush("ROLLING lang=\(language) header: chunk chunkWords decisions actions questions carried dropped withDue elapsedSec error")

    for (index, chunk) in chunks.enumerated() {
        let start = Date()
        do {
            let updated = try await rollingUpdate(previous: current, chunk: chunk, language: language, chunkIndex: index, totalChunks: chunks.count)
            let elapsed = Date().timeIntervalSince(start)
            let currentKeys = ItemKeySet.from(updated)
            let carried = currentKeys.carriedCount(from: previousKeys)
            let dropped = currentKeys.droppedCount(from: previousKeys)
            printFlush("ROLLING lang=\(language) chunk=\(index) chunkWords=\(wordCount(chunk)) decisions=\(updated.decisions.count) actions=\(updated.actionItems.count) questions=\(updated.openQuestions.count) carried=\(carried) dropped=\(dropped) withDue=\(withDueCount(updated)) elapsedSec=\(String(format: "%.2f", elapsed)) error=none")
            printFlush("ROLLING-JSON lang=\(language) chunk=\(index)\n\(jsonString(updated))")
            current = updated
            previousKeys = currentKeys
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            printFlush("ROLLING lang=\(language) chunk=\(index) chunkWords=\(wordCount(chunk)) decisions=n/a actions=n/a questions=n/a carried=n/a dropped=n/a withDue=n/a elapsedSec=\(String(format: "%.2f", elapsed)) error=\(classifyError(error)) detail=\(error)")
            // Keep `current`/`previousKeys` unchanged so the next chunk still
            // has a state to build on — one failed chunk shouldn't abort the
            // whole rolling run.
        }
    }

    let consolidationStart = Date()
    do {
        let consolidated = try await consolidate(final: current, language: language)
        let elapsed = Date().timeIntervalSince(consolidationStart)
        printFlush("ROLLING-CONSOLIDATION lang=\(language) elapsedSec=\(String(format: "%.2f", elapsed)) decisions=\(consolidated.decisions.count) actions=\(consolidated.actionItems.count) questions=\(consolidated.openQuestions.count) error=none")
        printFlush("ROLLING-CONSOLIDATION-JSON lang=\(language)\n\(jsonString(consolidated))")
        return consolidated
    } catch {
        let elapsed = Date().timeIntervalSince(consolidationStart)
        printFlush("ROLLING-CONSOLIDATION lang=\(language) elapsedSec=\(String(format: "%.2f", elapsed)) error=\(classifyError(error)) detail=\(error)")
        return current // fall back to the last successful rolling state, unconsolidated
    }
}

/// Ablation B: identical loop to `runRollingMode`, except the prior state is
/// placed in the `LanguageModelSession` instructions (system) rather than the
/// user turn — the user turn is the new chunk only. Isolates whether
/// position affects carry-forward reliability. Log lines use the
/// `ROLLING-PII` prefix ("prior in instructions") to distinguish from the
/// naive `ROLLING` mode above.
@available(macOS 26.0, *)
func runRollingModePriorInInstructions(chunks: [String], language: String) async -> RollingSummary? {
    var current = RollingSummary.empty
    var previousKeys = ItemKeySet.empty
    printFlush("ROLLING-PII lang=\(language) header: chunk chunkWords decisions actions questions carried dropped withDue elapsedSec error")

    for (index, chunk) in chunks.enumerated() {
        let start = Date()
        do {
            let updated = try await rollingUpdatePriorInInstructions(previous: current, chunk: chunk, language: language, chunkIndex: index, totalChunks: chunks.count)
            let elapsed = Date().timeIntervalSince(start)
            let currentKeys = ItemKeySet.from(updated)
            let carried = currentKeys.carriedCount(from: previousKeys)
            let dropped = currentKeys.droppedCount(from: previousKeys)
            printFlush("ROLLING-PII lang=\(language) chunk=\(index) chunkWords=\(wordCount(chunk)) decisions=\(updated.decisions.count) actions=\(updated.actionItems.count) questions=\(updated.openQuestions.count) carried=\(carried) dropped=\(dropped) withDue=\(withDueCount(updated)) elapsedSec=\(String(format: "%.2f", elapsed)) error=none")
            printFlush("ROLLING-PII-JSON lang=\(language) chunk=\(index)\n\(jsonString(updated))")
            current = updated
            previousKeys = currentKeys
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            printFlush("ROLLING-PII lang=\(language) chunk=\(index) chunkWords=\(wordCount(chunk)) decisions=n/a actions=n/a questions=n/a carried=n/a dropped=n/a withDue=n/a elapsedSec=\(String(format: "%.2f", elapsed)) error=\(classifyError(error)) detail=\(error)")
        }
    }

    let consolidationStart = Date()
    do {
        let consolidated = try await consolidate(final: current, language: language)
        let elapsed = Date().timeIntervalSince(consolidationStart)
        printFlush("ROLLING-PII-CONSOLIDATION lang=\(language) elapsedSec=\(String(format: "%.2f", elapsed)) decisions=\(consolidated.decisions.count) actions=\(consolidated.actionItems.count) questions=\(consolidated.openQuestions.count) error=none")
        printFlush("ROLLING-PII-CONSOLIDATION-JSON lang=\(language)\n\(jsonString(consolidated))")
        return consolidated
    } catch {
        let elapsed = Date().timeIntervalSince(consolidationStart)
        printFlush("ROLLING-PII-CONSOLIDATION lang=\(language) elapsedSec=\(String(format: "%.2f", elapsed)) error=\(classifyError(error)) detail=\(error)")
        return current
    }
}

/// Ablation A: delta mode. Each iteration the model returns ONLY new items /
/// resolved ids / corrections (see `DeltaGenerable`), which `Accumulator`
/// applies deterministically — so `activeItems.count` can only decrease by an
/// id the model explicitly resolved, never by silent re-generation loss.
/// `singlePass` (that language's single-pass result, or nil if it failed) is
/// used only for the final "over-eager resolution" check: whether an item
/// delta mode resolved away still appears (by normalized exact match) in
/// single-pass's output — i.e. delta mode called something "done" that a
/// whole-transcript read still considered live. Exact-match is the same
/// methodology `ItemKeySet`/`Normalize.dedupeKey` uses elsewhere in this
/// probe; a paraphrase would not be caught, so this likely undercounts.
@available(macOS 26.0, *)
func runDeltaMode(chunks: [String], language: String, singlePass: RollingSummary?) async -> RollingSummary? {
    var accumulator = Accumulator()
    var resolvedRecords: [(id: Int, category: ItemCategory, text: String)] = []
    printFlush("DELTA lang=\(language) header: chunk chunkWords activeBefore activeAfter added resolved corrections elapsedSec error")

    for (index, chunk) in chunks.enumerated() {
        let start = Date()
        let activeBefore = accumulator.activeItems.count
        do {
            let delta = try await deltaUpdate(accumulator: accumulator, chunk: chunk, language: language, chunkIndex: index, totalChunks: chunks.count)
            let elapsed = Date().timeIntervalSince(start)

            accumulator.summaryText = delta.updatedSummary
            for decision in delta.newDecisions where !Normalize.isEmptyOrPlaceholder(decision) {
                accumulator.addDecision(decision)
            }
            for action in delta.newActionItems where !Normalize.isEmptyOrPlaceholder(action.text) {
                accumulator.addAction(ActionItem(
                    text: action.text,
                    owner: Normalize.field(action.owner, extraPlaceholders: Normalize.genericOwnerPlaceholders),
                    due: Normalize.field(action.due)
                ))
            }
            for question in delta.newOpenQuestions where !Normalize.isEmptyOrPlaceholder(question) {
                accumulator.addQuestion(question)
            }

            var resolvedCount = 0
            for id in delta.resolvedItemIds {
                if let item = accumulator.items.first(where: { $0.id == id && !$0.resolved }) {
                    resolvedRecords.append((id: id, category: item.category, text: item.text))
                    if accumulator.markResolved(id) { resolvedCount += 1 }
                }
            }

            var correctionCount = 0
            for correction in delta.corrections where accumulator.applyCorrection(id: correction.id, text: correction.text) {
                correctionCount += 1
            }

            let activeAfter = accumulator.activeItems.count
            let added = activeAfter - (activeBefore - resolvedCount)
            printFlush("DELTA lang=\(language) chunk=\(index) chunkWords=\(wordCount(chunk)) activeBefore=\(activeBefore) activeAfter=\(activeAfter) added=\(added) resolved=\(resolvedCount) corrections=\(correctionCount) elapsedSec=\(String(format: "%.2f", elapsed)) error=none")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            printFlush("DELTA lang=\(language) chunk=\(index) chunkWords=\(wordCount(chunk)) activeBefore=\(activeBefore) activeAfter=\(activeBefore) added=0 resolved=0 corrections=0 elapsedSec=\(String(format: "%.2f", elapsed)) error=\(classifyError(error)) detail=\(error)")
        }
    }

    let accumulatedActive = accumulator.activeItems.count
    let consolidationStart = Date()
    do {
        let (finalSummary, mergedPairCount) = try await deltaConsolidate(accumulator: accumulator, language: language)
        let elapsed = Date().timeIntervalSince(consolidationStart)
        let expectedMin = max(0, accumulatedActive - mergedPairCount)
        let actual = totalItemCount(finalSummary)
        let violation = actual < expectedMin ? expectedMin - actual : 0
        printFlush("DELTA-CONSOLIDATION lang=\(language) accumulatedActive=\(accumulatedActive) mergedPairs=\(mergedPairCount) expectedMin=\(expectedMin) actualItems=\(actual) violation=\(violation) elapsedSec=\(String(format: "%.2f", elapsed)) error=none")
        printFlush("DELTA-CONSOLIDATION-JSON lang=\(language)\n\(jsonString(finalSummary))")

        if let singlePass {
            let singlePassKeys = ItemKeySet.from(singlePass)
            var overEager = 0
            for record in resolvedRecords {
                let key = Normalize.dedupeKey(record.text)
                switch record.category {
                case .decision: if singlePassKeys.decisionKeys.contains(key) { overEager += 1 }
                case .action: if singlePassKeys.actionKeys.contains(key) { overEager += 1 }
                case .question: if singlePassKeys.questionKeys.contains(key) { overEager += 1 }
                }
            }
            printFlush("DELTA-OVEREAGER lang=\(language) resolvedTotal=\(resolvedRecords.count) overEagerCount=\(overEager)")
        } else {
            printFlush("DELTA-OVEREAGER lang=\(language) resolvedTotal=\(resolvedRecords.count) overEagerCount=n/a (no single-pass result)")
        }

        return finalSummary
    } catch {
        let elapsed = Date().timeIntervalSince(consolidationStart)
        printFlush("DELTA-CONSOLIDATION lang=\(language) accumulatedActive=\(accumulatedActive) mergedPairs=n/a expectedMin=n/a actualItems=n/a violation=n/a elapsedSec=\(String(format: "%.2f", elapsed)) error=\(classifyError(error)) detail=\(error)")
        return accumulator.toRollingSummary() // fall back to the unconsolidated accumulator state
    }
}

/// Ablation "delta-consolidate": identical per-chunk accumulation loop to
/// `runDeltaMode` (duplicated rather than shared, so changes to one mode's
/// log format/behavior can't accidentally affect the other — log lines use
/// the `DELTAC` prefix here), but the FINAL consolidation is also a delta
/// (`DeltaConsolidationDeltaGenerable`, applied via
/// `Accumulator.applyDeltaConsolidation`) instead of a free-form re-emission.
/// By construction every id is either in a merge group, a drop (with a
/// reason), or untouched — there is no way for this step to silently lose an
/// item the way `deltaConsolidate`'s free-form output can.
@available(macOS 26.0, *)
func runDeltaConsolidateMode(chunks: [String], language: String) async -> RollingSummary? {
    var accumulator = Accumulator()
    printFlush("DELTAC lang=\(language) header: chunk chunkWords activeBefore activeAfter added resolved corrections elapsedSec error")

    for (index, chunk) in chunks.enumerated() {
        let start = Date()
        let activeBefore = accumulator.activeItems.count
        do {
            let delta = try await deltaUpdate(accumulator: accumulator, chunk: chunk, language: language, chunkIndex: index, totalChunks: chunks.count)
            let elapsed = Date().timeIntervalSince(start)

            accumulator.summaryText = delta.updatedSummary
            for decision in delta.newDecisions where !Normalize.isEmptyOrPlaceholder(decision) {
                accumulator.addDecision(decision)
            }
            for action in delta.newActionItems where !Normalize.isEmptyOrPlaceholder(action.text) {
                accumulator.addAction(ActionItem(
                    text: action.text,
                    owner: Normalize.field(action.owner, extraPlaceholders: Normalize.genericOwnerPlaceholders),
                    due: Normalize.field(action.due)
                ))
            }
            for question in delta.newOpenQuestions where !Normalize.isEmptyOrPlaceholder(question) {
                accumulator.addQuestion(question)
            }

            var resolvedCount = 0
            for id in delta.resolvedItemIds where accumulator.markResolved(id) { resolvedCount += 1 }

            var correctionCount = 0
            for correction in delta.corrections where accumulator.applyCorrection(id: correction.id, text: correction.text) {
                correctionCount += 1
            }

            let activeAfter = accumulator.activeItems.count
            let added = activeAfter - (activeBefore - resolvedCount)
            printFlush("DELTAC lang=\(language) chunk=\(index) chunkWords=\(wordCount(chunk)) activeBefore=\(activeBefore) activeAfter=\(activeAfter) added=\(added) resolved=\(resolvedCount) corrections=\(correctionCount) elapsedSec=\(String(format: "%.2f", elapsed)) error=none")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            printFlush("DELTAC lang=\(language) chunk=\(index) chunkWords=\(wordCount(chunk)) activeBefore=\(activeBefore) activeAfter=\(activeBefore) added=0 resolved=0 corrections=0 elapsedSec=\(String(format: "%.2f", elapsed)) error=\(classifyError(error)) detail=\(error)")
        }
    }

    let accumulatedBefore = accumulator.activeItems.count
    let duplicatesBefore = duplicateItemCountAmongActive(accumulator)
    // Numbered pre-consolidation state, printed once so a human reading the
    // (gitignored, local-only) log can correlate mergeGroups'/dropIds' ids
    // against what they originally said — never surfaced outside this file.
    printFlush("DELTAC-PRE-CONSOLIDATION-STATE lang=\(language)\n\(accumulator.structuredTextWithIds())")

    let consolidationStart = Date()
    do {
        let result = try await deltaConsolidateAsDelta(accumulator: accumulator, language: language)
        let elapsed = Date().timeIntervalSince(consolidationStart)
        // Raw merge-group id lists, printed once for the same local-only
        // correlation purpose as DELTAC-PRE-CONSOLIDATION-STATE above.
        printFlush("DELTAC-MERGE-GROUPS lang=\(language) groups=\(result.mergeGroups.map(\.ids))")
        let (mergeGroupSizes, dropReasons) = accumulator.applyDeltaConsolidation(result)
        let dropCounts = Dictionary(grouping: dropReasons.map(classifyDropReason), by: { $0 }).mapValues(\.count)

        let finalSummary = accumulator.toRollingSummary()
        let finalItems = accumulator.activeItems.count
        let duplicatesAfter = duplicateItemCountAmongActive(accumulator)

        printFlush("DELTAC-CONSOLIDATION lang=\(language) accumulatedBefore=\(accumulatedBefore) duplicatesBefore=\(duplicatesBefore) mergeGroups=\(mergeGroupSizes.count) mergeGroupSizes=\(mergeGroupSizes) dropsProposed=\(dropReasons.count) dropDuplicate=\(dropCounts["duplicate"] ?? 0) dropNotAnItem=\(dropCounts["not an item"] ?? 0) dropResolved=\(dropCounts["resolved"] ?? 0) dropOther=\(dropCounts["other"] ?? 0) finalItems=\(finalItems) duplicatesAfter=\(duplicatesAfter) elapsedSec=\(String(format: "%.2f", elapsed)) error=none")
        printFlush("DELTAC-CONSOLIDATION-JSON lang=\(language)\n\(jsonString(finalSummary))")
        return finalSummary
    } catch {
        let elapsed = Date().timeIntervalSince(consolidationStart)
        printFlush("DELTAC-CONSOLIDATION lang=\(language) accumulatedBefore=\(accumulatedBefore) duplicatesBefore=\(duplicatesBefore) error=\(classifyError(error)) detail=\(error) elapsedSec=\(String(format: "%.2f", elapsed))")
        return accumulator.toRollingSummary()
    }
}

/// Map-reduce baseline: one independent FM call per chunk (no continuity
/// between chunks), then one merge pass over all chunk summaries.
@available(macOS 26.0, *)
func runMapReduce(chunks: [String], language: String) async -> RollingSummary? {
    var chunkSummaries: [RollingSummary] = []
    printFlush("MAPREDUCE-CHUNK lang=\(language) header: chunk chunkWords decisions actions questions withDue elapsedSec error")

    for (index, chunk) in chunks.enumerated() {
        let start = Date()
        do {
            let result = try await mapReduceChunkPass(chunk: chunk, language: language, index: index, total: chunks.count)
            let elapsed = Date().timeIntervalSince(start)
            printFlush("MAPREDUCE-CHUNK lang=\(language) chunk=\(index) chunkWords=\(wordCount(chunk)) decisions=\(result.decisions.count) actions=\(result.actionItems.count) questions=\(result.openQuestions.count) withDue=\(withDueCount(result)) elapsedSec=\(String(format: "%.2f", elapsed)) error=none")
            printFlush("MAPREDUCE-CHUNK-JSON lang=\(language) chunk=\(index)\n\(jsonString(result))")
            chunkSummaries.append(result)
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            printFlush("MAPREDUCE-CHUNK lang=\(language) chunk=\(index) chunkWords=\(wordCount(chunk)) decisions=n/a actions=n/a questions=n/a withDue=n/a elapsedSec=\(String(format: "%.2f", elapsed)) error=\(classifyError(error)) detail=\(error)")
        }
    }

    guard !chunkSummaries.isEmpty else {
        printFlush("MAPREDUCE-MERGE lang=\(language) SKIPPED — no chunk summaries succeeded")
        return nil
    }

    let mergeStart = Date()
    do {
        let merged = try await mapReduceMerge(chunkSummaries: chunkSummaries, language: language)
        let elapsed = Date().timeIntervalSince(mergeStart)
        printFlush("MAPREDUCE-MERGE lang=\(language) elapsedSec=\(String(format: "%.2f", elapsed)) decisions=\(merged.decisions.count) actions=\(merged.actionItems.count) questions=\(merged.openQuestions.count) error=none")
        printFlush("MAPREDUCE-MERGE-JSON lang=\(language)\n\(jsonString(merged))")
        return merged
    } catch {
        let elapsed = Date().timeIntervalSince(mergeStart)
        printFlush("MAPREDUCE-MERGE lang=\(language) elapsedSec=\(String(format: "%.2f", elapsed)) error=\(classifyError(error)) detail=\(error)")
        return nil
    }
}

/// Final comparison: rolling+consolidation vs map-reduce, counts only —
/// total items, internal duplicates, owners not said in the transcript,
/// invented due dates.
func printComparison(label: String, summary: RollingSummary?, transcript: String) {
    guard let summary else {
        printFlush("COMPARE \(label): n/a (no successful result)")
        return
    }
    printFlush("COMPARE \(label): totalItems=\(totalItemCount(summary)) decisions=\(summary.decisions.count) actions=\(summary.actionItems.count) questions=\(summary.openQuestions.count) duplicateItems=\(duplicateItemCount(summary)) ownerNotInTranscript=\(ownerNotInTranscriptCount(summary, transcript: transcript)) inventedDue=\(inventedDueCount(summary, transcript: transcript)) withDue=\(withDueCount(summary))")
}
#endif

// MARK: - Main

@main
struct RollingSummaryProbe {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)

        guard #available(macOS 26.0, *) else {
            printFlush("macOS < 26.0 — FoundationModels unavailable, aborting probe.")
            return
        }

        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        printFlush("AVAILABILITY: \(model.availability)")
        guard model.availability == .available else {
            printFlush("Foundation Models unavailable (\(model.availability)) — stopping probe here per escalation rule. Not falling back to Ollama or heuristics.")
            return
        }

        let arguments = CommandLine.arguments
        var sessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/Dikta")
        if let flagIndex = arguments.firstIndex(of: "--sessions-dir"), flagIndex + 1 < arguments.count {
            sessionsDir = arguments[flagIndex + 1]
        }
        // Default matches decision 8's ~5 min / ~750 word chunk size. This
        // run overrides it down (see the STAND-IN note printed below) because
        // every available real transcript is far shorter than one chunk —
        // there is no real 1h recording yet (tasks/decisions-call-debrief.md,
        // Spike item 3 notes this explicitly). At --chunk-words 750 both
        // language corpora below would produce exactly ONE chunk each,
        // which cannot exercise "many chunk iterations" at all.
        var chunkWords = 750
        if let flagIndex = arguments.firstIndex(of: "--chunk-words"), flagIndex + 1 < arguments.count,
           let parsed = Int(arguments[flagIndex + 1]), parsed > 0 {
            chunkWords = parsed
        }

        printFlush("SESSIONS-DIR: \(sessionsDir)")
        printFlush("CHUNK-WORDS: \(chunkWords)")

        let files = loadTranscriptFiles(from: sessionsDir)
        guard !files.isEmpty else {
            printFlush("No transcripts found under \(sessionsDir)/*/transcript.txt")
            return
        }
        for file in files {
            printFlush("FILE id=\(file.id) words=\(file.words) lang=\(file.language)")
        }

        for language in ["en", "sv"] {
            let langFiles = files.filter { $0.language == language }.sorted { $0.id < $1.id }
            guard !langFiles.isEmpty else {
                printFlush("### lang=\(language): no files, skipping ###")
                continue
            }

            let longest = langFiles.max(by: { $0.words < $1.words })!
            let isStandIn = longest.words < 3000
            let corpusText: String
            if isStandIn {
                corpusText = langFiles.map(\.text).joined(separator: "\n\n")
                printFlush("### lang=\(language) STAND-IN — built by concatenating \(langFiles.count) real transcripts in timestamp order (\(langFiles.map(\.id).joined(separator: ", "))), total words=\(wordCount(corpusText)). This is NOT a real long meeting — longest single real file is only \(longest.words) words, well under the ~3000-word real-long-transcript threshold. ###")
            } else {
                corpusText = longest.text
                printFlush("### lang=\(language) REAL long transcript: \(longest.id), words=\(longest.words) ###")
            }

            let single = await runSinglePass(text: corpusText, language: language)

            let chunks = splitIntoChunks(corpusText, targetWords: chunkWords)
            printFlush("CHUNKS lang=\(language) count=\(chunks.count) wordsPerChunk=\(chunks.map(wordCount))")

            let rollingFinal = await runRollingMode(chunks: chunks, language: language)
            let priorInInstructionsFinal = await runRollingModePriorInInstructions(chunks: chunks, language: language)
            let deltaFinal = await runDeltaMode(chunks: chunks, language: language, singlePass: single)
            let deltaConsolidateFinal = await runDeltaConsolidateMode(chunks: chunks, language: language)
            let mapReduceFinal = await runMapReduce(chunks: chunks, language: language)

            printFlush("=== COMPARISON lang=\(language) ===")
            printComparison(label: "single-pass lang=\(language)", summary: single, transcript: corpusText)
            printComparison(label: "naive-rolling+consolidation lang=\(language)", summary: rollingFinal, transcript: corpusText)
            printComparison(label: "prior-in-instructions+consolidation lang=\(language)", summary: priorInInstructionsFinal, transcript: corpusText)
            printComparison(label: "delta+consolidation lang=\(language)", summary: deltaFinal, transcript: corpusText)
            printComparison(label: "delta-consolidate lang=\(language)", summary: deltaConsolidateFinal, transcript: corpusText)
            printComparison(label: "map-reduce lang=\(language)", summary: mapReduceFinal, transcript: corpusText)
        }
        #else
        printFlush("FoundationModels not importable on this platform — aborting probe.")
        #endif
    }
}
