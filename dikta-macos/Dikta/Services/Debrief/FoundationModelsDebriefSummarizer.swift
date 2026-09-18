#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Summarizes a debrief transcript using Apple's on-device Foundation Models,
/// via structured (`@Generable`) output so no separate JSON parsing step is
/// needed.
@available(macOS 26.0, *)
final class FoundationModelsDebriefSummarizer: DebriefSummarizer {
    let name = "FoundationModels"

    /// Greedy (argmax, no sampling) by default so the same transcript produces
    /// the same structured output every run — LLM sampling otherwise makes a
    /// single probe run non-representative and lets a repeated user recording
    /// diverge between runs (see "Tuning round 2" in
    /// docs/review-2026-09/debrief-probe-2026-09-17.md). Exposed as an init
    /// parameter so tests/probes can opt back into sampling if ever needed.
    ///
    /// Stored as a plain enum rather than a `GenerationOptions` value on
    /// purpose: a stored property of a FoundationModels type makes the class
    /// layout depend on that framework's metadata at load time, which crashed
    /// the SPM test bundle (signal 11) on a macOS 15 CI runner where the
    /// framework does not exist. The options value is built per call instead.
    enum SamplingStrategy {
        case greedy
        case random
    }

    private let sampling: SamplingStrategy

    init(sampling: SamplingStrategy = .greedy) {
        self.sampling = sampling
    }

    private var generationOptions: GenerationOptions {
        switch sampling {
        case .greedy:
            return GenerationOptions(sampling: .greedy)
        case .random:
            return GenerationOptions()
        }
    }

    func isAvailable() async -> Bool {
        SystemLanguageModel.default.availability == .available
    }

    func summarize(transcript: String, language: String) async throws -> DebriefSummary {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw DebriefSummarizerError.emptyTranscript
        }

        let session = LanguageModelSession(
            instructions: DebriefPromptBuilder.systemPrompt(
                language: language,
                isLabeledTranscript: TwoTrackMerger.isLabeledTranscript(trimmedTranscript)
            )
        )
        let userPrompt = DebriefPromptBuilder.userPrompt(transcript: trimmedTranscript, language: language)

        do {
            let response = try await session.respond(
                to: userPrompt,
                generating: DebriefSummaryGenerable.self,
                options: generationOptions
            )
            return response.content.toDebriefSummary()
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .assetsUnavailable:
                throw DebriefSummarizerError.unavailable(error.localizedDescription)
            default:
                throw error
            }
        }
    }
}

/// `@Generable` mirror of `DebriefSummary` used to request structured output
/// from the on-device model. Mapped to `DebriefSummary` via `toDebriefSummary()`.
@available(macOS 26.0, *)
@Generable
struct DebriefSummaryGenerable {
    // NOTE: these @Guide descriptions are deliberately LANGUAGE-NEUTRAL — no
    // English or Swedish example literals (see "Tuning round 2" follow-up in
    // docs/review-2026-09/debrief-probe-2026-09-17.md). A @Guide string is a
    // single static attribute shared across every call regardless of the
    // transcript's language, so a literal example in one language sitting in
    // the schema description risked being copied into the wrong-language
    // output — exactly the defect that motivated making
    // `DebriefPromptBuilder.systemPrompt` per-language instead. All concrete
    // examples now live only in that per-language prompt text.
    @Guide(description: "A 2 to 5 sentence FIRST-PERSON summary, never third-person (\"the speaker\"), of what happened IN this meeting, written in the transcript's own language. If the speaker names themselves as an aside, that name IS the speaker — never describe the speaker as meeting with their own name as if it were a third person. Something already done or already true BEFORE this meeting is context here, not a decision or action.")
    var summary: String

    @Guide(description: "ONLY things explicitly agreed or concluded in this meeting, using committal language actually spoken — a conditional or either/or option still being weighed is NOT a decision, it belongs in openQuestions instead. A future task like scheduling or booking something is an actionItem, not a decision, even if phrased as an agreement to do it later. Empty array if none were made — never repeat an item that belongs in actionItems.")
    var decisions: [String]

    @Guide(description: "Things someone still has to do after the meeting — scheduling, sending, booking, following up. An event already arranged as a settled fact is NOT an action item. Empty array if none were mentioned. Never repeat an item that belongs in decisions, even worded differently there.")
    var actionItems: [ActionItemGenerable]

    @Guide(description: "Unresolved points or either/or options actually voiced in the meeting, including a conditional the speaker is still weighing. Never invent a question that was not raised. Empty array if none.")
    var openQuestions: [String]

    @available(macOS 26.0, *)
    @Generable
    struct ActionItemGenerable {
        @Guide(description: "The task to do, written in the transcript's own language")
        var text: String

        @Guide(description: "The GRAMMATICAL SUBJECT of this task as spoken: the speaker's own first-person self-reference means the speaker (use their own stated name if given, otherwise the transcript's own first-person word for it); a third person named as the subject means that person. Never assign the speaker's own task to someone else nearby in the transcript. Written in the transcript's own language only. Null when not spoken; never a generic group like \"Team\" or \"Everyone\", and never a placeholder such as \"Not specified\", \"TBD\", \"N/A\" or \"Unknown\"")
        var owner: String?

        @Guide(description: "The deadline for THIS specific task, copied VERBATIM exactly as spoken, in the transcript's own language only; NEVER convert to a calendar date, NEVER add or invent a year, NEVER add a weekday name unless the speaker said that weekday themselves; do not reuse an unrelated date mentioned elsewhere in the transcript, such as the meeting's own date; null when not spoken; never a placeholder such as \"Not specified\", \"TBD\", \"N/A\" or \"Unknown\"")
        var due: String?
    }

    func toDebriefSummary() -> DebriefSummary {
        DebriefSummary(
            summary: summary,
            decisions: decisions,
            actionItems: actionItems.map { DebriefActionItem(text: $0.text, owner: $0.owner, due: $0.due) },
            openQuestions: openQuestions
        )
    }
}
#endif
