import Foundation

/// Turns a raw transcript of a spoken post-meeting debrief into a structured
/// `DebriefSummary`.
///
/// Conformers are not `@MainActor`-bound: summarization may involve network
/// calls (Ollama) or on-device model inference (Foundation Models), both of
/// which should run off the main actor.
protocol DebriefSummarizer: AnyObject {
    /// Human-readable name, used for logging and to record which engine
    /// produced a result (see `ChainedDebriefSummarizer.lastUsedEngineName`).
    var name: String { get }

    /// Whether this engine is currently usable (model downloaded, server
    /// reachable, etc). Cheap enough to call before every summarize attempt.
    func isAvailable() async -> Bool

    /// Summarizes `transcript` (spoken in `language`) into a `DebriefSummary`.
    func summarize(transcript: String, language: String) async throws -> DebriefSummary
}

enum DebriefSummarizerError: Error, LocalizedError {
    case unavailable(String)
    case emptyTranscript
    case badResponse(String)
    case http(Int)
    case timeout

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Summarizer unavailable: \(reason)"
        case .emptyTranscript:
            return "Transcript is empty."
        case .badResponse(let excerpt):
            return "Summarizer returned an unparsable response: \(excerpt)"
        case .http(let code):
            return "Summarizer HTTP request failed with status \(code)."
        case .timeout:
            return "Summarizer timed out."
        }
    }
}

/// Builds the system/user prompts sent to LLM-backed summarizers (Ollama,
/// Foundation Models). Kept separate from the engines so the wording can be
/// iterated on and tested without touching networking/session code.
enum DebriefPromptBuilder {
    static let jsonSchemaDescription = """
    {
      "summary": "string, 2-5 sentences",
      "decisions": ["string", "..."],
      "actionItems": [{"text": "string", "owner": "string or null", "due": "string or null"}],
      "openQuestions": ["string", "..."]
    }
    """

    /// Language-specific example literals for `systemPrompt`. Keeping these
    /// separate per language (rather than showing both languages' examples
    /// side by side in one shared string, as earlier tuning rounds did) is a
    /// deliberate fix for a real defect: an all-English transcript
    /// (`en-cadec-gaming`) came back with a Swedish `due`/`owner`
    /// ("om två veckor"/"jag") after a prompt-trim, almost certainly because
    /// the model was copying a literal Swedish example string that was
    /// present in the prompt regardless of the transcript's own language.
    /// `forLanguage` defaults to English for anything other than "sv",
    /// matching `DebriefPipeline.renderLanguage`.
    private struct PromptExamples {
        let selfNamingAside: String
        let committalPhrases: String
        let conditionalPhrase: String
        let decidedToPhrase: String
        let firstPersonSubject: String
        let firstPersonOwner: String
        let thirdPersonSubject: String
        let alreadyArrangedEvent: String
        let dueExamples: String
        let bucketDecisionExample: String
        let bucketActionExample: String

        static func forLanguage(_ language: String) -> PromptExamples {
            guard language == "sv" else {
                return PromptExamples(
                    selfNamingAside: "it was me, Sebastian, and Erik",
                    committalPhrases: "\"we decided\", \"we'll go with\"",
                    conditionalPhrase: "if he should X or Y",
                    decidedToPhrase: "we decided to...",
                    firstPersonSubject: "I",
                    firstPersonOwner: "me",
                    thirdPersonSubject: "X will",
                    alreadyArrangedEvent: "we will have a meeting tomorrow",
                    dueExamples: "\"one week from now\", \"tomorrow\"",
                    bucketDecisionExample: "booked the meeting",
                    bucketActionExample: "book the meeting"
                )
            }
            return PromptExamples(
                selfNamingAside: "det var jag, Sebastian och Erik",
                committalPhrases: "\"vi bestämde\", \"vi kör på\"",
                conditionalPhrase: "om han ska X eller Y",
                decidedToPhrase: "vi bestämde att...",
                firstPersonSubject: "jag",
                firstPersonOwner: "jag",
                thirdPersonSubject: "X ska",
                alreadyArrangedEvent: "vi ska ha ett möte imorgon",
                dueExamples: "\"om två veckor\", \"imorgon\"",
                bucketDecisionExample: "bokade mötet",
                bucketActionExample: "boka mötet"
            )
        }
    }

    /// Appended to `systemPrompt` when `isLabeledTranscript` is true — the
    /// transcript came from `TwoTrackMerger.render`, i.e. a call debrief with
    /// separate mic ("Me") and system-audio ("Them") tracks (decision 4 in
    /// `tasks/decisions-call-debrief.md`). Exists to fix the owner-misattribution
    /// defect documented in docs/review-2026-09/debrief-probe-2026-09-17.md
    /// ("Tuning round 2", defect 4): without knowing who is speaking, the model
    /// has previously assigned the speaker's own "I need to..." task to another
    /// attendee. The labels themselves ("Me:"/"Them:") are never translated —
    /// only the rule text explaining them is language-specific.
    private static let labeledTranscriptRuleEnglish = """

        This transcript is labeled: each line starts with "Me:" (spoken by \
        you, the user) or "Them:" (spoken by the other meeting participants). \
        Keep writing in first person ("I"/"we") for what was said on "Me:" \
        lines — you are still the user this summary is written for. A \
        commitment made on a "Me:" line belongs to you; never attribute it to \
        another attendee. A commitment made on a "Them:" line belongs to \
        whichever participant is named on that line; if no name is given for \
        a "Them:" commitment, use owner "them" rather than inventing a name \
        or assuming it is yours.
        """

    private static let labeledTranscriptRuleSwedish = """

        Denna transkription är märkt: varje rad börjar med "Me:" (sagt av \
        dig, användaren) eller "Them:" (sagt av övriga mötesdeltagare). \
        Fortsätt skriva i jag-form ("jag"/"vi") för det som sägs på \
        "Me:"-rader — det är fortfarande du sammanfattningen skrivs för. Ett \
        åtagande på en "Me:"-rad tillhör dig; tillskriv det aldrig en annan \
        deltagare. Ett åtagande på en "Them:"-rad tillhör den deltagare som \
        namnges på den raden; om ingen namnges för ett åtagande på en \
        "Them:"-rad, använd ägaren "them" istället för att hitta på ett namn \
        eller anta att det är ditt.
        """

    /// - Parameter isLabeledTranscript: true when `transcript` was produced
    ///   by `TwoTrackMerger.render` (Me/Them lines) rather than plain
    ///   dictation. Defaults to false so every existing call site (and this
    ///   file's own prompt tests) keeps the unlabeled prompt byte-identical.
    static func systemPrompt(language: String, isLabeledTranscript: Bool = false) -> String {
        let ex = PromptExamples.forLanguage(language)
        let basePrompt = Self.basePrompt(ex: ex)
        guard isLabeledTranscript else { return basePrompt }
        let labeledRule = language == "sv" ? labeledTranscriptRuleSwedish : labeledTranscriptRuleEnglish
        return basePrompt + labeledRule
    }

    /// The unlabeled prompt body — unchanged by `isLabeledTranscript`, kept
    /// byte-identical to before that parameter existed (see its call site in
    /// `systemPrompt`, and the `DebriefPromptBuilderLanguageTests` that guard
    /// it).
    private static func basePrompt(ex: PromptExamples) -> String {
        """
        You are an assistant that summarizes spoken post-meeting debriefs. The \
        transcript is the USER's own first-person account of a meeting they just \
        left — not a description of someone else. The transcript may be Swedish or \
        English, and punctuation may be missing or inconsistent because it comes \
        from speech-to-text.

        Write your output in the SAME language as the transcript, and in FIRST \
        PERSON ("I", "we") the way the speaker talks — never call them "the \
        speaker" or refer to them in the third person. If the speaker states their \
        own name (often as an aside, e.g. "\(ex.selfNamingAside)"), that name \
        refers to THEM, the speaker — it is not a separate third person they met \
        with. Never write something like "we met with Sebastian" when Sebastian is \
        the speaker's own name; write "I met with..." instead. Use that name as the \
        owner for actions the speaker themselves will do. Write every field, \
        including owner and due, in the transcript's language only.

        Speech-to-text often spells the same name or company two different ways in \
        one transcript (e.g. "Acme" vs "Akme" for the same company). These are \
        the SAME entity, not two different ones. Before you write anything, decide \
        on ONE spelling for every name that appears more than once with different \
        spellings, and re-check your finished summary, decisions, action items, and \
        open questions to make sure the spelling you rejected does not appear \
        ANYWHERE in them — not even once, not even in the summary while a decision \
        uses the other spelling.

        Return ONLY a JSON object with this shape, no prose before or after it:
        \(jsonSchemaDescription)

        Rules:
        - Spell every name/company only ONE way everywhere, even if the transcript \
        spells it more than one way.
        - summary: 2-5 sentences, first person, what happened IN the meeting. Something \
        already done or true before the meeting is context here only, never a decision \
        or action.
        - decisions: ONLY things explicitly agreed or concluded, using committal \
        language actually spoken (e.g. \(ex.committalPhrases)). A conditional or \
        either/or still being weighed ("\(ex.conditionalPhrase)") is an openQuestion, \
        not a decision. A future task — scheduling, booking, sending, following up — \
        is always an actionItem, never a decision, even phrased as "\(ex.decidedToPhrase)". \
        Empty array if none.
        - actionItems: things still to do after the meeting. owner is the GRAMMATICAL \
        SUBJECT of the task as spoken: "\(ex.firstPersonSubject)" means the speaker — \
        use their own stated name, else "\(ex.firstPersonOwner)"; \
        "\(ex.thirdPersonSubject)" means X. Never give the speaker's own task to someone \
        else nearby. An already-arranged event ("\(ex.alreadyArrangedEvent)") is NOT an \
        action item — summary only. due is copied VERBATIM as spoken (e.g. \
        \(ex.dueExamples)) — NEVER converted to a calendar date, NEVER given a year or \
        weekday the speaker didn't say, and never an unrelated date borrowed from \
        elsewhere in the transcript. owner is only a person actually named, never a \
        generic group like "Team"/"Everyone"; owner and due are null when not spoken.
        - Every item is EITHER a decision OR an actionItem, never both or worded twice \
        in each place (e.g. "\(ex.bucketDecisionExample)" as a decision and \
        "\(ex.bucketActionExample)" as an action item is still one item).
        - openQuestions: unresolved points or either/or options actually voiced, \
        including a conditional the speaker is still weighing (see decisions). Never \
        invent one. Empty array if none.
        - Never invent facts, owners, dates, or years absent from the transcript. Use \
        empty arrays for empty sections. owner/due must be null, never a placeholder \
        such as "Not specified", "TBD", "N/A", "None" or "Unknown".
        """
    }

    static func userPrompt(transcript: String, language: String) -> String {
        """
        Transcript (language: \(language)):

        \(transcript)
        """
    }
}

/// Tolerant parser for the JSON an LLM is asked to return. Model output is
/// frequently wrapped in ``` fences or preceded by chatty text, so this
/// extracts the first plausible JSON object before decoding.
enum DebriefSummaryParser {
    static func parse(_ raw: String) throws -> DebriefSummary {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            text = text
                .split(separator: "\n")
                .filter { !$0.hasPrefix("```") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let firstBrace = text.firstIndex(of: "{"),
              let lastBrace = text.lastIndex(of: "}"),
              firstBrace <= lastBrace else {
            throw DebriefSummarizerError.badResponse(String(raw.prefix(200)))
        }

        let jsonSubstring = text[firstBrace...lastBrace]

        guard let data = jsonSubstring.data(using: .utf8) else {
            throw DebriefSummarizerError.badResponse(String(raw.prefix(200)))
        }

        do {
            let decoded = try JSONDecoder().decode(DebriefSummaryDTO.self, from: data)
            return decoded.toDebriefSummary()
        } catch {
            throw DebriefSummarizerError.badResponse(String(raw.prefix(200)))
        }
    }
}

/// Decoding-only mirror of `DebriefSummary` with optional arrays, so a
/// response missing `decisions`/`actionItems`/`openQuestions` entirely still
/// decodes (as empty arrays) instead of failing.
private struct DebriefSummaryDTO: Decodable {
    var summary: String
    var decisions: [String]?
    var actionItems: [DebriefActionItem]?
    var openQuestions: [String]?

    func toDebriefSummary() -> DebriefSummary {
        // Normalize here too, so a placeholder owner/due is gone even for
        // callers that parse without going through DebriefPipeline.
        DebriefSummary(
            summary: summary,
            decisions: decisions ?? [],
            actionItems: actionItems ?? [],
            openQuestions: openQuestions ?? []
        ).normalized()
    }
}

/// Which summarization engine(s) to use, persisted in config.
enum DebriefEngineKind: String, Codable, CaseIterable {
    case auto
    case foundationModels
    case ollama
    case heuristic
}

enum DebriefSummarizerFactory {
    /// Builds a summarizer for `kind`. `.auto` returns a `ChainedDebriefSummarizer`
    /// that tries Foundation Models, then Ollama, then the heuristic fallback,
    /// in that order, using the first one that is available and succeeds.
    static func make(kind: DebriefEngineKind, ollamaModel: String) -> DebriefSummarizer {
        switch kind {
        case .auto:
            var engines: [DebriefSummarizer] = []
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                engines.append(FoundationModelsDebriefSummarizer())
            }
            #endif
            engines.append(OllamaDebriefSummarizer(model: ollamaModel))
            engines.append(HeuristicDebriefSummarizer())
            return ChainedDebriefSummarizer(engines: engines)
        case .foundationModels:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                return FoundationModelsDebriefSummarizer()
            }
            #endif
            return HeuristicDebriefSummarizer()
        case .ollama:
            return OllamaDebriefSummarizer(model: ollamaModel)
        case .heuristic:
            return HeuristicDebriefSummarizer()
        }
    }
}

/// Tries a list of summarizers in order, using the first one that reports
/// itself available and whose `summarize` call succeeds. Exists so `.auto`
/// mode always produces a result: the heuristic fallback should always
/// succeed (it only throws `.emptyTranscript`, which is checked up front).
final class ChainedDebriefSummarizer: DebriefSummarizer {
    let name = "Chained"

    private let engines: [DebriefSummarizer]

    /// Name of the engine that produced the most recent result, or nil if
    /// `summarize` hasn't been called yet (or every engine failed).
    private(set) var lastUsedEngineName: String?

    /// Engine names in try order, for tests/diagnostics.
    var engineNames: [String] { engines.map(\.name) }

    init(engines: [DebriefSummarizer]) {
        self.engines = engines
    }

    func isAvailable() async -> Bool {
        for engine in engines where await engine.isAvailable() {
            return true
        }
        return false
    }

    func summarize(transcript: String, language: String) async throws -> DebriefSummary {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DebriefSummarizerError.emptyTranscript
        }

        var lastError: Error?

        for engine in engines {
            try Task.checkCancellation()
            guard await engine.isAvailable() else { continue }
            do {
                let result = try await engine.summarize(transcript: transcript, language: language)
                lastUsedEngineName = engine.name
                return result
            } catch let error as CancellationError {
                throw error
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? DebriefSummarizerError.unavailable("No summarizer engine is available.")
    }
}
