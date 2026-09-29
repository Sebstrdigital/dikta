import Foundation

/// Who was the active speaker in the meeting tab, and when, as recorded to
/// `speakers.jsonl` by `SpeakerTimelineRecorder` during a shadow join.
///
/// Times are seconds from the instant audio capture started, which is the same
/// origin the chunked transcriber's session-absolute segment times use.
struct SpeakerTimeline: Equatable, Sendable {
    struct Event: Equatable, Sendable {
        var t: TimeInterval
        var kind: String
        var name: String?
    }

    /// One stretch during which one participant was the active speaker.
    struct Interval: Equatable, Sendable {
        var name: String
        var start: TimeInterval
        var end: TimeInterval
    }

    var events: [Event]

    static let empty = SpeakerTimeline(events: [])

    /// Parses `speakers.jsonl` content. A malformed or half-written line (the
    /// recorder may be mid-write when a chunk reads the file) is skipped.
    static func parse(jsonl: String) -> SpeakerTimeline {
        var events: [Event] = []
        for line in jsonl.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = (object["t"] as? NSNumber)?.doubleValue,
                  let kind = object["kind"] as? String else { continue }
            events.append(Event(t: t, kind: kind, name: object["name"] as? String))
        }
        return SpeakerTimeline(events: events)
    }

    /// The timeline in `url`, or an empty one when the file is absent or unreadable.
    static func load(from url: URL?) -> SpeakerTimeline {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
        return parse(jsonl: text)
    }

    /// Every distinct, normalised participant name the timeline mentions.
    var names: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for event in events {
            guard let raw = event.name else { continue }
            let name = SpeakerAttributor.normalizedName(raw)
            if !name.isEmpty, seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }

    /// Active-speaker stretches, in time order. An `activeSpeaker` event ends
    /// the previous stretch and, when it names someone, starts a new one; a
    /// `left` event for the current speaker ends theirs. The last stretch is
    /// open-ended.
    var intervals: [Interval] {
        var result: [Interval] = []
        var current: (name: String, start: TimeInterval)?

        func close(at t: TimeInterval) {
            if let current { result.append(Interval(name: current.name, start: current.start, end: max(t, current.start))) }
            current = nil
        }

        for event in events.sorted(by: { $0.t < $1.t }) {
            switch event.kind {
            case "activeSpeaker":
                close(at: event.t)
                if let raw = event.name {
                    let name = SpeakerAttributor.normalizedName(raw)
                    if !name.isEmpty { current = (name, event.t) }
                }
            case "left":
                if let raw = event.name, let running = current,
                   SpeakerAttributor.normalizedName(raw) == running.name {
                    close(at: event.t)
                }
            default:
                break
            }
        }
        if let current { result.append(Interval(name: current.name, start: current.start, end: .infinity)) }
        return result
    }
}

/// Turns the anonymous "Them" segments of a merged call transcript into named
/// ones, using the meeting's active-speaker timeline, and removes the user's
/// own voice when the meeting relays it back on the system-audio track.
enum SpeakerAttributor {
    /// A Them segment overlapped by Me for more than this fraction of its
    /// duration is the user's own relayed voice and is dropped.
    static let echoDropFraction = 0.5

    /// The label for a named remote participant.
    static func label(for name: String) -> SpeakerLabel {
        SpeakerLabel(id: "name:\(name.lowercased())", display: name)
    }

    /// Markers Meet appends to a tile's display name that are not part of the name.
    private static let trailingMarker = try! NSRegularExpression(
        pattern: #"\s*\((?:guest|gäst|you|du)\)\s*$"#,
        options: [.caseInsensitive]
    )

    /// `"Anna Svensson (Guest)"` becomes `"Anna Svensson"`; a trailing
    /// `(You)`/`(Du)` is removed and whitespace runs collapse to one space.
    static func normalizedName(_ raw: String) -> String {
        var name = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while let match = trailingMarker.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range, in: name) {
            name.removeSubrange(range)
            name = name.trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// `attribute`, but only when a shadow join actually recorded a timeline.
    /// Without one (a plain call capture) the merge output passes through
    /// untouched, so those debriefs behave exactly as before.
    static func attributeIfRecorded(_ segments: [LabeledSegment], timeline: SpeakerTimeline) -> [LabeledSegment] {
        timeline.events.isEmpty ? segments : attribute(segments, timeline: timeline)
    }

    /// `segments` (as produced by `TwoTrackMerger.merge`) with echo removed and
    /// each Them segment relabeled with the participant who was speaking for
    /// the majority of it. Me segments are never touched. Works for any segment
    /// length, including one word per segment.
    static func attribute(_ segments: [LabeledSegment], timeline: SpeakerTimeline) -> [LabeledSegment] {
        let meSpans = mergedSpans(segments.filter { $0.speaker == .me }.map { ($0.start, $0.end) })
        let intervals = timeline.intervals

        var output: [(index: Int, segment: LabeledSegment)] = []
        for (index, segment) in segments.enumerated() {
            guard segment.speaker == .them else {
                output.append((index, segment))
                continue
            }
            for piece in removingEcho(from: segment, meSpans: meSpans) {
                output.append((index, named(piece, intervals: intervals)))
            }
        }
        // Trimming moves starts later; keep the timeline ordered, stably.
        return output
            .sorted { $0.segment.start != $1.segment.start ? $0.segment.start < $1.segment.start : $0.index < $1.index }
            .map(\.segment)
    }

    // MARK: - Echo

    /// Sorted, non-overlapping union of the given spans.
    private static func mergedSpans(_ spans: [(TimeInterval, TimeInterval)]) -> [(TimeInterval, TimeInterval)] {
        var merged: [(TimeInterval, TimeInterval)] = []
        for span in spans.filter({ $0.1 > $0.0 }).sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, span.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, span.1)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// The Them `segment` minus the stretches where Me was talking: nothing when
    /// more than half of it is overlapped, the whole segment when none is, and
    /// otherwise one trimmed piece per free stretch, each keeping the words
    /// whose midpoints fall inside it.
    private static func removingEcho(from segment: LabeledSegment, meSpans: [(TimeInterval, TimeInterval)]) -> [LabeledSegment] {
        let duration = segment.end - segment.start
        guard duration > 0 else { return [segment] }

        var overlap: TimeInterval = 0
        var free: [(TimeInterval, TimeInterval)] = []
        var cursor = segment.start
        for span in meSpans where span.1 > segment.start && span.0 < segment.end {
            let from = max(span.0, segment.start)
            let to = min(span.1, segment.end)
            overlap += to - from
            if from > cursor { free.append((cursor, from)) }
            cursor = max(cursor, to)
        }
        guard overlap > 0 else { return [segment] }
        guard overlap / duration <= echoDropFraction else { return [] }
        if cursor < segment.end { free.append((cursor, segment.end)) }

        let words = segment.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return free.compactMap { start, end in
            let kept = words.enumerated().filter { offset, _ in
                let midpoint = segment.start + duration * (Double(offset) + 0.5) / Double(words.count)
                return midpoint >= start && midpoint < end
            }.map(\.element)
            guard !kept.isEmpty else { return nil }
            var piece = segment
            piece.start = start
            piece.end = end
            piece.text = kept.joined(separator: " ")
            return piece
        }
    }

    // MARK: - Naming

    /// `segment` labeled with the participant active for more than half of it,
    /// or unchanged when nobody was.
    private static func named(_ segment: LabeledSegment, intervals: [SpeakerTimeline.Interval]) -> LabeledSegment {
        let duration = segment.end - segment.start
        var overlapByName: [String: TimeInterval] = [:]
        for interval in intervals {
            let overlap: TimeInterval
            if duration > 0 {
                overlap = min(interval.end, segment.end) - max(interval.start, segment.start)
            } else {
                overlap = (interval.start <= segment.start && segment.start < interval.end) ? 1 : 0
            }
            if overlap > 0 { overlapByName[interval.name, default: 0] += overlap }
        }
        let threshold = duration > 0 ? duration / 2 : 0.5
        guard let best = overlapByName.max(by: { $0.value < $1.value }), best.value > threshold else { return segment }
        var result = segment
        result.speaker = label(for: best.key)
        return result
    }
}
