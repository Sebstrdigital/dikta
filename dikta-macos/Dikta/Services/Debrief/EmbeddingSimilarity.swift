import Foundation

/// Supplies the `(String, String) -> Double` similarity closure
/// `DebriefAccumulator.dedupe` needs.
///
/// Two modes:
/// - embeddings — cosine similarity over `SentenceEmbeddingService`'s 384-dim
///   MiniLM vectors, the same model the formatter's paragraph splitter uses.
///   Catches a real paraphrase ("book the follow-up" / "schedule the next
///   call") that token overlap misses.
/// - `jaccard` — pure, dependency-free Jaccard over word sets.
///
/// Embedding mode FALLS BACK to `jaccard` per call rather than throwing:
/// `SentenceEmbeddingService.shared` is a lazily-loaded CoreML model whose
/// initializer `fatalError`s when `minilm-vocab.txt` is absent from the bundle
/// (SentenceEmbeddingService.swift:36). That resource ships in the app bundle
/// but not in every test/CLI host, so the singleton is only ever touched behind
/// `isEmbeddingModelAvailable`, and never at type-initialization time.
///
/// Vectors are MEMOIZED by exact text. Dedupe is quadratic in the number of
/// active items of one kind, so an item's vector would otherwise be recomputed
/// once per comparison, per chunk, for the whole meeting; with the cache each
/// distinct string is embedded once. The cache is cleared at the end of a
/// meeting (`RollingDebriefSummarizer.finish()`).
final class EmbeddingSimilarity {
    // MARK: - Pure fallback

    /// Lowercased words of 3+ characters, punctuation stripped — same token
    /// definition `DebriefSummary.isParaphrase` already uses, so the two
    /// dedupe paths in the app agree on what "a word" is.
    private static func tokens(_ text: String) -> Set<String> {
        let lowercased = text.lowercased()
        let withoutPunctuation = String(
            lowercased.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        )
        return Set(
            withoutPunctuation
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { $0.count >= 3 }
        )
    }

    /// Jaccard similarity (intersection over union) of the two word sets, in
    /// [0, 1]. Two strings with no 3+ character words score 0 rather than 1:
    /// an empty intersection over an empty union is not evidence of a duplicate.
    static func jaccard(_ a: String, _ b: String) -> Double {
        let tokensA = tokens(a)
        let tokensB = tokens(b)
        let union = tokensA.union(tokensB)
        guard !union.isEmpty else { return 0 }
        return Double(tokensA.intersection(tokensB).count) / Double(union.count)
    }

    // MARK: - Availability

    /// Whether the bundled MiniLM vocabulary is present, i.e. whether touching
    /// `SentenceEmbeddingService.shared` is safe. Checked without constructing
    /// the singleton, because its `private init` traps on a missing vocab file.
    static var isEmbeddingModelAvailable: Bool {
        Bundle.main.url(forResource: "minilm-vocab", withExtension: "txt") != nil
    }

    // MARK: - Instance

    private let useEmbeddings: Bool
    private let lock = NSLock()
    private var cache: [String: [Float]] = [:]

    /// - Parameter useEmbeddings: defaults to whether the MiniLM vocabulary is
    ///   bundled. Pass `false` for a pure-Jaccard instance (tests, CLI hosts).
    init(useEmbeddings: Bool = EmbeddingSimilarity.isEmbeddingModelAvailable) {
        self.useEmbeddings = useEmbeddings
    }

    /// Cosine similarity over memoized sentence embeddings, falling back to
    /// `jaccard` when the model is unavailable or a prediction throws.
    ///
    /// `SentenceEmbeddingService` is a plain (non-actor) class that guards its
    /// lazy model load with an `NSLock` and is otherwise stateless per call, so
    /// calling it from the summarizer's background task is safe — it is not
    /// bound to the formatter or to the main actor.
    func similarity(_ a: String, _ b: String) -> Double {
        guard useEmbeddings else { return Self.jaccard(a, b) }
        guard let vectorA = vector(for: a), let vectorB = vector(for: b) else {
            return Self.jaccard(a, b)
        }
        return Double(SentenceEmbeddingService.cosineSimilarity(vectorA, vectorB))
    }

    /// The similarity function as a closure, for injection into
    /// `DebriefAccumulator.dedupe` / `RollingDebriefSummarizer`.
    func callable() -> (String, String) -> Double {
        { [weak self] a, b in
            guard let self else { return EmbeddingSimilarity.jaccard(a, b) }
            return self.similarity(a, b)
        }
    }

    /// Drops every memoized vector. Called when a meeting ends; the strings are
    /// meeting-specific and would otherwise be held for the app's lifetime.
    func clearCache() {
        lock.lock()
        cache.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// Number of memoized vectors — for tests and diagnostics.
    var cachedVectorCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    private func vector(for text: String) -> [Float]? {
        lock.lock()
        if let cached = cache[text] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        do {
            guard let embedded = try SentenceEmbeddingService.shared.embeddings(for: [text]).first else {
                return nil
            }
            lock.lock()
            cache[text] = embedded
            lock.unlock()
            return embedded
        } catch {
            AppLogger.llm.warning(
                "EmbeddingSimilarity: embedding failed, falling back to Jaccard: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }
}
