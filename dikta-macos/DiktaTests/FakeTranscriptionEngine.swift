import Foundation
@testable import Dikta

/// Test double for `TranscriptionEngine`. Lets tests control load/reload
/// outcomes deterministically, without touching WhisperKit.
@MainActor
final class FakeTranscriptionEngine: TranscriptionEngine {
    private(set) var isLoading = false
    private(set) var isReady = false
    private(set) var errorMessage: String?
    var downloadProgress: Double?

    /// Models (by rawValue) whose `reload(model:)` should fail.
    var modelsThatFail: Set<String> = []

    /// Every model passed to `reload(model:)`, in call order.
    private(set) var reloadedModels: [WhisperModel] = []

    /// Text returned by `transcribe`. Empty by default, which is what the
    /// pre-debrief tests relied on.
    var transcriptToReturn: String = ""

    /// Artificial delay before `transcribe` returns, so timeout paths can be
    /// exercised without waiting on a real model.
    var transcribeDelay: TimeInterval = 0

    /// Number of `transcribe` calls, for tests that assert the engine ran.
    private(set) var transcribeCallCount = 0

    /// Segments returned by `transcribeSegments`. Empty by default.
    var segmentsToReturn: [TranscriptSegment] = []

    /// `promptText` passed to each `transcribeSegments` call, in call order.
    private(set) var receivedPromptTexts: [String?] = []

    func load() async {
        isReady = true
    }

    func reload(model: WhisperModel) async throws {
        reloadedModels.append(model)

        if modelsThatFail.contains(model.rawValue) {
            isReady = false
            errorMessage = "Fake failure loading \(model.rawValue)"
            throw TranscriberError.reloadFailed(errorMessage!)
        }

        isReady = true
        errorMessage = nil
    }

    func transcribe(_ audioSamples: [Float], language: String?, micSensitivity: MicSensitivity) async throws -> String {
        transcribeCallCount += 1
        if transcribeDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(transcribeDelay * 1_000_000_000))
        }
        return transcriptToReturn
    }

    func transcribeSegments(
        _ samples: [Float],
        language: String?,
        micSensitivity: MicSensitivity,
        promptText: String?
    ) async throws -> [TranscriptSegment] {
        receivedPromptTexts.append(promptText)
        return segmentsToReturn
    }
}
