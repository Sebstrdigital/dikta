import Foundation

/// A single follow-up task pulled out of a meeting debrief.
///
/// `owner` and `due` are only populated when the speaker actually named them —
/// summarizers must not guess.
struct DebriefActionItem: Codable, Equatable {
    var text: String
    var owner: String?
    var due: String?

    /// Values an LLM writes instead of leaving a field null. Foundation Models
    /// in particular fills `owner`/`due` with "Not specified" or "N/A" rather
    /// than omitting them, which then renders as `(… due Not specified)`.
    /// Lowercased; compared against the trimmed field.
    static let placeholderValues: Set<String> = [
        "not specified",
        "tbd",
        "n/a",
        "na",
        "none",
        "unknown",
        "null",
        "ingen",
        "ingen specificerad",
        "ingen angiven",
        "ej angivet",
        "ej specificerat",
        "okänd",
        "-",
        "–",
        "—"
    ]

    /// Generic collective owners an LLM sometimes invents when no one was
    /// actually named (e.g. "the gaming team" -> "Team"). These are only ever
    /// stripped from `owner`, never from `due`, since a real due date could
    /// coincidentally collide with a word in this list.
    static let genericOwnerPlaceholders: Set<String> = [
        "team",
        "the team",
        "everyone",
        "all",
        "teamet",
        "alla"
    ]

    /// Punctuation trimmed off the ends of an owner/due value on top of
    /// whitespace, so a stray sentence-final character an LLM leaves attached
    /// (e.g. owner "Tomas.") doesn't survive into the rendered text.
    private static let edgePunctuation: Set<Character> = [".", ",", ";", ":"]

    /// Trims whitespace and `edgePunctuation` off both ends of `value`,
    /// repeating until neither remains (handles e.g. "Tomas. " or ", Friday").
    private static func trimmedOfEdgePunctuation(_ value: String) -> String {
        var result = Substring(value)
        func isTrimmable(_ character: Character) -> Bool {
            character.isWhitespace || edgePunctuation.contains(character)
        }
        while let first = result.first, isTrimmable(first) {
            result.removeFirst()
        }
        while let last = result.last, isTrimmable(last) {
            result.removeLast()
        }
        return String(result)
    }

    /// Maps a placeholder, blank, or (for owner only) generic-collective
    /// owner/due to nil, and trims stray edge punctuation off real values.
    static func normalizedField(_ value: String?, extraPlaceholders: Set<String> = []) -> String? {
        guard let value else { return nil }
        let trimmed = trimmedOfEdgePunctuation(value.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.isEmpty { return nil }
        let lowercased = trimmed.lowercased()
        if placeholderValues.contains(lowercased) { return nil }
        if extraPlaceholders.contains(lowercased) { return nil }
        return trimmed
    }

    /// A key for comparing two action-item/decision strings as "the same
    /// item", ignoring case and punctuation. Used to de-duplicate an item an
    /// engine wrote into both `decisions` and `actionItems`.
    static func dedupeKey(_ text: String) -> String {
        let lowercased = text.lowercased()
        let withoutPunctuation = String(lowercased.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) })
        return withoutPunctuation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A copy with placeholder/generic-collective owner/due values replaced
    /// by nil, and edge punctuation trimmed off what remains.
    func normalized() -> DebriefActionItem {
        DebriefActionItem(
            text: text,
            owner: Self.normalizedField(owner, extraPlaceholders: Self.genericOwnerPlaceholders),
            due: Self.normalizedField(due)
        )
    }

    // MARK: - validated(against:)

    /// A bare 4-digit year, anywhere in the string (e.g. the "2024" inside
    /// "senast 2024-09-17"). Also matches the year half of an ISO date, which
    /// is fine — either pattern alone is enough to flag the value.
    private static let fourDigitYearPattern = try! NSRegularExpression(pattern: #"\b\d{4}\b"#)

    /// An ISO `yyyy-MM-dd` date, e.g. "2024-09-17".
    private static let isoDatePattern = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)

    private static func matches(_ pattern: NSRegularExpression, _ value: String) -> Bool {
        pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// Whether `word` appears in `text` as a whole word, case-insensitively.
    private static func containsWholeWord(_ word: String, in text: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text.localizedCaseInsensitiveContains(word)
        }
        return matches(regex, text)
    }

    /// A single word (no internal whitespace) starting with an uppercase
    /// letter — the shape of a plausible person's name, as opposed to "me",
    /// "the team", or a due-date phrase.
    private static func isCapitalizedSingleWord(_ value: String) -> Bool {
        guard let first = value.first, !value.contains(where: { $0.isWhitespace }) else { return false }
        return first.isUppercase
    }

    /// First-person self-references the prompt tells the model to use for
    /// the speaker's own tasks when they didn't state their name (see
    /// DebriefPromptBuilder.systemPrompt's actionItems rule: "me"/"jag").
    /// Foundation Models sometimes capitalizes these ("Me", "Jag") since they
    /// often start the owner field like a proper noun — that capitalization
    /// must not make a legitimate self-reference look like a name-shaped
    /// hallucination. Checked case-insensitively, and exempted from the
    /// name-shape check entirely (regardless of whether the exact word
    /// appears in the transcript), unlike a real name which still has to be
    /// said somewhere.
    private static let firstPersonOwners: Set<String> = [
        "me", "i", "myself",
        "jag", "mig", "själv"
    ]

    /// A copy where a `due` containing a fabricated year/ISO date, or an
    /// `owner` that is a capitalized single word never actually said, is
    /// mapped to nil by checking against the transcript that was actually
    /// spoken. This is a narrow, mechanical safety net, not a full fact
    /// checker: it only catches the clearest fabrication *shapes* (a bare
    /// year or ISO date the model invented; a name-shaped owner string that
    /// never appears anywhere in the transcript). An owner that DOES appear
    /// in the transcript but was attached to the wrong person's task (e.g.
    /// assigning the speaker's own "I need to..." task to someone else named
    /// nearby) looks identical to a correct attribution from here — only the
    /// prompt can fix that (see "Tuning round 2" in
    /// docs/review-2026-09/debrief-probe-2026-09-17.md).
    /// The literal substring of `value` matched by `pattern`'s first match,
    /// or nil. Used to check the transcript for the fabricated YEAR/DATE
    /// TOKEN itself (e.g. "2024" or "2024-09-17"), not the whole `due`
    /// string it was found in — a real due like "senast 2027" would
    /// otherwise never match the transcript even when "2027" was genuinely
    /// said, just phrased differently around it.
    private static func matchedSubstring(of pattern: NSRegularExpression, in value: String) -> String? {
        guard let match = pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else {
            return nil
        }
        return String(value[range])
    }

    func validated(against transcript: String) -> DebriefActionItem {
        var result = self

        if let due {
            let matchedToken = Self.matchedSubstring(of: Self.isoDatePattern, in: due)
                ?? Self.matchedSubstring(of: Self.fourDigitYearPattern, in: due)
            if let matchedToken, !transcript.localizedCaseInsensitiveContains(matchedToken) {
                result.due = nil
            }
        }

        if let owner, !Self.firstPersonOwners.contains(owner.lowercased()),
           Self.isCapitalizedSingleWord(owner), !Self.containsWholeWord(owner, in: transcript) {
            result.owner = nil
        }

        return result
    }
}

/// Structured result of summarizing a spoken post-meeting debrief.
///
/// Produced by a `DebriefSummarizer` and rendered to plain text via
/// `renderPlainText(language:date:)` for pasting/sharing.
struct DebriefSummary: Codable, Equatable {
    var summary: String
    var decisions: [String]
    var actionItems: [DebriefActionItem]
    var openQuestions: [String]

    /// Lowercased words of at least 3 characters, punctuation stripped — used
    /// to compare a decision against an action item as a *paraphrase*, not
    /// just an exact-string match. Words shorter than 3 characters (mostly
    /// function words — "a", "is", "ska", "med") are excluded so overlap
    /// reflects shared content, not shared grammar.
    private static func similarityTokens(_ text: String) -> Set<String> {
        let lowercased = text.lowercased()
        let withoutPunctuation = String(lowercased.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) })
        return Set(withoutPunctuation.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count >= 3 })
    }

    /// Whether `a` and `b` are similar enough to be treated as the same item
    /// paraphrased two ways: Jaccard similarity (intersection over union of
    /// `similarityTokens`) >= 0.75, AND the smaller of the two token sets has
    /// at least 3 tokens. The token-count floor exists because a short
    /// decision/action pair can hit a high Jaccard ratio on shared filler
    /// words alone while still being two genuinely different items — e.g.
    /// "Boka möte med Erik" vs. "Boka möte med Anna" (0.6) or "Review the
    /// Falcon repo" vs. "Review the Falcon docs" (0.6) — a lower threshold
    /// (0.5) previously collapsed pairs like these.
    private static func isParaphrase(_ a: String, _ b: String) -> Bool {
        let tokensA = similarityTokens(a)
        let tokensB = similarityTokens(b)
        guard min(tokensA.count, tokensB.count) >= 3 else { return false }
        let union = tokensA.union(tokensB)
        guard !union.isEmpty else { return false }
        return Double(tokensA.intersection(tokensB).count) / Double(union.count) >= 0.75
    }

    /// Placeholder-shaped strings an engine sometimes writes as an entire
    /// `decisions`/`openQuestions` entry or action-item `text` instead of
    /// just omitting it — e.g. Foundation Models emitting the literal JSON
    /// string `"null"` as the sole `openQuestions` entry rather than an empty
    /// array (seen on the real sv-ewave-mikael sample, see "Tuning round 2"
    /// in docs/review-2026-09/debrief-probe-2026-09-17.md). Builds on
    /// `DebriefActionItem.placeholderValues` (already covers "n/a", "none",
    /// "null", "ingen", "-") plus a couple of forms specific to whole-item
    /// text that aren't otherwise in that owner/due-focused set.
    private static let emptyContentPlaceholders: Set<String> = DebriefActionItem.placeholderValues.union(["inga"])

    /// Whether `text`, trimmed and lowercased, is empty or one of
    /// `emptyContentPlaceholders` — i.e. not real content at all.
    private static func isEmptyOrPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return emptyContentPlaceholders.contains(trimmed.lowercased())
    }

    /// A copy with every action item's placeholder owner/due mapped to nil;
    /// any `decisions`/`openQuestions` entry, or action item, whose entire
    /// `text` is empty or placeholder-shaped (e.g. `"null"`, `"None"`)
    /// dropped outright, order preserved; and any decision that duplicates an
    /// action item removed (an action item wins — it's the one still worth
    /// showing). A decision is removed both for an exact-string match
    /// (`DebriefActionItem.dedupeKey`, e.g. "Schedule a new meeting for the
    /// gaming team." in both lists) and for a *paraphrase* match (see
    /// `isParaphrase`, e.g. sv "Ska ta fram en tidsram..." as a decision vs.
    /// "Skapa en tidsram..." as an action item — same item, different
    /// wording, no exact substring in common). Applied by the pipeline after
    /// summarizing, so no engine's habit of writing "N/A"/"null" instead of
    /// null or an empty array, listing the same item twice, or restating one
    /// item across both lists in different words, reaches the rendered output.
    func normalized() -> DebriefSummary {
        let normalizedActionItems = actionItems
            .map { $0.normalized() }
            .filter { !Self.isEmptyOrPlaceholder($0.text) }
        let actionItemKeys = Set(normalizedActionItems.map { DebriefActionItem.dedupeKey($0.text) })
        let dedupedDecisions = decisions.filter { decision in
            guard !Self.isEmptyOrPlaceholder(decision) else { return false }
            guard !actionItemKeys.contains(DebriefActionItem.dedupeKey(decision)) else { return false }
            return !normalizedActionItems.contains { Self.isParaphrase(decision, $0.text) }
        }
        let filteredOpenQuestions = openQuestions.filter { !Self.isEmptyOrPlaceholder($0) }

        return DebriefSummary(
            summary: summary,
            decisions: dedupedDecisions,
            actionItems: normalizedActionItems,
            openQuestions: filteredOpenQuestions
        )
    }

    /// A copy where each action item's fabricated-looking `due`/`owner` is
    /// mapped to nil by checking against the transcript that was actually
    /// spoken — see `DebriefActionItem.validated(against:)` for exactly what
    /// this does and does not catch. Applied by the pipeline right after
    /// `normalized()`.
    func validated(against transcript: String) -> DebriefSummary {
        DebriefSummary(
            summary: summary,
            decisions: decisions,
            actionItems: actionItems.map { $0.validated(against: transcript) },
            openQuestions: openQuestions
        )
    }

    /// Renders the summary as plain text (no markdown) for the given language.
    ///
    /// Sections with no content are omitted; SUMMARY is always present.
    /// Falls back to English for any language other than "sv".
    func renderPlainText(language: String, date: Date = Date()) -> String {
        let strings = DebriefSummaryStrings.forLanguage(language)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let dateString = dateFormatter.string(from: date)

        var blocks: [String] = ["\(strings.title) – \(dateString)"]

        blocks.append("\(strings.summaryHeading)\n\(summary)")

        if !decisions.isEmpty {
            blocks.append("\(strings.decisionsHeading)\n\(decisions.joined(separator: "\n"))")
        }

        if !actionItems.isEmpty {
            let lines = actionItems.map { strings.renderActionItem($0) }
            blocks.append("\(strings.actionItemsHeading)\n\(lines.joined(separator: "\n"))")
        }

        if !openQuestions.isEmpty {
            blocks.append("\(strings.openQuestionsHeading)\n\(openQuestions.joined(separator: "\n"))")
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }
}

/// Language-specific headings and action-item phrasing for `renderPlainText`.
private struct DebriefSummaryStrings {
    let title: String
    let summaryHeading: String
    let decisionsHeading: String
    let actionItemsHeading: String
    let openQuestionsHeading: String
    let dueSuffix: (String) -> String

    func renderActionItem(_ item: DebriefActionItem) -> String {
        var line = "[ ] \(item.text)"
        switch (item.owner, item.due) {
        case let (owner?, due?):
            line += " (\(owner), \(dueSuffix(due)))"
        case let (owner?, nil):
            line += " (\(owner))"
        case let (nil, due?):
            line += " (\(dueSuffix(due)))"
        case (nil, nil):
            break
        }
        return line
    }

    static func forLanguage(_ language: String) -> DebriefSummaryStrings {
        switch language {
        case "sv":
            return DebriefSummaryStrings(
                title: "MÖTESSAMMANFATTNING",
                summaryHeading: "SAMMANFATTNING",
                decisionsHeading: "BESLUT",
                actionItemsHeading: "ÅTGÄRDER",
                openQuestionsHeading: "ÖPPNA FRÅGOR",
                dueSuffix: { "senast \($0)" }
            )
        default:
            return DebriefSummaryStrings(
                title: "MEETING DEBRIEF",
                summaryHeading: "SUMMARY",
                decisionsHeading: "DECISIONS",
                actionItemsHeading: "ACTION ITEMS",
                openQuestionsHeading: "OPEN QUESTIONS",
                dueSuffix: { "due \($0)" }
            )
        }
    }
}
