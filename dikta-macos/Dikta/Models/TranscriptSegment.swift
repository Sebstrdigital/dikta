import Foundation

/// A transcribed segment with timestamps relative to the start of the audio
/// samples passed to `TranscriptionEngine.transcribeSegments`.
///
/// Used to interleave Me/Them tracks in call-debrief mode and to dedupe
/// overlapping chunks by time (see `tasks/decisions-call-debrief.md`,
/// decision 4 and the "Chunk boundary rule").
struct TranscriptSegment: Equatable, Codable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}
