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
        ""
    }
}
