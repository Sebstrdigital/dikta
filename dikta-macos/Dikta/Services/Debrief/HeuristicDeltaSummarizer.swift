import Foundation

/// No-LLM delta engine: runs the existing `HeuristicDebriefSummarizer` over
/// each chunk in isolation and reports everything it finds as NEW.
///
/// It is genuinely incapable of the other two delta operations — it has no
/// notion of the state it is being handed, so it never resolves and never
/// corrects. That is the correct degradation: the accumulator stays monotone
/// and `dedupe` removes the repetition a keyword bucketer inevitably produces
/// when the same sentence recurs across chunks.
///
/// The per-chunk summary sentence is used as the rolling summary, so the
/// paragraph at least tracks the latest chunk rather than going blank.
final class HeuristicDeltaSummarizer: DeltaSummarizing {
    let name = "Heuristic"

    private let inner: HeuristicDebriefSummarizer

    init(inner: HeuristicDebriefSummarizer = HeuristicDebriefSummarizer()) {
        self.inner = inner
    }

    func isAvailable() async -> Bool { true }

    func extractDelta(
        state: DebriefState,
        chunk: String,
        chunkIndex: Int,
        language: String
    ) async throws -> DebriefDelta {
        let summary = try await inner.summarize(transcript: chunk, language: language)

        var newItems: [DebriefDelta.NewItem] = []
        newItems += summary.decisions.map { DebriefDelta.NewItem(kind: .decision, text: $0) }
        newItems += summary.actionItems.map {
            DebriefDelta.NewItem(kind: .action, text: $0.text, owner: $0.owner, due: $0.due)
        }
        newItems += summary.openQuestions.map { DebriefDelta.NewItem(kind: .openQuestion, text: $0) }

        return DebriefDelta(summary: summary.summary, newItems: newItems)
    }

    /// Nothing to consolidate without a model: the summary paragraph is kept as
    /// it stands and no item is dropped.
    func consolidate(state: DebriefState, language: String) async throws -> ConsolidationDelta {
        ConsolidationDelta(summary: state.summary, dropIds: [])
    }
}

/// Tries a list of delta engines in order, using the first one that reports
/// itself available and whose call succeeds — the delta-mode counterpart of
/// `ChainedDebriefSummarizer`.
///
/// Availability is resolved ONCE, on the first successful call, and then
/// pinned: a meeting must not switch engines halfway through, because the ids
/// in `DebriefState` only mean anything to whichever engine has been reading
/// the numbered state all along, and a mid-meeting switch would change how the
/// summary paragraph is written from one chunk to the next.
final class ChainedDeltaSummarizer: DeltaSummarizing {
    let name = "Chained"

    private let engines: [DeltaSummarizing]
    private var pinnedEngine: DeltaSummarizing?

    /// Name of the engine that produced the most recent result, or nil before
    /// the first successful call.
    private(set) var lastUsedEngineName: String?

    /// Engine names in try order, for tests/diagnostics.
    var engineNames: [String] { engines.map(\.name) }

    init(engines: [DeltaSummarizing]) {
        self.engines = engines
    }

    func isAvailable() async -> Bool {
        for engine in engines where await engine.isAvailable() {
            return true
        }
        return false
    }

    func extractDelta(
        state: DebriefState,
        chunk: String,
        chunkIndex: Int,
        language: String
    ) async throws -> DebriefDelta {
        try await run {
            try await $0.extractDelta(state: state, chunk: chunk, chunkIndex: chunkIndex, language: language)
        }
    }

    func consolidate(state: DebriefState, language: String) async throws -> ConsolidationDelta {
        try await run { try await $0.consolidate(state: state, language: language) }
    }

    private func run<T>(_ body: (DeltaSummarizing) async throws -> T) async throws -> T {
        if let pinnedEngine {
            let result = try await body(pinnedEngine)
            lastUsedEngineName = pinnedEngine.name
            return result
        }

        var lastError: Error?
        for engine in engines {
            try Task.checkCancellation()
            guard await engine.isAvailable() else { continue }
            do {
                let result = try await body(engine)
                pinnedEngine = engine
                lastUsedEngineName = engine.name
                return result
            } catch let error as CancellationError {
                throw error
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? DebriefSummarizerError.unavailable("No delta summarizer engine is available.")
    }
}

enum DeltaSummarizerFactory {
    /// Builds a delta engine for `kind`, mirroring
    /// `DebriefSummarizerFactory.make(kind:ollamaModel:)` so the same config
    /// value selects the same engine on both the single-pass and rolling paths.
    static func make(kind: DebriefEngineKind, ollamaModel: String) -> DeltaSummarizing {
        switch kind {
        case .auto:
            var engines: [DeltaSummarizing] = []
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                engines.append(FoundationModelsDeltaSummarizer())
            }
            #endif
            engines.append(OllamaDeltaSummarizer(model: ollamaModel))
            engines.append(HeuristicDeltaSummarizer())
            return ChainedDeltaSummarizer(engines: engines)
        case .foundationModels:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                return FoundationModelsDeltaSummarizer()
            }
            #endif
            return HeuristicDeltaSummarizer()
        case .ollama:
            return OllamaDeltaSummarizer(model: ollamaModel)
        case .heuristic:
            return HeuristicDeltaSummarizer()
        }
    }
}
