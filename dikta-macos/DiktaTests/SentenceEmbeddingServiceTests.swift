import XCTest
@testable import Dikta

/// The MiniLM model ships inside the app as the *compiled*
/// `MiniLML12v2.mlmodelc` — Xcode compiles the source `.mlpackage` at build
/// time — so the service has to look it up under that extension. It asked
/// for `.mlpackage` from v1.2 until 2026-09-22, got nil in every built app,
/// and every caller silently fell back to Jaccard word overlap; the first
/// real two-track call debrief showed the cost as seven "decisions" that were
/// three paraphrased ideas. These tests run inside the real app bundle (the
/// test host is Dikta.app), so they catch the lookup breaking again.
final class SentenceEmbeddingServiceTests: XCTestCase {
    func test_loadModel_findsTheCompiledModelInTheAppBundle() {
        XCTAssertNoThrow(try SentenceEmbeddingService.shared.loadModel())
    }

    func test_embeddings_paraphrasedDecisionsScoreAsDuplicates() throws {
        // The exact pair that survived dedupe on 2026-09-22: Jaccard scores
        // them under the 0.75 dedupe threshold, the model must not.
        let a = "Decided to implement a more structured approach to handling releases and updates."
        let b = "Agree to establish a more structured approach to handling releases and updates."

        let vectors = try SentenceEmbeddingService.shared.embeddings(for: [a, b])
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0].count, SentenceEmbeddingService.embeddingDimension)

        let cosine = Double(SentenceEmbeddingService.cosineSimilarity(vectors[0], vectors[1]))
        XCTAssertGreaterThan(cosine, 0.75, "paraphrases that share the same idea must dedupe via embeddings")
    }

    func test_embeddingSimilarity_usesTheModelRatherThanJaccard() {
        let a = "Develop a detailed plan for hiring and onboarding the consultant."
        let b = "Develop a detailed plan for onboarding the consultant."

        let modelScore = EmbeddingSimilarity(useEmbeddings: true).similarity(a, b)
        let jaccardScore = EmbeddingSimilarity.jaccard(a, b)

        // With the model missing, `similarity` returns exactly `jaccard`.
        XCTAssertNotEqual(modelScore, jaccardScore, accuracy: 1e-9, "similarity fell back to Jaccard — is the model in the bundle?")
        XCTAssertGreaterThan(modelScore, 0.75)
    }
}
