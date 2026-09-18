import Foundation

/// What the model is allowed to propose after reading ONE new transcript chunk.
///
/// Note what is absent: there is no way to express "here is the new full item
/// list". The model can add, resolve, and correct — Swift code owns the list
/// itself. The spike behind decision 8 found model-proposed MERGES were mostly
/// wrong (pairing unrelated items, splitting real duplicates), so merging is
/// not in this vocabulary at all; `DebriefAccumulator.dedupe` does it in code.
struct DebriefDelta: Equatable {
    /// One item the model claims is genuinely new in this chunk.
    struct NewItem: Equatable {
        var kind: DebriefItem.Kind
        var text: String
        var owner: String?
        var due: String?

        init(kind: DebriefItem.Kind, text: String, owner: String? = nil, due: String? = nil) {
            self.kind = kind
            self.text = text
            self.owner = owner
            self.due = due
        }
    }

    /// A rewording of an existing item, addressed by its id.
    struct Correction: Equatable {
        var id: Int
        var text: String
        var owner: String?
        var due: String?

        init(id: Int, text: String, owner: String? = nil, due: String? = nil) {
            self.id = id
            self.text = text
            self.owner = owner
            self.due = due
        }
    }

    /// The whole-meeting summary paragraph, fully regenerated each chunk. This
    /// is the ONE field the model may rewrite wholesale.
    var summary: String
    var newItems: [NewItem]
    /// Ids the chunk explicitly closes (answered, completed, made obsolete).
    var resolvedIds: [Int]
    var corrections: [Correction]

    init(
        summary: String = "",
        newItems: [NewItem] = [],
        resolvedIds: [Int] = [],
        corrections: [Correction] = []
    ) {
        self.summary = summary
        self.newItems = newItems
        self.resolvedIds = resolvedIds
        self.corrections = corrections
    }
}

/// What the model is allowed to propose in the FINAL pass over a complete
/// meeting: rewrite the summary paragraph, and drop items that turned out not
/// to be items at all. It may NOT merge, reorder, or regenerate the lists —
/// the spike found model DROPs ("not an item") reasonable but model MERGEs
/// unreliable.
struct ConsolidationDelta: Equatable {
    struct Drop: Equatable {
        var id: Int
        /// Why this is not a real item. A drop with an empty reason is ignored
        /// by `RollingDebriefSummarizer.finish()` — an unexplained drop is the
        /// probe's "undeclared drop" failure in disguise.
        var reason: String

        init(id: Int, reason: String) {
            self.id = id
            self.reason = reason
        }
    }

    var summary: String
    var dropIds: [Drop]

    init(summary: String = "", dropIds: [Drop] = []) {
        self.summary = summary
        self.dropIds = dropIds
    }
}

/// Failures specific to the delta path, on top of `DebriefSummarizerError`
/// (which the single-pass engines already share).
enum DeltaSummarizerError: Error, LocalizedError {
    /// The prompt — numbered state plus chunk — did not fit the model's context
    /// window. Recoverable: `RollingDebriefSummarizer.ingest` retries against a
    /// compact render, then against half-chunks.
    case contextWindowExceeded(String)

    var errorDescription: String? {
        switch self {
        case .contextWindowExceeded(let detail):
            return "Delta summarizer exceeded the model's context window: \(detail)"
        }
    }
}

/// An engine that can turn (state, chunk) into a `DebriefDelta`, and a final
/// state into a `ConsolidationDelta`.
///
/// Deliberately NOT `@MainActor`: conformers do network calls (Ollama) or
/// on-device inference (Foundation Models).
protocol DeltaSummarizing: AnyObject {
    /// Human-readable name, used for logging and to record which engine
    /// produced a result.
    var name: String { get }

    func isAvailable() async -> Bool

    func extractDelta(
        state: DebriefState,
        chunk: String,
        chunkIndex: Int,
        language: String
    ) async throws -> DebriefDelta

    func consolidate(state: DebriefState, language: String) async throws -> ConsolidationDelta
}

/// System/user prompts for the two delta call sites.
///
/// The extraction/ownership/no-invention rules are NOT rewritten here: they are
/// lifted verbatim from `DebriefPromptBuilder.systemPrompt(language:)` at
/// runtime (see `coreRules`), so the delta path and the single-pass path can
/// never drift apart and the language-specific example literals
/// (`PromptExamples`, which exist to stop a Swedish example leaking into an
/// English transcript) are reused as-is. Only the *framing* — "you output a
/// delta over a numbered state", and how labeled speech is attributed — is
/// written here.
enum DeltaPromptBuilder {
    /// Marker that begins the rules section of the app's single-pass system
    /// prompt (DebriefSummarizer.swift, `DebriefPromptBuilder.systemPrompt`).
    private static let rulesMarker = "Rules:"

    /// The `Rules:` block of the existing single-pass system prompt, for the
    /// given language. Falls back to the whole prompt if the marker ever moves,
    /// which is noisy but never silently drops the rules.
    static func coreRules(language: String) -> String {
        let full = DebriefPromptBuilder.systemPrompt(language: language)
        guard let range = full.range(of: rulesMarker) else { return full }
        return String(full[range.lowerBound...])
    }

    /// How to attribute a commitment in a transcript whose paragraphs are
    /// labeled by speaker. Mirrors the single-pass prompt's owner rule (owner
    /// is the GRAMMATICAL SUBJECT as spoken) applied to the label instead of
    /// the pronoun.
    static func labelRules(language: String) -> String {
        let selfOwner = language == "sv" ? "\"jag\"" : "\"me\""
        return """
        The chunk may be labeled speech: a paragraph starting with "Me:" is the \
        USER speaking about themselves in the first person, and a paragraph \
        starting with "Them:" is another participant on the call. A commitment \
        made in a "Me:" paragraph is the user's — its owner is the user's own \
        stated name if they gave one, else \(selfOwner). A commitment made in a \
        "Them:" paragraph belongs to the participant actually NAMED on or near \
        that line; when no participant is named anywhere, owner is null. Never \
        write "Them", "them", or any other stand-in for an unnamed participant \
        as an owner, and never fall back to a generic group. Never give a "Me:" \
        task to a participant, and never give a "Them:" task to the user. The \
        labels themselves are scaffolding: never write "Me" or "Them" into an \
        item's text.
        """
    }

    /// Shape of the delta JSON, for engines that ask for JSON rather than using
    /// a structured-output schema (Ollama).
    static let deltaJSONSchemaDescription = """
    {
      "summary": "string, 2-5 sentences, the WHOLE meeting so far",
      "newDecisions": ["string", "..."],
      "newActionItems": [{"text": "string", "owner": "string or null", "due": "string or null"}],
      "newOpenQuestions": ["string", "..."],
      "resolvedIds": [1, 2],
      "corrections": [{"id": 3, "text": "string", "owner": "string, or \\"null\\" to clear it, or omitted to keep it", "due": "string, or \\"null\\" to clear it, or omitted to keep it"}]
    }
    """

    static let consolidationJSONSchemaDescription = """
    {
      "summary": "string, 2-5 sentences, final summary of the whole meeting",
      "dropIds": [{"id": 4, "reason": "string, why this is not a real item"}]
    }
    """

    static func deltaSystemPrompt(language: String) -> String {
        """
        You maintain the state of an ONGOING spoken meeting as a NUMBERED list of \
        items (decisions / action items / open questions), built up chunk by \
        chunk while the meeting is still being transcribed. You are given the \
        current numbered state (a list may say "(none)" if nothing is in it yet) \
        and the NEXT chunk of transcript that continues directly after it.

        You do NOT rewrite the state. You output ONLY what changed:
        - summary: a fresh 2-5 sentence summary of the whole meeting SO FAR — this \
        one field, and only this one, is fully regenerated each time.
        - newDecisions / newActionItems / newOpenQuestions: ONLY items genuinely \
        NEW in this chunk. Never restate an item already in the numbered list, \
        even worded differently, and never merge or combine existing items.
        - resolvedIds: ids from the numbered list that THIS chunk explicitly \
        resolves, completes, answers, or makes obsolete. Never list an id just \
        because this chunk does not repeat it.
        - corrections: only when this chunk shows an existing item's wording, \
        owner, or due was wrong or incomplete. Most items need none. Leave a \
        correction's owner or due out entirely to keep the existing value; send \
        the exact string "null" for it only when the existing value is wrong and \
        nothing should replace it.

        Never invent an id that is not in the numbered list.

        \(labelRules(language: language))

        The rules below describe decisions, actionItems and openQuestions; they \
        apply unchanged to newDecisions, newActionItems and newOpenQuestions.

        \(coreRules(language: language))
        """
    }

    static func deltaUserPrompt(state: DebriefState, chunk: String, chunkIndex: Int, language: String) -> String {
        """
        Current state of the meeting so far:

        \(state.rendered(language: language))

        Next chunk (\(chunkIndex + 1)) of the transcript (language: \(language)):

        \(chunk)
        """
    }

    static func consolidationSystemPrompt(language: String) -> String {
        """
        You are given the FINAL accumulated state of a now-COMPLETE spoken \
        meeting, as a numbered list of items built up chunk by chunk. You do NOT \
        rewrite the list. You output ONLY:
        - summary: a fresh 2-5 sentence FIRST-PERSON summary of the whole meeting.
        - dropIds: ids that are not real items at all — a stray transcription \
        fragment, or something with no content left to act on — each with a short \
        reason saying why.

        Every id you were given that is not in dropIds is kept exactly as it is. \
        Do NOT merge items, do not combine near-duplicates, and do not re-emit \
        the list: duplicates are removed separately and are not your job. Drop \
        sparingly — a real item that is merely terse is still a real item — and \
        never invent an id that was not in the numbered list.

        \(coreRules(language: language))
        """
    }

    static func consolidationUserPrompt(state: DebriefState, language: String) -> String {
        """
        Final accumulated state to consolidate (language: \(language)):

        \(state.rendered(language: language))
        """
    }
}
