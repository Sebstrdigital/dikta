import Foundation

/// Immutable request preferences captured at the ViewModel ownership boundary.
struct TextToSpeechRequest: Equatable, Sendable {
    let voice: KokoroVoice
    let speed: TextToSpeechSpeed
    init(voice: KokoroVoice, speed: TextToSpeechSpeed = .normal) {
        self.voice = voice; self.speed = speed
    }
}

/// The Read Aloud surface; tests never construct the server-owning implementation.
protocol TextToSpeechSpeaking: AnyObject {
    @MainActor var voice: KokoroVoice { get set }
    @MainActor var speed: TextToSpeechSpeed { get set }
    @MainActor var isSetUp: Bool { get }
    @MainActor var unavailabilityMessage: String? { get }
    @MainActor func captureRequest() -> TextToSpeechRequest
    @MainActor func checkAvailable(for request: TextToSpeechRequest) async -> Bool
    @MainActor func speak(_ text: String, request: TextToSpeechRequest) async throws
    @MainActor func stop()
}

/// Safety net for the application instance that hosts XCTest.
@MainActor
final class InertTextToSpeechService: TextToSpeechSpeaking {
    var voice: KokoroVoice = .af_heart
    var speed: TextToSpeechSpeed = .normal
    var isSetUp: Bool { false }
    var unavailabilityMessage: String? { "Native Read Aloud is unavailable in the test host." }
    func captureRequest() -> TextToSpeechRequest { TextToSpeechRequest(voice: voice, speed: speed) }
    func checkAvailable(for request: TextToSpeechRequest) async -> Bool { false }
    func speak(_ text: String, request: TextToSpeechRequest) async throws {
        throw TextToSpeechService.TTSError.notAvailable(unavailabilityMessage!)
    }
    // Compatibility conveniences for direct callers/tests; production passes an
    // explicit request across the complete ViewModel lifecycle.
    func checkAvailable() async -> Bool { await checkAvailable(for: captureRequest()) }
    func speak(_ text: String) async throws { try await speak(text, request: captureRequest()) }
    func stop() {}
}
