import Foundation

/// Deterministic, no-LLM fallback summarizer.
///
/// Always available; throws only `DebriefSummarizerError.emptyTranscript` for
/// empty input, otherwise always succeeds, so the debrief pipeline can fall
/// back to it even with no Ollama server and no Foundation Models support.
/// Quality is intentionally modest: it splits the transcript into sentences,
/// further breaks up any long run-on sentence (unpunctuated WhisperKit output
/// tends to produce one giant "sentence"), and buckets the resulting segments
/// by keyword, with no owner/due extraction.
final class HeuristicDebriefSummarizer: DebriefSummarizer {
    let name = "Heuristic"

    /// Segments longer than this (in words) are further broken up — first at
    /// discourse markers, then (if still too long) at a fixed word count —
    /// so a single unpunctuated run-on "sentence" doesn't get bucketed as
    /// one summary/decision/action/question all at once.
    private static let maxSegmentWordsBeforeSplit = 30
    /// Fallback chunk size (in words) used once discourse-marker splitting
    /// alone isn't enough to bring a segment under the threshold above.
    private static let wordCountFallbackChunkSize = 20

    /// English discourse fillers that mark a natural clause boundary in a
    /// run-on, unpunctuated transcript. Longer phrases are listed first so
    /// they're preferred over a shorter phrase they contain (e.g. "and then"
    /// over "then").
    private static let discourseMarkersEn = [
        "and then", "so", "okay", "ok", "also", "next", "then",
    ]
    /// Swedish discourse fillers, same purpose as `discourseMarkersEn`.
    private static let discourseMarkersSv = [
        "och sen", "sen", "så", "okej", "också", "sedan",
    ]

    /// English keywords that mark a segment as describing a follow-up task.
    private static let actionMarkersEn = [
        "will ", "should ", "need to", "needs to", "must ", "todo", "action item", "follow up",
    ]
    /// Swedish keywords that mark a segment as describing a follow-up task.
    private static let actionMarkersSv = [
        "ska ", "måste ", "behöver ", "bör ", "åtgärd", "följa upp",
    ]

    private static let decisionMarkersEn = [
        "decided", "agreed", "we will go with",
    ]
    private static let decisionMarkersSv = [
        "beslutade", "bestämde", "kom överens", "vi kör på",
    ]

    private static let openQuestionMarkersEn = [
        "open question", "unclear", "not sure",
    ]
    private static let openQuestionMarkersSv = [
        "öppen fråga", "oklart", "osäker",
    ]

    func isAvailable() async -> Bool {
        true
    }

    func summarize(transcript: String, language: String) async throws -> DebriefSummary {
        var trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw DebriefSummarizerError.emptyTranscript
        }

        // This engine has no notion of speakers, so a Me/Them-labeled call
        // debrief (see TwoTrackMerger) must have its labels stripped first —
        // otherwise the literal "Me: "/"Them: " prefixes end up bucketed
        // straight into the summary/decisions/actions/questions below.
        if TwoTrackMerger.isLabeledTranscript(trimmedTranscript) {
            trimmedTranscript = TwoTrackMerger.stripLabels(trimmedTranscript)
        }

        let discourseMarkers = language == "sv" ? Self.discourseMarkersSv : Self.discourseMarkersEn
        let actionMarkers = language == "sv" ? Self.actionMarkersSv : Self.actionMarkersEn
        let decisionMarkers = language == "sv" ? Self.decisionMarkersSv : Self.decisionMarkersEn
        let openQuestionMarkers = language == "sv" ? Self.openQuestionMarkersSv : Self.openQuestionMarkersEn

        let segments = Self.splitIntoSegments(trimmedTranscript, discourseMarkers: discourseMarkers)

        let summary = segments.prefix(3).joined(separator: " ")

        // Each segment lands in at most one bucket, highest priority wins:
        // openQuestion > decision > action. Otherwise a merged, unpunctuated
        // clause (e.g. one that both states a decision and raises a
        // question) would get duplicated into two buckets at once.
        var decisionTexts: [String] = []
        var actionItemTexts: [String] = []
        var openQuestionTexts: [String] = []

        for segment in segments {
            if segment.hasSuffix("?") || Self.contains(any: openQuestionMarkers, in: segment) {
                openQuestionTexts.append(segment)
            } else if Self.contains(any: decisionMarkers, in: segment) {
                decisionTexts.append(segment)
            } else if Self.contains(any: actionMarkers, in: segment) {
                actionItemTexts.append(segment)
            }
        }

        let actionItems = Self.dedupeKeepingOrder(actionItemTexts)
            .prefix(10)
            .map { DebriefActionItem(text: $0, owner: nil, due: nil) }

        return DebriefSummary(
            summary: summary,
            decisions: Self.dedupeKeepingOrder(decisionTexts),
            actionItems: Array(actionItems),
            openQuestions: Self.dedupeKeepingOrder(openQuestionTexts)
        )
    }

    // MARK: - Segmentation

    /// Splits `text` into sentences, then further breaks up any sentence
    /// longer than `maxSegmentWordsBeforeSplit` words: first at discourse
    /// markers, then (if a resulting piece is still too long) into fixed
    /// `wordCountFallbackChunkSize`-word chunks.
    private static func splitIntoSegments(_ text: String, discourseMarkers: [String]) -> [String] {
        var segments: [String] = []
        for sentence in splitSentences(text) {
            guard wordCount(sentence) > maxSegmentWordsBeforeSplit else {
                segments.append(sentence)
                continue
            }
            for piece in splitAtDiscourseMarkers(sentence, markers: discourseMarkers) {
                if wordCount(piece) > maxSegmentWordsBeforeSplit {
                    segments.append(contentsOf: splitEveryNWords(piece, n: wordCountFallbackChunkSize))
                } else {
                    segments.append(piece)
                }
            }
        }
        return segments
    }

    /// Splits `text` into trimmed sentences on `.`, `!`, `?`, and newlines.
    /// The terminating punctuation (but not the newline) is kept as part of
    /// the sentence it closes.
    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sentences.append(trimmed)
            }
            current = ""
        }

        for character in text {
            switch character {
            case "\n":
                flush()
            case ".", "!", "?":
                current.append(character)
                flush()
            default:
                current.append(character)
            }
        }
        flush()

        return sentences
    }

    /// Splits `text` at every (case-insensitive, word-bounded) occurrence of
    /// any of `markers`. The matched marker text itself is dropped; the
    /// pieces before/after/between matches are trimmed and returned in
    /// order, skipping any that are empty. Returns `[text]` unchanged if no
    /// marker matches.
    private static func splitAtDiscourseMarkers(_ text: String, markers: [String]) -> [String] {
        guard !markers.isEmpty, let regex = discourseMarkerRegex(for: markers) else {
            return [text]
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return [text] }

        var pieces: [String] = []
        var lastEnd = 0
        for match in matches {
            let piece = nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                pieces.append(trimmed)
            }
            lastEnd = match.range.location + match.range.length
        }
        let tail = nsText.substring(from: lastEnd).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            pieces.append(tail)
        }
        return pieces.isEmpty ? [text] : pieces
    }

    private static func discourseMarkerRegex(for markers: [String]) -> NSRegularExpression? {
        let alternation = markers.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try? NSRegularExpression(pattern: "\\b(?:\(alternation))\\b", options: [.caseInsensitive])
    }

    /// Splits `text` into chunks of at most `n` whitespace-separated words
    /// (the last chunk may be shorter). Returns `[text]` unchanged if it
    /// already has `n` words or fewer.
    private static func splitEveryNWords(_ text: String, n: Int) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > n else { return [text] }

        var chunks: [String] = []
        var index = 0
        while index < words.count {
            let end = min(index + n, words.count)
            chunks.append(words[index..<end].joined(separator: " "))
            index = end
        }
        return chunks
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func contains(any markers: [String], in sentence: String) -> Bool {
        let lowercased = sentence.lowercased()
        return markers.contains { lowercased.contains($0) }
    }

    private static func dedupeKeepingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items where !seen.contains(item) {
            seen.insert(item)
            result.append(item)
        }
        return result
    }
}
