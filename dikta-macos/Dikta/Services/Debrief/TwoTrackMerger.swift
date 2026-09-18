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
    /// (equal `start`) keep Me before Them, and a further tie within the
    /// same track keeps its original order. No segment is dropped, and
    /// overlapping segments are kept as-is in start order — this merger
    /// never splits a segment.
    ///
    /// The tie-break is explicit (start, then Me-before-Them, then original
    /// index within its own track) rather than relying on `sorted(by:)`
    /// being a stable sort, so the ordering can't silently change if a
    /// future edit swaps in an unstable sort or reorders `combined`.
    static func merge(me: [TranscriptSegment], them: [TranscriptSegment]) -> [LabeledSegment] {
        struct Candidate {
            let segment: LabeledSegment
            /// 0 for Me, 1 for Them — lower sorts first on a start tie.
            let speakerRank: Int
            /// Original position within `me`/`them`, for a same-track tie.
            let index: Int
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(me.count + them.count)
        for (index, segment) in me.enumerated() {
            candidates.append(Candidate(
                segment: LabeledSegment(speaker: .me, start: segment.start, end: segment.end, text: segment.text),
                speakerRank: 0,
                index: index
            ))
        }
        for (index, segment) in them.enumerated() {
            candidates.append(Candidate(
                segment: LabeledSegment(speaker: .them, start: segment.start, end: segment.end, text: segment.text),
                speakerRank: 1,
                index: index
            ))
        }

        candidates.sort { lhs, rhs in
            if lhs.segment.start != rhs.segment.start {
                return lhs.segment.start < rhs.segment.start
            }
            if lhs.speakerRank != rhs.speakerRank {
                return lhs.speakerRank < rhs.speakerRank
            }
            return lhs.index < rhs.index
        }

        return candidates.map(\.segment)
    }

    /// Renders `segments` as plain text: consecutive segments from the same
    /// speaker join into one paragraph (`"Me: text text"` / `"Them: text"`),
    /// paragraphs are separated by a blank line, and each segment's text has
    /// its whitespace normalized (trimmed, internal runs collapsed to a
    /// single space) before joining. Empty input renders as `""`.
    ///
    /// A segment whose text is empty/whitespace-only is dropped *before*
    /// grouping by speaker, not just skipped while building a paragraph's
    /// text — otherwise it could either leave a dangling `"Them: "`
    /// paragraph with no text (if every segment in that speaker turn is
    /// empty) or force an unwanted paragraph split (e.g. Me/empty-Them/Me
    /// would otherwise render as two separate Me paragraphs instead of one).
    static func render(_ segments: [LabeledSegment]) -> String {
        let nonEmptySegments: [(speaker: SpeakerLabel, text: String)] = segments.compactMap { segment in
            let normalized = normalizedWhitespace(segment.text)
            guard !normalized.isEmpty else { return nil }
            return (segment.speaker, normalized)
        }

        var paragraphs: [String] = []
        var currentSpeaker: SpeakerLabel?
        var currentParts: [String] = []

        func flushCurrentParagraph() {
            guard let speaker = currentSpeaker, !currentParts.isEmpty else { return }
            paragraphs.append("\(speaker.display): \(currentParts.joined(separator: " "))")
            currentParts.removeAll()
        }

        for (speaker, text) in nonEmptySegments {
            if speaker != currentSpeaker {
                flushCurrentParagraph()
                currentSpeaker = speaker
            }
            currentParts.append(text)
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

    /// Removes the leading `"Me: "`/`"Them: "` label from each paragraph of
    /// a `render`-produced transcript, keeping the paragraph breaks (blank
    /// lines) intact. Used by `HeuristicDebriefSummarizer`, which has no
    /// notion of speakers and would otherwise bucket the literal label text
    /// into its output (e.g. an action item starting with `"Them: "`).
    static func stripLabels(_ text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map { paragraph -> String in
                if paragraph.hasPrefix("Me: ") {
                    return String(paragraph.dropFirst("Me: ".count))
                } else if paragraph.hasPrefix("Them: ") {
                    return String(paragraph.dropFirst("Them: ".count))
                }
                return paragraph
            }
            .joined(separator: "\n\n")
    }

    /// Trims `text` and collapses any run of whitespace (including
    /// newlines, since a segment's text may itself be multi-line) to a
    /// single space.
    private static func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
