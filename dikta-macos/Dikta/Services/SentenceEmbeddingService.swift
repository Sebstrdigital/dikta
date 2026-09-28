import CoreML
import Foundation

/// Computes 384-dimensional sentence embeddings using the bundled MiniLM-L12-v2 CoreML model.
///
/// The model accepts WordPiece-tokenised input (max 128 tokens) and outputs an L2-normalised
/// float32 vector that can be compared with cosine similarity.
///
/// Usage:
/// ```swift
/// let service = SentenceEmbeddingService.shared
/// let embeddings = try service.embeddings(for: ["Hello world", "Goodbye world"])
/// let similarity = SentenceEmbeddingService.cosineSimilarity(embeddings[0], embeddings[1])
/// ```
final class SentenceEmbeddingService {

    // MARK: - Constants

    static let maxSequenceLength = 128
    static let embeddingDimension = 384

    // MARK: - Singleton

    static let shared = SentenceEmbeddingService()

    // MARK: - Private state

    private var model: MLModel?
    private let tokenizer: WordPieceTokenizer
    private let lock = NSLock()

    // MARK: - Init

    private init() {
        guard let vocabURL = Bundle.main.url(forResource: "minilm-vocab", withExtension: "txt") else {
            fatalError("SentenceEmbeddingService: minilm-vocab.txt not found in bundle")
        }
        tokenizer = WordPieceTokenizer(vocabURL: vocabURL)
    }

    // MARK: - Public API

    /// Lazily loads the CoreML model on first call (thread-safe).
    ///
    /// - Returns: The loaded `MLModel`, or `nil` if the bundle resource is missing.
    func loadModel() throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let m = model { return m }

        // Xcode compiles the source `MiniLML12v2.mlpackage` into the bundle as
        // `MiniLML12v2.mlmodelc`, so that is the extension to look up. Asking
        // for `.mlpackage` returned nil in every built app since v1.2, and
        // every caller silently fell back to Jaccard word overlap.
        guard let modelURL = Bundle.main.url(forResource: "MiniLML12v2", withExtension: "mlmodelc") else {
            throw EmbeddingError.modelNotFound
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let loaded = try MLModel(contentsOf: modelURL, configuration: config)
        model = loaded
        return loaded
    }

    /// Compute normalised 384-dim embeddings for an array of sentences.
    ///
    /// - Parameter sentences: Input strings. Empty strings produce zero vectors.
    /// - Returns: `[[Float]]` — one 384-element vector per input sentence, L2-normalised.
    func embeddings(for sentences: [String]) throws -> [[Float]] {
        let m = try loadModel()
        return try sentences.map { sentence in
            let (ids, mask) = tokenizer.encode(sentence, maxLength: Self.maxSequenceLength)
            let input = try buildInput(ids: ids, mask: mask)
            let output = try m.prediction(from: input)
            return extractEmbedding(from: output)
        }
    }

    /// Cosine similarity between two equal-length float vectors. Returns a value in [-1, 1].
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot  += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    // MARK: - Private helpers

    private func buildInput(ids: [Int32], mask: [Int32]) throws -> MLFeatureProvider {
        let seqLen = Self.maxSequenceLength

        guard let idsArray = try? MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32),
              let maskArray = try? MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        else {
            throw EmbeddingError.inputBuildFailed
        }

        for i in 0..<seqLen {
            idsArray[i] = NSNumber(value: i < ids.count ? ids[i] : 0)
            maskArray[i] = NSNumber(value: i < mask.count ? mask[i] : 0)
        }

        return try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: idsArray),
            "attention_mask": MLFeatureValue(multiArray: maskArray),
        ])
    }

    private func extractEmbedding(from output: MLFeatureProvider) -> [Float] {
        guard let feature = output.featureValue(for: "sentence_embedding"),
              let array = feature.multiArrayValue
        else {
            return [Float](repeating: 0, count: Self.embeddingDimension)
        }
        return (0..<array.count).map { array[$0].floatValue }
    }

    // MARK: - Errors

    enum EmbeddingError: Error, LocalizedError {
        case modelNotFound
        case inputBuildFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "MiniLML12v2.mlpackage not found in app bundle"
            case .inputBuildFailed:
                return "Failed to build CoreML input arrays"
            }
        }
    }
}

// MARK: - WordPiece Tokenizer

/// Minimal WordPiece tokeniser for BERT-family models.
///
/// Covers the functionality needed by MiniLM-L12-v2:
/// - Lower-case, accent stripping, basic punctuation splitting
/// - WordPiece segmentation using the bundled vocab.txt
/// - Special tokens: [CLS]=101, [SEP]=102, [PAD]=0, [UNK]=100
final class WordPieceTokenizer {

    // MARK: - Special token IDs

    static let clsId: Int32 = 101
    static let sepId: Int32 = 102
    static let padId: Int32 = 0
    static let unkId: Int32 = 100

    // MARK: - Private state

    private let vocab: [String: Int32]

    // MARK: - Init

    init(vocabURL: URL) {
        var v: [String: Int32] = [:]
        if let content = try? String(contentsOf: vocabURL, encoding: .utf8) {
            for (index, line) in content.components(separatedBy: "\n").enumerated() {
                let token = line.trimmingCharacters(in: .whitespaces)
                guard !token.isEmpty else { continue }
                v[token] = Int32(index)
            }
        }
        vocab = v
    }

    // MARK: - Public

    /// Encode a string into (token_ids, attention_mask) with fixed length `maxLength`.
    ///
    /// Layout: [CLS] tokens... [SEP] [PAD]*
    func encode(_ text: String, maxLength: Int) -> ([Int32], [Int32]) {
        let normalised = normalise(text)
        let wordPieces = tokenise(normalised)

        // Truncate to fit [CLS] + tokens + [SEP]
        let maxContent = maxLength - 2
        let truncated = wordPieces.prefix(maxContent)

        var ids: [Int32] = [Self.clsId]
        ids += truncated.map { vocab[$0] ?? Self.unkId }
        ids.append(Self.sepId)

        var mask = [Int32](repeating: 1, count: ids.count)

        // Pad
        while ids.count < maxLength {
            ids.append(Self.padId)
            mask.append(0)
        }

        return (ids, mask)
    }

    // MARK: - Private

    private func normalise(_ text: String) -> String {
        // Lower-case + decompose accents (strip combining marks) + whitespace normalise
        let lower = text.lowercased()
        let decomposed = lower.decomposedStringWithCompatibilityMapping
        let stripped = decomposed.unicodeScalars.compactMap { scalar -> Character? in
            let cat = scalar.properties.generalCategory
            if cat == .nonspacingMark { return nil }
            return Character(scalar)
        }
        return String(stripped)
    }

    private func tokenise(_ text: String) -> [String] {
        // Split on whitespace, then apply basic punctuation splitting,
        // then WordPiece each word.
        var pieces: [String] = []
        for rawWord in text.components(separatedBy: .whitespaces) where !rawWord.isEmpty {
            let chars = splitPunctuation(rawWord)
            for word in chars {
                pieces += wordPiece(word)
            }
        }
        return pieces
    }

    private func splitPunctuation(_ text: String) -> [String] {
        // Insert spaces around punctuation, then split
        var result = ""
        for ch in text {
            if isPunctuation(ch) {
                result += " \(ch) "
            } else {
                result.append(ch)
            }
        }
        return result.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    private func isPunctuation(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let cat = scalar.properties.generalCategory
        // Unicode punctuation categories
        return [
            Unicode.GeneralCategory.otherPunctuation,
            .openPunctuation, .closePunctuation,
            .initialPunctuation, .finalPunctuation,
            .connectorPunctuation, .dashPunctuation,
            .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
        ].contains(cat)
    }

    private func wordPiece(_ word: String) -> [String] {
        guard !word.isEmpty else { return [] }
        if vocab[word] != nil { return [word] }

        let chars = Array(word)
        var pieces: [String] = []
        var start = 0
        var failed = false

        while start < chars.count {
            var end = chars.count
            var found: String?
            while start < end {
                var sub = String(chars[start..<end])
                if start > 0 { sub = "##" + sub }
                if vocab[sub] != nil {
                    found = sub
                    break
                }
                end -= 1
            }
            if let piece = found {
                pieces.append(piece)
                start = end
            } else {
                failed = true
                break
            }
        }
        return failed ? ["[UNK]"] : pieces
    }
}
