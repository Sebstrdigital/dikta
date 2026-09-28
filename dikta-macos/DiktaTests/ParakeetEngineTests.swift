/// ParakeetEngineTests — Unit tests for `ParakeetEngine` via `@testable import Dikta`,
/// using `FakeParakeetBackend` so no real Parakeet model is downloaded or loaded.
///
/// Run via: cd dikta-macos && swift test --filter ParakeetEngineTests

import CoreML
import XCTest
@testable import Dikta

@MainActor
final class ParakeetEngineTests: XCTestCase {

    // MARK: - Disk-space guard

    /// Mirrors `TranscriberDiskSpaceTests.test_load_refusesWhenFreeSpaceBelowTwiceModelSize`:
    /// proves `ParakeetEngine` refuses to start a download when the injected free-space
    /// provider reports too little free space, without ever reaching the fake backend's
    /// `loadModel`.
    func test_load_refusesWhenFreeSpaceBelowTwiceVariantSize() async {
        let backend = FakeParakeetBackend()
        let engine = ParakeetEngine(kind: .parakeetRedux, backend: backend, freeDiskSpaceProvider: { 1_000 })

        await engine.load()

        XCTAssertFalse(engine.isReady)
        XCTAssertNil(engine.downloadProgress)
        XCTAssertNil(backend.loadedKind, "disk guard should short-circuit before the backend is ever asked to load")
        let message = try? XCTUnwrap(engine.errorMessage)
        XCTAssertTrue(message?.contains("disk space") ?? false, "expected a disk-space error, got: \(engine.errorMessage ?? "nil")")
    }

    func test_load_succeedsWhenFreeSpaceAtLeastTwiceVariantSize() async {
        let backend = FakeParakeetBackend()
        let engine = ParakeetEngine(kind: .parakeetV3, backend: backend, freeDiskSpaceProvider: { .max })

        await engine.load()

        XCTAssertTrue(engine.isReady)
        XCTAssertNil(engine.errorMessage)
        XCTAssertNil(engine.downloadProgress, "downloadProgress resets to nil once loading finishes")
        XCTAssertEqual(backend.loadedKind, .parakeetV3)
    }

    /// `.parakeetRedux` loads with `.cpuAndGPU`; the other kinds pass `nil` through
    /// (platform default).
    func test_load_usesGPUEncoderComputeUnitsForReduxOnly() async {
        let reduxBackend = FakeParakeetBackend()
        let reduxEngine = ParakeetEngine(kind: .parakeetRedux, backend: reduxBackend, freeDiskSpaceProvider: { .max })
        await reduxEngine.load()
        XCTAssertEqual(reduxBackend.loadedEncoderComputeUnits, .cpuAndGPU)

        let v3Backend = FakeParakeetBackend()
        let v3Engine = ParakeetEngine(kind: .parakeetV3, backend: v3Backend, freeDiskSpaceProvider: { .max })
        await v3Engine.load()
        XCTAssertNil(v3Backend.loadedEncoderComputeUnits)
    }

    func test_load_failedBackendLoadSetsErrorMessageAndLeavesNotReady() async {
        let backend = FakeParakeetBackend()
        backend.loadError = FakeParakeetBackendError()
        let engine = ParakeetEngine(kind: .parakeetUltra, backend: backend, freeDiskSpaceProvider: { .max })

        await engine.load()

        XCTAssertFalse(engine.isReady)
        XCTAssertNotNil(engine.errorMessage)
        XCTAssertNil(engine.downloadProgress)
    }

    // MARK: - reload(model:) no-op

    func test_reload_isNoOp_keepsIsReadyTrueAfterSuccessfulLoad() async throws {
        let backend = FakeParakeetBackend()
        let engine = ParakeetEngine(kind: .parakeetV3, backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()
        XCTAssertTrue(engine.isReady)

        try await engine.reload(model: .turbo)

        XCTAssertTrue(engine.isReady)
    }

    func test_reload_isNoOp_keepsIsReadyFalseBeforeAnyLoad() async throws {
        let backend = FakeParakeetBackend()
        let engine = ParakeetEngine(kind: .parakeetV3, backend: backend, freeDiskSpaceProvider: { .max })

        try await engine.reload(model: .turbo)

        XCTAssertFalse(engine.isReady)
    }

    // MARK: - transcribe

    func test_transcribe_returnsCleanedText() async throws {
        let backend = FakeParakeetBackend()
        backend.resultToReturn = ParakeetBackendResult(
            text: "<|startoftranscript|>Hello there<|endoftext|>",
            wordTimings: []
        )
        let engine = ParakeetEngine(kind: .parakeetV3, backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()

        let text = try await engine.transcribe([0.1, 0.2], language: "sv", micSensitivity: .normal)

        XCTAssertEqual(text, "Hello there", "language hint must be ignored, not just accepted")
    }

    func test_transcribe_throwsWhenNotReady() async {
        let backend = FakeParakeetBackend()
        let engine = ParakeetEngine(kind: .parakeetV3, backend: backend, freeDiskSpaceProvider: { .max })

        do {
            _ = try await engine.transcribe([0.1], language: nil, micSensitivity: .normal)
            XCTFail("expected modelNotLoaded to be thrown")
        } catch {
            XCTAssertTrue(error is ParakeetEngineError)
        }
    }

    // MARK: - transcribeSegments

    /// Feeds the fake backend word timings out of order and proves `ParakeetEngine`
    /// still returns segments sorted with non-decreasing `start`, reusing
    /// `Transcriber.sortMonotonic` the same way `Transcriber.transcribeSegments` does.
    func test_transcribeSegments_sortsOutOfOrderTimingsMonotonically() async throws {
        let backend = FakeParakeetBackend()
        backend.resultToReturn = ParakeetBackendResult(
            text: "third first second",
            wordTimings: [
                ParakeetWordTiming(word: "third", start: 4.0, end: 4.5),
                ParakeetWordTiming(word: "first", start: 0.0, end: 0.5),
                ParakeetWordTiming(word: "second", start: 2.0, end: 2.5),
            ]
        )
        let engine = ParakeetEngine(kind: .parakeetV3, backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()

        let segments = try await engine.transcribeSegments([Float](repeating: 0, count: 16_000), language: nil, micSensitivity: .normal, promptText: nil)

        XCTAssertEqual(segments.map(\.text), ["first", "second", "third"])
        XCTAssertTrue(
            zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start },
            "segments must be monotonic non-decreasing by start"
        )
    }

    /// `promptText` is accepted without error and reaches the backend, even though
    /// FluidAudio's Parakeet decoder has no textual prompt input of its own.
    func test_transcribeSegments_acceptsPromptTextWithoutError() async throws {
        let backend = FakeParakeetBackend()
        backend.resultToReturn = ParakeetBackendResult(text: "continued", wordTimings: [])
        let engine = ParakeetEngine(kind: .parakeetV3, backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()

        let segments = try await engine.transcribeSegments(
            [Float](repeating: 0, count: 16_000),
            language: nil,
            micSensitivity: .normal,
            promptText: "previous chunk tail"
        )

        XCTAssertEqual(backend.receivedPromptTexts, ["previous chunk tail"])
        XCTAssertEqual(segments.map(\.text), ["continued"])
    }

    /// When the backend reports no per-token timings (see `ParakeetBackendResult
    /// .wordTimings`), `transcribeSegments` falls back to one segment spanning the
    /// whole chunk rather than throwing or dropping the transcript.
    func test_transcribeSegments_fallsBackToSingleSegmentWhenNoWordTimings() async throws {
        let backend = FakeParakeetBackend()
        backend.resultToReturn = ParakeetBackendResult(text: "whole chunk text", wordTimings: [])
        let engine = ParakeetEngine(kind: .parakeetV3, backend: backend, freeDiskSpaceProvider: { .max })
        await engine.load()

        let samples = [Float](repeating: 0, count: 32_000) // 2s @ 16kHz
        let segments = try await engine.transcribeSegments(samples, language: nil, micSensitivity: .normal, promptText: nil)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.text, "whole chunk text")
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(try XCTUnwrap(segments.first?.end), 2.0, accuracy: 0.001)
    }

    func test_transcribeSegments_throwsWhenNotReady() async {
        let backend = FakeParakeetBackend()
        let engine = ParakeetEngine(kind: .parakeetV3, backend: backend, freeDiskSpaceProvider: { .max })

        do {
            _ = try await engine.transcribeSegments([0.1], language: nil, micSensitivity: .normal, promptText: nil)
            XCTFail("expected modelNotLoaded to be thrown")
        } catch {
            XCTAssertTrue(error is ParakeetEngineError)
        }
    }
}
