import Foundation
@testable import Dikta

/// Deterministic fake used to test summarizer wiring (chaining, the pipeline,
/// the ViewModel) without touching Ollama or Foundation Models. Tracks call
/// counts so tests can assert an engine was — or wasn't — touched at all.
final class FakeDebriefSummarizer: DebriefSummarizer {
    let name: String
    let available: Bool
    let result: Result<DebriefSummary, Error>

    private(set) var isAvailableCallCount = 0
    private(set) var summarizeCallCount = 0
    /// Every (transcript, language) pair passed to `summarize`, in call order.
    private(set) var summarizeCalls: [(transcript: String, language: String)] = []

    init(name: String, available: Bool, result: Result<DebriefSummary, Error>) {
        self.name = name
        self.available = available
        self.result = result
    }

    func isAvailable() async -> Bool {
        isAvailableCallCount += 1
        return available
    }

    func summarize(transcript: String, language: String) async throws -> DebriefSummary {
        summarizeCallCount += 1
        summarizeCalls.append((transcript: transcript, language: language))
        return try result.get()
    }
}
