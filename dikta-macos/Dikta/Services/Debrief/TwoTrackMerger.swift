import Foundation

/// Merges the mic ("Me") and system-audio ("Them") transcript tracks from a
/// call debrief into one speaker-labeled timeline, and renders that timeline
/// back to plain text for the summarizer.
///
/// See decision 4/4b in `tasks/decisions-call-debrief.md`: mic = Me, system
/// audio = Them, and the transcript model carries a speaker per segment from
/// day one so a future diarization pass can split "Them" into
/// `SpeakerLabel.remote(1...N)` without reshaping this merger's output.
enum TwoTrackMerger {
    /// Merges `me` and `them` into one timeline, sorted by `start`. Ties
    /// (equal `start`) keep Me before Them. No segment is dropped, and
    /// overlapping segments are kept as-is in start order — this merger
    /// never splits a segment.
    ///
    /// Swift's `sorted(by:)` has been stable since Swift 5, so segments with
    /// equal `start` keep their relative order from `combined` below, where
    /// every Me segment is placed before every Them segment. That's what
    /// gives the Me-first tie-break, with no explicit speaker check needed.
    static func merge(me: [TranscriptSegment], them: [TranscriptSegment]) -> [LabeledSegment] {
        let combined =
            me.map { LabeledSegment(speaker: .me, start: $0.start, end: $0.end, text: $0.text) }
            + them.map { LabeledSegment(speaker: .them, start: $0.start, end: $0.end, text: $0.text) }
        return combined.sorted { $0.start < $1.start }
    }

    /// Renders `segments` as plain text: consecutive segments from the same
    /// speaker join into one paragraph (`"Me: text text"` / `"Them: text"`),
    /// paragraphs are separated by a blank line, and each segment's text has
    /// its whitespace normalized (trimmed, internal runs collapsed to a
    /// single space) before joining. Empty input renders as `""`.
    static func render(_ segments: [LabeledSegment]) -> String {
        var paragraphs: [String] = []
        var currentSpeaker: SpeakerLabel?
        var currentParts: [String] = []

        func flushCurrentParagraph() {
            guard let speaker = currentSpeaker else { return }
            paragraphs.append("\(speaker.display): \(currentParts.joined(separator: " "))")
            currentParts.removeAll()
        }

        for segment in segments {
            if segment.speaker != currentSpeaker {
                flushCurrentParagraph()
                currentSpeaker = segment.speaker
            }
            let normalized = normalizedWhitespace(segment.text)
            if !normalized.isEmpty {
                currentParts.append(normalized)
            }
        }
        flushCurrentParagraph()

        return paragraphs.joined(separator: "\n\n")
    }

    /// Whether `text` looks like a Me/Them-labeled transcript, i.e. at least
    /// one line starts with `"Me:"` or `"Them:"` (after trimming leading
    /// whitespace). Used by the summarizer to switch between labeled and
    /// unlabeled prompt rules.
    static func isLabeledTranscript(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("Me:") || trimmed.hasPrefix("Them:")
        }
    }

    /// Trims `text` and collapses any run of whitespace (including
    /// newlines, since a segment's text may itself be multi-line) to a
    /// single space.
    private static func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
