import Foundation

/// Applies model-proposed deltas to a `DebriefState` deterministically, in
/// plain Swift.
///
/// This is the half of decision 8 that the model is not trusted with. A delta
/// can only ADD an item, RESOLVE an id, or CORRECT an id; nothing a model
/// returns can regenerate or reorder the list, so `state.activeItems.count`
/// can only fall through a path this type implements itself: an explicit
/// resolve, `dedupe`, or an applied consolidation drop.
struct DebriefAccumulator {
    private(set) var state: DebriefState

    /// Human-readable record of everything that was ignored or collapsed, in
    /// order. Mirrored to `AppLogger.llm`; kept in memory as well so tests (and
    /// a future diagnostics view) can assert on it without scraping os_log.
    /// Capped so a long meeting cannot grow it without bound.
    private(set) var events: [String] = []

    private static let maxEvents = 200

    /// The one literal a correction may send to CLEAR an existing owner or due
    /// (rather than replace it). Documented to the model in
    /// `DeltaPromptBuilder` and in the `@Guide` descriptions, so "leave it
    /// alone" (omit the field) and "it was wrong, remove it" (send "null") are
    /// distinguishable — an LLM cannot otherwise express the second.
    static let clearSentinel = "null"

    static func isClearSentinel(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == clearSentinel
    }

    init(state: DebriefState = DebriefState()) {
        self.state = state
    }

    // MARK: - Applying a delta

    /// Applies `delta` to the state:
    /// 1. every `newItem` is appended with a fresh id and `sourceChunk: chunkIndex`,
    /// 2. every known, still-active `resolvedId` is marked resolved,
    /// 3. every known `correction` replaces that item's text (and owner/due when
    ///    the correction supplies them),
    /// 4. the summary paragraph is replaced, but only by a non-empty one.
    ///
    /// Ids that do not exist — the model hallucinating a number, or naming an
    /// id that dedupe already collapsed — are ignored and recorded. This is the
    /// expected failure mode, not an error: a delta is a suggestion.
    mutating func apply(_ delta: DebriefDelta, chunkIndex: Int) {
        for newItem in delta.newItems {
            append(
                kind: newItem.kind,
                text: newItem.text,
                owner: newItem.owner,
                due: newItem.due,
                chunkIndex: chunkIndex
            )
        }

        for id in delta.resolvedIds {
            guard let index = state.items.firstIndex(where: { $0.id == id && !$0.resolved }) else {
                record("chunk \(chunkIndex): ignored resolve of unknown or already-resolved id \(id)")
                continue
            }
            state.items[index].resolved = true
        }

        for correction in delta.corrections {
            guard let index = state.items.firstIndex(where: { $0.id == correction.id }) else {
                record("chunk \(chunkIndex): ignored correction of unknown id \(correction.id)")
                continue
            }
            let trimmed = correction.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                state.items[index].text = trimmed
            }
            // A correction may CLEAR an owner/due by sending the literal string
            // "null" (see `clearSentinel`). Omitting the field, or sending any
            // other placeholder, leaves the existing value alone — a model that
            // simply does not mention the owner must not wipe it.
            if let rawOwner = correction.owner {
                if Self.isClearSentinel(rawOwner) {
                    state.items[index].owner = nil
                } else if let owner = DebriefItem.normalizedOwner(rawOwner) {
                    state.items[index].owner = owner
                }
            }
            if let rawDue = correction.due {
                if Self.isClearSentinel(rawDue) {
                    state.items[index].due = nil
                } else if let due = DebriefActionItem.normalizedField(rawDue) {
                    state.items[index].due = due
                }
            }
        }

        let trimmedSummary = delta.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            state.summary = trimmedSummary
        }
    }

    /// Appends one item with a fresh id. Blank/placeholder text is skipped — an
    /// engine that emits `"null"` as an item must not create a numbered item the
    /// model then has to reason about.
    mutating func append(
        kind: DebriefItem.Kind,
        text: String,
        owner: String? = nil,
        due: String? = nil,
        chunkIndex: Int
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              DebriefActionItem.normalizedField(trimmed) != nil else {
            record("chunk \(chunkIndex): skipped empty or placeholder \(kind.rawValue)")
            return
        }
        state.items.append(
            DebriefItem(
                id: state.nextId,
                kind: kind,
                text: trimmed,
                owner: DebriefItem.normalizedOwner(owner),
                due: DebriefActionItem.normalizedField(due),
                sourceChunk: chunkIndex
            )
        )
        state.nextId += 1
    }

    /// Marks `id` resolved. Returns whether anything changed.
    @discardableResult
    mutating func markResolved(_ id: Int) -> Bool {
        guard let index = state.items.firstIndex(where: { $0.id == id && !$0.resolved }) else { return false }
        state.items[index].resolved = true
        return true
    }

    /// Replaces the summary paragraph outright (consolidation's one privilege).
    mutating func setSummary(_ summary: String) {
        state.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Dedupe

    /// Comparison key for "the same item said twice": lowercased, punctuation
    /// stripped, whitespace collapsed to single spaces.
    static func normalizedText(_ text: String) -> String {
        let lowercased = text.lowercased()
        let withoutPunctuation = String(
            lowercased.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        )
        return withoutPunctuation
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Collapses duplicate ACTIVE items of the same kind.
    ///
    /// Two items are duplicates when their `normalizedText` is equal, or when
    /// `similarity` rates them at least `threshold`. The EARLIER item (lower id,
    /// i.e. the one the model has already been shown and may have referenced)
    /// survives; the later one is removed after donating any `owner`/`due` the
    /// survivor was missing, so a second mention that added a deadline is not
    /// thrown away with the duplicate.
    ///
    /// `similarity` is injected rather than fixed so this stays a pure function
    /// of text: `EmbeddingSimilarity` supplies a cosine-over-embeddings closure
    /// in the app, and tests supply a deterministic stub.
    /// `similarity` is called at most once per unordered pair of ACTIVE items
    /// of the SAME kind, and never for a pair whose normalized texts are equal
    /// (that pair is already a duplicate by the cheap test) — so for n such
    /// items the cost is at most n(n-1)/2 calls per kind, and 0 when every item
    /// repeats a text already seen. Callers pass a memoizing similarity
    /// (`EmbeddingSimilarity`) on top of that.
    mutating func dedupe(using similarity: (String, String) -> Double, threshold: Double = 0.9) {
        var survivingIndexByKey: [String: Int] = [:]
        /// Indices into `survivors` of the active survivors of each kind, so a
        /// near-duplicate scan never touches another kind or a resolved item.
        var activeIndicesByKind: [DebriefItem.Kind: [Int]] = [:]
        var normalizedByIndex: [Int: String] = [:]
        var survivors: [DebriefItem] = []
        var removedIds: [Int] = []

        for item in state.items {
            guard !item.resolved else {
                survivors.append(item)
                continue
            }

            let normalized = Self.normalizedText(item.text)
            let key = "\(item.kind.rawValue)|\(normalized)"
            var matchIndex = survivingIndexByKey[key]

            if matchIndex == nil {
                matchIndex = activeIndicesByKind[item.kind, default: []].first { candidateIndex in
                    // Equal normalized text would have hit the key map above;
                    // never spend a similarity call on it.
                    guard normalizedByIndex[candidateIndex] != normalized else { return false }
                    return similarity(survivors[candidateIndex].text, item.text) >= threshold
                }
            }

            guard let index = matchIndex else {
                survivingIndexByKey[key] = survivors.count
                activeIndicesByKind[item.kind, default: []].append(survivors.count)
                normalizedByIndex[survivors.count] = normalized
                survivors.append(item)
                continue
            }

            if survivors[index].owner == nil { survivors[index].owner = item.owner }
            if survivors[index].due == nil { survivors[index].due = item.due }
            removedIds.append(item.id)
        }

        guard !removedIds.isEmpty else { return }
        state.items = survivors
        record("deduped \(removedIds.count) duplicate item(s): ids \(removedIds.map(String.init).joined(separator: ", "))")
    }

    // MARK: - Events

    mutating func record(_ message: String) {
        AppLogger.llm.warning("DebriefAccumulator: \(message, privacy: .public)")
        events.append(message)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
    }
}
