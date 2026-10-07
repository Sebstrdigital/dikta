import Foundation

/// The Read Aloud surface; tests never construct the server-owning implementation.
protocol TextToSpeechSpeaking: AnyObject {
    @MainActor var voice: KokoroVoice { get set }
    @MainActor var isSetUp: Bool { get }
    @MainActor func checkAvailable() async -> Bool
    @MainActor func speak(_ text: String) async throws
    @MainActor func stop()
}

/// Safety net for the application instance that hosts XCTest.
@MainActor
final class InertTextToSpeechService: TextToSpeechSpeaking {
    var voice: KokoroVoice = .af_heart
    var isSetUp: Bool { false }
    func checkAvailable() async -> Bool { false }
    func speak(_ text: String) async throws { throw TextToSpeechService.TTSError.serverNotRunning }
    func stop() {}
}
