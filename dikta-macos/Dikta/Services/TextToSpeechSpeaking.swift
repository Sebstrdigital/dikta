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
    @MainActor func speak(_ text: String, request: TextToSpeechRequest, playbackStarted: @escaping () -> Void) async throws
    @MainActor func stop()
}

extension TextToSpeechSpeaking {
    @MainActor func speak(_ text: String, request: TextToSpeechRequest, playbackStarted: @escaping () -> Void) async throws {
        // Implementations without a playback event must not invent one.
        try await speak(text, request: request)
    }
}

/// Created only for a matched Read Aloud trigger, never for arbitrary key events.
struct ReadAloudTrace: Sendable {
    enum Origin: String, Sendable { case hotkey, direct }
    let id: UUID
    let triggeredAt: TimeInterval
    let origin: Origin
    init(origin: Origin, id: UUID = UUID(), triggeredAt: TimeInterval = ReadAloudTiming.now) {
        self.id = id; self.triggeredAt = triggeredAt; self.origin = origin
    }
}

struct ReadAloudTimingEvent: Sendable {
    let trace: ReadAloudTrace?
    let stage: String
    let uptime: TimeInterval
    let seconds: TimeInterval?

    var message: String {
        var fields = ["READ_ALOUD_TIMING", "request=\(trace?.id.uuidString ?? "none")",
                      "origin=\(trace?.origin.rawValue ?? "uncorrelated")", "stage=\(stage)",
                      "uptime=\(String(format: "%.6f", uptime))"]
        if let trace { fields.append("since_trigger=\(String(format: "%.6f", uptime - trace.triggeredAt))") }
        if let seconds { fields.append("seconds=\(String(format: "%.6f", seconds))") }
        return fields.joined(separator: " | ")
    }
}

/// Retains the existing stage/duration pipeline. Task-local correlation follows
/// generation/lookahead child tasks without a mutable global current request.
/// No text, key values, audio bytes, model paths or error descriptions enter it.
enum ReadAloudTiming {
    @TaskLocal static var trace: ReadAloudTrace?
    @TaskLocal static var observer: (@Sendable (ReadAloudTimingEvent) -> Void)?
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    static func event(_ stage: String, trace: ReadAloudTrace? = nil, seconds: TimeInterval? = nil) {
        let event = ReadAloudTimingEvent(trace: trace ?? Self.trace, stage: stage, uptime: now, seconds: seconds)
        observer?(event)
        // Notice/public retains this content-free schema for manual Release qualification.
        AppLogger.general.notice("\(event.message, privacy: .public)")
    }
    static func log(_ stage: String, _ seconds: TimeInterval) {
        event(stage, seconds: seconds)
    }
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
