#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Delta engine backed by Apple's on-device Foundation Models, using
/// structured (`@Generable`) output so no JSON parsing step is needed.
///
/// Mirrors `FoundationModelsDebriefSummarizer`'s CI-safety shape exactly: no
/// stored property and no member signature mentions a FoundationModels type.
/// A stored `GenerationOptions` makes the class layout depend on that
/// framework's metadata at load time, which crashed the SPM test bundle
/// (signal 11) on a macOS 15 CI runner where the framework does not exist. The
/// sampling choice is a plain enum; the options value is built per call inside
/// an availability-guarded method.
@available(macOS 26.0, *)
final class FoundationModelsDeltaSummarizer: DeltaSummarizing {
    let name = "FoundationModels"

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

    func extractDelta(
        state: DebriefState,
        chunk: String,
        chunkIndex: Int,
        language: String
    ) async throws -> DebriefDelta {
        let trimmedChunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChunk.isEmpty else {
            throw DebriefSummarizerError.emptyTranscript
        }

        let session = LanguageModelSession(instructions: DeltaPromptBuilder.deltaSystemPrompt(language: language))
        let userPrompt = DeltaPromptBuilder.deltaUserPrompt(
            state: state,
            chunk: trimmedChunk,
            chunkIndex: chunkIndex,
            language: language
        )

        do {
            let response = try await session.respond(
                to: userPrompt,
                generating: DebriefDeltaGenerable.self,
                options: generationOptions
            )
            return response.content.toDebriefDelta()
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapped(error)
        }
    }

    func consolidate(state: DebriefState, language: String) async throws -> ConsolidationDelta {
        let session = LanguageModelSession(
            instructions: DeltaPromptBuilder.consolidationSystemPrompt(language: language)
        )
        let userPrompt = DeltaPromptBuilder.consolidationUserPrompt(state: state, language: language)

        do {
            let response = try await session.respond(
                to: userPrompt,
                generating: ConsolidationDeltaGenerable.self,
                options: generationOptions
            )
            return response.content.toConsolidationDelta()
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapped(error)
        }
    }

    /// Translates the framework's generation errors into the two the rolling
    /// summarizer knows how to act on. `exceededContextWindowSize` is the one
    /// a long meeting actually hits: the numbered state grows every chunk, so
    /// `RollingDebriefSummarizer.ingest` needs to tell it apart from a generic
    /// failure in order to retry smaller instead of giving up on the chunk.
    private static func mapped(_ error: LanguageModelSession.GenerationError) -> Error {
        switch error {
        case .exceededContextWindowSize:
            return DeltaSummarizerError.contextWindowExceeded(error.localizedDescription)
        case .assetsUnavailable:
            return DebriefSummarizerError.unavailable(error.localizedDescription)
        default:
            return error
        }
    }
}

// MARK: - Schemas

/// `@Generable` mirror of `DebriefDelta`.
///
/// As in `DebriefSummaryGenerable`, every `@Guide` description is deliberately
/// LANGUAGE-NEUTRAL: a `@Guide` string is one static attribute shared by every
/// call regardless of transcript language, so a concrete English or Swedish
/// example living here risks being copied into the wrong-language output. All
/// per-language examples stay in `DeltaPromptBuilder`'s prompt text.
@available(macOS 26.0, *)
@Generable
struct DebriefDeltaGenerable {
    @Guide(description: "An updated 2 to 5 sentence FIRST-PERSON summary of the WHOLE meeting so far, incorporating this new chunk, in the transcript's own language. Unlike every field below, this one is fully regenerated each time rather than being a delta.")
    var summary: String

    @Guide(description: "Decisions genuinely NEW in this chunk. Never restate a decision already in the numbered list you were given, even worded differently, and never combine two existing items into one. Empty array if none.")
    var newDecisions: [String]

    @Guide(description: "Action items genuinely NEW in this chunk. Never restate one already in the numbered list, and never combine two existing items into one. Empty array if none.")
    var newActionItems: [DeltaActionItemGenerable]

    @Guide(description: "Open questions genuinely NEW in this chunk. Never restate one already in the numbered list. Empty array if none.")
    var newOpenQuestions: [String]

    @Guide(description: "The numeric ids, from the numbered list you were given, of existing items THIS chunk explicitly resolves, completes, answers, or makes obsolete. Do NOT include an id merely because this chunk does not repeat it. Never invent an id that was not in the list. Empty array if none.")
    var resolvedIds: [Int]

    @Guide(description: "Corrections to an existing numbered item, only when this chunk shows its wording, owner, or due was wrong or incomplete. Most items need no correction — leave this empty unless one is clearly warranted.")
    var corrections: [DeltaCorrectionGenerable]

    @available(macOS 26.0, *)
    @Generable
    struct DeltaActionItemGenerable {
        @Guide(description: "The task to do, written in the transcript's own language")
        var text: String

        @Guide(description: "The GRAMMATICAL SUBJECT of this task as spoken: the user's own first-person self-reference means the user (use their own stated name if given, otherwise the transcript's own first-person word for it); a participant named as the subject means that person. Never assign the user's own task to someone else. Null when no person is actually named or self-referenced; never a generic group, never a stand-in for an unnamed participant, and never a placeholder such as \"Not specified\", \"TBD\", \"N/A\" or \"Unknown\"")
        var owner: String?

        @Guide(description: "The deadline for THIS specific task, copied VERBATIM exactly as spoken, in the transcript's own language only; NEVER convert to a calendar date, NEVER add or invent a year, NEVER add a weekday name unless it was said; do not reuse an unrelated date mentioned elsewhere; null when not spoken; never a placeholder such as \"Not specified\", \"TBD\", \"N/A\" or \"Unknown\"")
        var due: String?
    }

    @available(macOS 26.0, *)
    @Generable
    struct DeltaCorrectionGenerable {
        @Guide(description: "The id, from the numbered list you were given, of the existing item being corrected")
        var id: Int

        @Guide(description: "The corrected replacement text for that item, in the same language as the rest of your output")
        var text: String

        @Guide(description: "A corrected owner for that item, only if this chunk shows the existing owner was wrong or names one that was missing. Leave it null to KEEP the item's existing owner; use the exact string \"null\" to CLEAR an existing owner that turned out to be wrong")
        var owner: String?

        @Guide(description: "A corrected due for that item, copied verbatim as spoken, only if this chunk shows the existing due was wrong or names one that was missing. Leave it null to KEEP the item's existing due; use the exact string \"null\" to CLEAR an existing due that turned out to be wrong")
        var due: String?
    }

    func toDebriefDelta() -> DebriefDelta {
        var newItems: [DebriefDelta.NewItem] = []
        newItems += newDecisions.map { DebriefDelta.NewItem(kind: .decision, text: $0) }
        newItems += newActionItems.map {
            DebriefDelta.NewItem(kind: .action, text: $0.text, owner: $0.owner, due: $0.due)
        }
        newItems += newOpenQuestions.map { DebriefDelta.NewItem(kind: .openQuestion, text: $0) }

        return DebriefDelta(
            summary: summary,
            newItems: newItems,
            resolvedIds: resolvedIds,
            corrections: corrections.map {
                DebriefDelta.Correction(id: $0.id, text: $0.text, owner: $0.owner, due: $0.due)
            }
        )
    }
}

/// `@Generable` mirror of `ConsolidationDelta`. Note the absence of any merge
/// vocabulary: model-proposed merges were the spike's worst result (unrelated
/// items paired, real duplicates split), so the schema cannot express one.
@available(macOS 26.0, *)
@Generable
struct ConsolidationDeltaGenerable {
    @Guide(description: "A fresh 2 to 5 sentence FIRST-PERSON summary of the whole meeting, in the transcript's own language.")
    var summary: String

    @Guide(description: "Ids, from the numbered list you were given, that are not real items at all — a stray transcription fragment, or something with no content left to act on — each with a short reason. Every id NOT listed here is kept exactly as it is. Do not list an id just to shorten the list, and never invent an id that was not in the list. Empty array if nothing should be dropped.")
    var dropIds: [ConsolidationDropGenerable]

    @available(macOS 26.0, *)
    @Generable
    struct ConsolidationDropGenerable {
        @Guide(description: "The id, from the numbered list you were given, of the item to drop")
        var id: Int

        @Guide(description: "A short reason why this is not a real item")
        var reason: String
    }

    func toConsolidationDelta() -> ConsolidationDelta {
        ConsolidationDelta(
            summary: summary,
            dropIds: dropIds.map { ConsolidationDelta.Drop(id: $0.id, reason: $0.reason) }
        )
    }
}
#endif
