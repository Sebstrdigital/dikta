import Foundation
@testable import Dikta

@MainActor
final class FakeTextToSpeechService: TextToSpeechSpeaking {
    var voice: KokoroVoice = .af_heart
    var isSetUp = true
    var available = true
    var availability: (() async -> Bool)?
    var automaticCompletion = true
    var failure: Error?
    private(set) var texts: [String] = []
    private(set) var stopCount = 0
    private var completions: [Int: CheckedContinuation<Void, Error>] = [:]

    func checkAvailable() async -> Bool {
        if let availability { return await availability() }
        return available
    }
    func speak(_ text: String) async throws {
        let index = texts.count
        texts.append(text)
        if let failure { throw failure }
        if !automaticCompletion {
            // Deliberately ignores cancellation, to exercise stale ViewModel returns.
            try await withCheckedThrowingContinuation { completions[index] = $0 }
        }
    }
    func finish(_ index: Int, error: Error? = nil) {
        guard let completion = completions.removeValue(forKey: index) else { return }
        if let error { completion.resume(throwing: error) }
        else { completion.resume() }
    }
    func stop() { stopCount += 1 }
}
