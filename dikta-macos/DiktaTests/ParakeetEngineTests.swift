import XCTest
@testable import Dikta

/// Unit coverage for the fixed Ultra engine. The injected backend guarantees
/// these tests never load or download a real FluidAudio model.
@MainActor
final class ParakeetEngineTests: XCTestCase {
    func test_load_refusesWhenFreeSpaceBelowTwiceUltraSize() async {
        let backend = FakeParakeetBackend()
        let engine = ParakeetEngine(backend: backend, freeDiskSpaceProvider: { 1_000 })
        await engine.load()
        XCTAssertFalse(engine.isReady)
        XCTAssertEqual(backend.loadCallCount, 0)
        XCTAssertTrue(engine.errorMessage?.contains("disk space") == true)
    }

    func test_load_succeedsAndResetsProgress() async {
        let backend = FakeParakeetBackend()
        let engine = ParakeetEngine(backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()
        XCTAssertTrue(engine.isReady)
        XCTAssertNil(engine.errorMessage)
        XCTAssertNil(engine.downloadProgress)
        XCTAssertEqual(backend.loadCallCount, 1)
    }

    func test_load_failedBackendLeavesEngineNotReady() async {
        let backend = FakeParakeetBackend()
        backend.loadError = FakeParakeetBackendError()
        let engine = ParakeetEngine(backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()
        XCTAssertFalse(engine.isReady)
        XCTAssertNotNil(engine.errorMessage)
        XCTAssertNil(engine.downloadProgress)
    }

    func test_unloadReleasesBackendAndReadiness() async {
        let backend = FakeParakeetBackend()
        let engine = ParakeetEngine(backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()
        await engine.unload()
        XCTAssertFalse(engine.isReady)
        XCTAssertEqual(backend.unloadCallCount, 1)
    }

    func test_transcribe_returnsCleanedTextAndIgnoresLegacyHint() async throws {
        let backend = FakeParakeetBackend()
        backend.resultToReturn = ParakeetBackendResult(text: "<|en|>Hello there<|endoftext|>", wordTimings: [])
        let engine = ParakeetEngine(backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()
        let text = try await engine.transcribe([0.1], language: "sv", micSensitivity: .normal)
        XCTAssertEqual(text, "Hello there")
    }

    func test_transcribe_throwsWhenNotReady() async {
        let engine = ParakeetEngine(backend: FakeParakeetBackend(), freeDiskSpaceProvider: { .max })
        do {
            _ = try await engine.transcribe([0.1], language: nil, micSensitivity: .normal)
            XCTFail("expected modelNotLoaded")
        } catch { XCTAssertTrue(error is ParakeetEngineError) }
    }

    func test_transcribe_throwsForEmptyAudio() async {
        let engine = ParakeetEngine(backend: FakeParakeetBackend(), freeDiskSpaceProvider: { .max })
        await engine.load()
        do {
            _ = try await engine.transcribe([], language: nil, micSensitivity: .normal)
            XCTFail("expected emptyAudio")
        } catch { XCTAssertTrue(error is ParakeetEngineError) }
    }

    func test_transcribe_throwsWhenCleanupLeavesNoSpeech() async {
        let backend = FakeParakeetBackend()
        backend.resultToReturn = ParakeetBackendResult(text: "[BLANK_AUDIO]", wordTimings: [])
        let engine = ParakeetEngine(backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()
        do {
            _ = try await engine.transcribe([0], language: nil, micSensitivity: .normal)
            XCTFail("expected noSpeechDetected")
        } catch { XCTAssertTrue(error is ParakeetEngineError) }
    }

    func test_transcribeSegments_sortsAndSanitizesTimings() async throws {
        let backend = FakeParakeetBackend()
        backend.resultToReturn = ParakeetBackendResult(text: "", wordTimings: [
            ParakeetWordTiming(word: "third", start: 4, end: 4.5),
            ParakeetWordTiming(word: "[silence]", start: 1, end: 1.5),
            ParakeetWordTiming(word: "first", start: 0, end: 0.5)
        ])
        let engine = ParakeetEngine(backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()
        let segments = try await engine.transcribeSegments([Float](repeating: 0, count: 16_000), language: nil, micSensitivity: .normal, promptText: nil)
        XCTAssertEqual(segments.map(\.text), ["first", "third"])
        XCTAssertTrue(zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start })
    }

    func test_transcribeSegments_acceptsPromptForProtocolParity() async throws {
        let backend = FakeParakeetBackend()
        backend.resultToReturn = ParakeetBackendResult(text: "continued", wordTimings: [])
        let engine = ParakeetEngine(backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()
        _ = try await engine.transcribeSegments([Float](repeating: 0, count: 16_000), language: nil, micSensitivity: .normal, promptText: "tail")
        XCTAssertEqual(backend.receivedPromptTexts, ["tail"])
    }

    func test_transcribeSegments_fallsBackToChunkSpanWithoutTimings() async throws {
        let backend = FakeParakeetBackend()
        backend.resultToReturn = ParakeetBackendResult(text: "whole chunk", wordTimings: [])
        let engine = ParakeetEngine(backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()
        let result = try await engine.transcribeSegments([Float](repeating: 0, count: 32_000), language: nil, micSensitivity: .normal, promptText: nil)
        XCTAssertEqual(result, [TranscriptSegment(start: 0, end: 2, text: "whole chunk")])
    }
}
