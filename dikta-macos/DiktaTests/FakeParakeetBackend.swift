import Foundation
@testable import Dikta

/// Test double for `ParakeetBackend`. Lets `ParakeetEngineTests` exercise
/// `ParakeetEngine`'s load/transcribe logic deterministically, without
/// downloading or loading a real Parakeet model under XCTest.
final class FakeParakeetBackend: ParakeetBackend {
    /// Error `loadUltra` should throw, or nil to succeed.
    var loadError: Error?

    /// Number of Ultra load calls.
    private(set) var loadCallCount = 0

    /// Progress fractions reported via `loadUltra`, in call order.
    private(set) var reportedProgress: [Double] = []

    /// Result returned by every `transcribe` call.
    var resultToReturn = ParakeetBackendResult(text: "", wordTimings: [])

    /// `promptText` passed to each `transcribe` call, in call order.
    private(set) var receivedPromptTexts: [String?] = []

    /// Number of `transcribe` calls, for tests that assert the backend ran.
    private(set) var transcribeCallCount = 0

    /// Number of `unload` calls, for tests that assert the backend was released.
    private(set) var unloadCallCount = 0

    func loadUltra(
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        loadCallCount += 1
        progressHandler(0.5)
        reportedProgress.append(0.5)

        if let loadError {
            throw loadError
        }

        progressHandler(1.0)
        reportedProgress.append(1.0)
    }

    func transcribe(_ samples: [Float], promptText: String?) async throws -> ParakeetBackendResult {
        transcribeCallCount += 1
        receivedPromptTexts.append(promptText)
        return resultToReturn
    }

    func unload() async {
        unloadCallCount += 1
    }
}

struct FakeParakeetBackendError: Error {}
