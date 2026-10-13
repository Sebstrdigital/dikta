import Foundation
@testable import Dikta

@MainActor
final class FakeTextToSpeechService: TextToSpeechSpeaking {
    var voice: KokoroVoice = .af_heart
    var speed: TextToSpeechSpeed = .normal
    var isSetUp = true
    var unavailabilityMessage: String?
    var available = true
    var availability: (() async -> Bool)?
    var automaticCompletion = true
    var failure: Error?
    private(set) var texts: [String] = []
    private(set) var requests: [TextToSpeechRequest] = []
    private(set) var availabilityRequests: [TextToSpeechRequest] = []
    private(set) var stopCount = 0
    private var completions: [Int: CheckedContinuation<Void, Error>] = [:]
    private var starts: [Int: () -> Void] = [:]

    func speak(_ text: String, request: TextToSpeechRequest, playbackStarted: @escaping () -> Void) async throws {
        starts[texts.count] = playbackStarted
        try await speak(text, request: request)
    }

    func startPlayback(_ index: Int) { starts[index]?() }

    func captureRequest() -> TextToSpeechRequest { TextToSpeechRequest(voice: voice, speed: speed) }
    func checkAvailable(for request: TextToSpeechRequest) async -> Bool {
        availabilityRequests.append(request)
        if let availability { return await availability() }
        return available
    }
    func speak(_ text: String, request: TextToSpeechRequest) async throws {
        let index = texts.count
        texts.append(text)
        requests.append(request)
        if let failure { throw failure }
        if automaticCompletion { starts[index]?() }
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
