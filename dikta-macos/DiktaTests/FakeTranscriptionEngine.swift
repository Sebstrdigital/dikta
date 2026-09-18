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

    /// Segments returned by successive `transcribeSegments` calls: the first
    /// call gets element 0, the second element 1, and so on. Calls past the
    /// end fall back to `segmentsToReturn`. Lets a two-track test give each
    /// track its own distinguishable transcript.
    var segmentsPerCall: [[TranscriptSegment]] = []

    /// `promptText` passed to each `transcribeSegments` call, in call order.
    private(set) var receivedPromptTexts: [String?] = []

    /// Awaited just before `transcribeSegments` returns, with that call's
    /// 0-based index. Lets a test hold one chunk's transcription job open for
    /// as long as it likes instead of racing a wall clock. Default `nil`: no
    /// hook, no behaviour change.
    var beforeSegmentsReturn: ((Int) async -> Void)?

    /// Sample count passed to each `transcribeSegments` call, in call order.
    private(set) var receivedSegmentSampleCounts: [Int] = []

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
        let callIndex = receivedPromptTexts.count
        receivedPromptTexts.append(promptText)
        receivedSegmentSampleCounts.append(samples.count)
        if transcribeDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(transcribeDelay * 1_000_000_000))
        }
        await beforeSegmentsReturn?(callIndex)
        guard callIndex < segmentsPerCall.count else { return segmentsToReturn }
        return segmentsPerCall[callIndex]
    }
}
