import Foundation

/// Identifies who spoke a `LabeledSegment`. A struct rather than a plain enum
/// so a future diarization pass can mint per-speaker labels for the "Them"
/// track (`Speaker 1`, `Speaker 2`, ...) without changing the shape of
/// `LabeledSegment` itself — see decision 4b in
/// `tasks/decisions-call-debrief.md`.
struct SpeakerLabel: Codable, Equatable, Sendable {
    /// Stable identifier, e.g. for grouping/dedupe. Not shown to the user.
    var id: String
    /// User-facing label, e.g. rendered as `"<display>: <text>"` by
    /// `TwoTrackMerger.render`.
    var display: String

    /// The mic track — the app's own user.
    static let me = SpeakerLabel(id: "me", display: "Me")
    /// The system-audio track, before diarization splits it further.
    static let them = SpeakerLabel(id: "them", display: "Them")

    /// A diarized participant on the "Them" track, once diarization can tell
    /// them apart (deferred — see decision 4b).
    static func remote(_ n: Int) -> SpeakerLabel {
        SpeakerLabel(id: "remote-\(n)", display: "Speaker \(n)")
    }
}

/// A transcript segment attributed to a speaker, produced by
/// `TwoTrackMerger.merge` from the separate Me/Them `TranscriptSegment`
/// tracks.
struct LabeledSegment: Equatable, Codable, Sendable {
    var speaker: SpeakerLabel
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}
