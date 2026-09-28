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
///
/// They only make sense with that host: under `swift test` there is no app
/// bundle, `Bundle.main` is the test runner, and `SentenceEmbeddingService`'s
/// initializer `fatalError`s on the missing vocabulary before any assertion
/// can run — which took the whole SPM test process down in CI on
/// 2026-09-28. So the class skips itself when the vocabulary is not in
/// `Bundle.main` rather than touching the singleton.
final class SentenceEmbeddingServiceTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard Bundle.main.url(forResource: "minilm-vocab", withExtension: "txt") != nil else {
            throw XCTSkip("needs the Dikta.app test host: minilm-vocab.txt is not in Bundle.main (e.g. under `swift test`)")
        }
    }

    func test_loadModel_findsTheCompiledModelInTheAppBundle() {
        XCTAssertNoThrow(try SentenceEmbeddingService.shared.loadModel())
    }

    /// The two similarity tests below need the model to actually compute
    /// something. On GitHub's virtualised macOS runners the compiled MiniLM
    /// model loads and runs but returns all-zero vectors (observed
    /// 2026-09-28: cosine exactly 0.0 for both pairs, while the lookup test
    /// above passes), so they are skipped there. They run on real hardware,
    /// which is where the regression they guard was found.
    private func skipUnlessModelProducesVectors() throws {
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil {
            throw XCTSkip("MiniLM returns zero vectors on GitHub's virtual macOS runners; run on real hardware")
        }
    }

    func test_embeddings_paraphrasedDecisionsScoreAsDuplicates() throws {
        try skipUnlessModelProducesVectors()
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

    func test_embeddingSimilarity_usesTheModelRatherThanJaccard() throws {
        try skipUnlessModelProducesVectors()
        let a = "Develop a detailed plan for hiring and onboarding the consultant."
        let b = "Develop a detailed plan for onboarding the consultant."

        let modelScore = EmbeddingSimilarity(useEmbeddings: true).similarity(a, b)
        let jaccardScore = EmbeddingSimilarity.jaccard(a, b)

        // With the model missing, `similarity` returns exactly `jaccard`.
        XCTAssertNotEqual(modelScore, jaccardScore, accuracy: 1e-9, "similarity fell back to Jaccard — is the model in the bundle?")
        XCTAssertGreaterThan(modelScore, 0.75)
    }
}
