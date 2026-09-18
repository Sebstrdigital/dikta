/// TwoTrackMergerTests — merge order/tie-break/overlap and render/label
/// behavior for `TwoTrackMerger` (Me/Them call-debrief transcript merger).
///
/// Run via: cd dikta-macos && xcodebuild test -project Dikta.xcodeproj -scheme Dikta -only-testing:DiktaTests/TwoTrackMergerTests -destination 'platform=macOS' CODE_SIGN_IDENTITY=- 2>&1 | grep 'Executed.*test'

import XCTest
@testable import Dikta

// MARK: - merge

final class TwoTrackMergerMergeTests: XCTestCase {
    func test_interleavesBothTracksInStartOrder() {
        let me = [TranscriptSegment(start: 0, end: 2, text: "hello")]
        let them = [TranscriptSegment(start: 1, end: 3, text: "hi there")]

        let merged = TwoTrackMerger.merge(me: me, them: them)

        XCTAssertEqual(merged.map(\.speaker), [.me, .them])
        XCTAssertEqual(merged.map(\.text), ["hello", "hi there"])
    }

    func test_tieAtSameStart_meComesFirst() {
        let me = [TranscriptSegment(start: 5, end: 6, text: "me segment")]
        let them = [TranscriptSegment(start: 5, end: 6, text: "them segment")]

        let merged = TwoTrackMerger.merge(me: me, them: them)

        XCTAssertEqual(merged.map(\.speaker), [.me, .them])
    }

    func test_overlappingSegmentsAreKeptInStartOrder_notSplit() {
        let me = [TranscriptSegment(start: 0, end: 10, text: "long me segment")]
        let them = [TranscriptSegment(start: 3, end: 5, text: "interjection")]

        let merged = TwoTrackMerger.merge(me: me, them: them)

        XCTAssertEqual(merged.count, 2, "overlap must not split either segment")
        XCTAssertEqual(merged[0].text, "long me segment")
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 10, "end must be untouched by the overlapping Them segment")
        XCTAssertEqual(merged[1].text, "interjection")
    }

    func test_noSegmentIsDropped() {
        let me = (0..<5).map { TranscriptSegment(start: TimeInterval($0 * 10), end: TimeInterval($0 * 10 + 1), text: "me\($0)") }
        let them = (0..<3).map { TranscriptSegment(start: TimeInterval($0 * 10 + 5), end: TimeInterval($0 * 10 + 6), text: "them\($0)") }

        let merged = TwoTrackMerger.merge(me: me, them: them)

        XCTAssertEqual(merged.count, me.count + them.count)
    }

    func test_emptyBothTracks_returnsEmpty() {
        XCTAssertEqual(TwoTrackMerger.merge(me: [], them: []), [])
    }

    func test_oneSidedInput_meOnly() {
        let me = [TranscriptSegment(start: 0, end: 1, text: "only me")]

        let merged = TwoTrackMerger.merge(me: me, them: [])

        XCTAssertEqual(merged, [LabeledSegment(speaker: .me, start: 0, end: 1, text: "only me")])
    }

    func test_oneSidedInput_themOnly() {
        let them = [TranscriptSegment(start: 0, end: 1, text: "only them")]

        let merged = TwoTrackMerger.merge(me: [], them: them)

        XCTAssertEqual(merged, [LabeledSegment(speaker: .them, start: 0, end: 1, text: "only them")])
    }

    func test_speakerLabelRemote_carriesIndexInDisplayAndID() {
        let remote = SpeakerLabel.remote(2)
        XCTAssertEqual(remote.display, "Speaker 2")
        XCTAssertNotEqual(remote, SpeakerLabel.remote(1))
    }
}

// MARK: - render

final class TwoTrackMergerRenderTests: XCTestCase {
    func test_emptyInput_rendersEmptyString() {
        XCTAssertEqual(TwoTrackMerger.render([]), "")
    }

    func test_singleSegmentRendersAsOneLine() {
        let segments = [LabeledSegment(speaker: .me, start: 0, end: 1, text: "hello there")]
        XCTAssertEqual(TwoTrackMerger.render(segments), "Me: hello there")
    }

    func test_consecutiveSameSpeakerSegmentsJoinIntoOneParagraph() {
        let segments = [
            LabeledSegment(speaker: .me, start: 0, end: 1, text: "first"),
            LabeledSegment(speaker: .me, start: 1, end: 2, text: "second"),
        ]
        XCTAssertEqual(TwoTrackMerger.render(segments), "Me: first second")
    }

    func test_speakerChangeStartsNewParagraphSeparatedByBlankLine() {
        let segments = [
            LabeledSegment(speaker: .me, start: 0, end: 1, text: "hi"),
            LabeledSegment(speaker: .them, start: 1, end: 2, text: "hello back"),
        ]
        XCTAssertEqual(TwoTrackMerger.render(segments), "Me: hi\n\nThem: hello back")
    }

    func test_returningToAPriorSpeakerStartsANewParagraph_notReopeningTheEarlierOne() {
        let segments = [
            LabeledSegment(speaker: .me, start: 0, end: 1, text: "one"),
            LabeledSegment(speaker: .them, start: 1, end: 2, text: "two"),
            LabeledSegment(speaker: .me, start: 2, end: 3, text: "three"),
        ]
        XCTAssertEqual(TwoTrackMerger.render(segments), "Me: one\n\nThem: two\n\nMe: three")
    }

    func test_whitespaceIsNormalized() {
        let segments = [LabeledSegment(speaker: .me, start: 0, end: 1, text: "  hello\n  world  ")]
        XCTAssertEqual(TwoTrackMerger.render(segments), "Me: hello world")
    }

    func test_endToEnd_mergeThenRender() {
        let me = [
            TranscriptSegment(start: 0, end: 1, text: "so about the launch"),
            TranscriptSegment(start: 4, end: 5, text: "sounds good"),
        ]
        let them = [
            TranscriptSegment(start: 1.5, end: 3, text: "I think we should wait")
        ]

        let rendered = TwoTrackMerger.render(TwoTrackMerger.merge(me: me, them: them))

        XCTAssertEqual(rendered, "Me: so about the launch\n\nThem: I think we should wait\n\nMe: sounds good")
    }
}

// MARK: - isLabeledTranscript

final class TwoTrackMergerIsLabeledTranscriptTests: XCTestCase {
    func test_true_whenALineStartsWithMe() {
        XCTAssertTrue(TwoTrackMerger.isLabeledTranscript("Me: hello\nThem: hi"))
    }

    func test_true_whenOnlyThemLinesArePresent() {
        XCTAssertTrue(TwoTrackMerger.isLabeledTranscript("Them: hello there"))
    }

    func test_true_whenLabeledLineIsNotFirst() {
        XCTAssertTrue(TwoTrackMerger.isLabeledTranscript("some preamble\nMe: hello"))
    }

    func test_false_forPlainUnlabeledTranscript() {
        XCTAssertFalse(TwoTrackMerger.isLabeledTranscript("so we talked about the roadmap today"))
    }

    func test_false_whenMeOrThemAppearMidLineRatherThanAsALabel() {
        XCTAssertFalse(TwoTrackMerger.isLabeledTranscript("they told me: this is not a label"))
    }

    func test_false_forEmptyString() {
        XCTAssertFalse(TwoTrackMerger.isLabeledTranscript(""))
    }
}
