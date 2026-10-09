import Foundation
@testable import Dikta

/// Test double for `TranscriptionEngine`. Lets tests control Ultra load and
/// transcription outcomes without touching FluidAudio.
@MainActor
final class FakeTranscriptionEngine: TranscriptionEngine {
    private(set) var isLoading = false
    private(set) var isReady = false
    private(set) var errorMessage: String?
    var downloadProgress: Double?

    /// When true, `load()` reports failure instead of succeeding.
    var shouldFailLoad = false

    /// Text returned by `transcribe`. Empty by default, which is what the
    /// pre-debrief tests relied on.
    var transcriptToReturn: String = ""

    /// Artificial delay before `transcribe` returns, so timeout paths can be
    /// exercised without waiting on a real model.
    var transcribeDelay: TimeInterval = 0

    /// Number of `transcribe` calls and legacy hints received.
    private(set) var transcribeCallCount = 0
    private(set) var receivedLanguageHints: [String?] = []

    /// Segments returned by `transcribeSegments`. Empty by default.
    var segmentsToReturn: [TranscriptSegment] = []

    /// Segments returned by successive `transcribeSegments` calls: the first
    /// call gets element 0, the second element 1, and so on. Calls past the
    /// end fall back to `segmentsToReturn`. Lets a two-track test give each
    /// track its own distinguishable transcript.
    var segmentsPerCall: [[TranscriptSegment]] = []

    /// Arguments passed to each `transcribeSegments` call, in call order.
    private(set) var receivedPromptTexts: [String?] = []
    private(set) var receivedSegmentLanguageHints: [String?] = []

    /// Awaited just before `transcribeSegments` returns, with that call's
    /// 0-based index. Lets a test hold one chunk's transcription job open for
    /// as long as it likes instead of racing a wall clock. Default `nil`: no
    /// hook, no behaviour change.
    var beforeSegmentsReturn: ((Int) async -> Void)?

    /// Sample count passed to each `transcribeSegments` call, in call order.
    private(set) var receivedSegmentSampleCounts: [Int] = []

    /// Number of `unload` calls, for tests that assert the old engine was released.
    private(set) var unloadCallCount = 0

    func load() async {
        if shouldFailLoad {
            isReady = false
            errorMessage = "Fake failure loading"
            return
        }
        isReady = true
        errorMessage = nil
    }

    func transcribe(_ audioSamples: [Float], language: String?, micSensitivity: MicSensitivity) async throws -> String {
        transcribeCallCount += 1
        receivedLanguageHints.append(language)
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
        receivedSegmentLanguageHints.append(language)
        receivedSegmentSampleCounts.append(samples.count)
        if transcribeDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(transcribeDelay * 1_000_000_000))
        }
        await beforeSegmentsReturn?(callIndex)
        guard callIndex < segmentsPerCall.count else { return segmentsToReturn }
        return segmentsPerCall[callIndex]
    }

    func unload() async {
        unloadCallCount += 1
    }
}
