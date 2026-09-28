import XCTest
@testable import Dikta

/// Synthetic segments only — no real transcripts.
final class SpeakerAttributorTests: XCTestCase {

    private func seg(_ speaker: SpeakerLabel, _ start: Double, _ end: Double, _ text: String) -> LabeledSegment {
        LabeledSegment(speaker: speaker, start: start, end: end, text: text)
    }

    private func timeline(_ events: [(Double, String, String?)]) -> SpeakerTimeline {
        SpeakerTimeline(events: events.map { SpeakerTimeline.Event(t: $0.0, kind: $0.1, name: $0.2) })
    }

    // MARK: - Attribution

    func test_themSegmentTakesTheMajorityOverlapSpeaker() {
        let tl = timeline([(0, "activeSpeaker", "Anna"), (7, "activeSpeaker", "Bo"), (10, "activeSpeaker", nil)])
        let out = SpeakerAttributor.attribute([seg(.them, 0, 10, "hello there")], timeline: tl)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].speaker.display, "Anna")
    }

    func test_majorityGoesToTheLongerSpeakerNotTheFirst() {
        let tl = timeline([(0, "activeSpeaker", "Anna"), (3, "activeSpeaker", "Bo")])
        let out = SpeakerAttributor.attribute([seg(.them, 0, 10, "hello there")], timeline: tl)
        XCTAssertEqual(out[0].speaker.display, "Bo")
        XCTAssertEqual(out[0].speaker.id, "name:bo")
    }

    func test_noSpeakerHoldingMoreThanHalf_staysThem() {
        let tl = timeline([(0, "activeSpeaker", "Anna"), (5, "activeSpeaker", "Bo")])
        let out = SpeakerAttributor.attribute([seg(.them, 0, 10, "split evenly")], timeline: tl)
        XCTAssertEqual(out[0].speaker, .them)
    }

    func test_meSegmentsAreUntouched() {
        let tl = timeline([(0, "activeSpeaker", "Anna")])
        let me = seg(.me, 0, 5, "my words")
        XCTAssertEqual(SpeakerAttributor.attribute([me], timeline: tl), [me])
    }

    func test_perWordSegmentsAreAttributedIndividually() {
        let tl = timeline([(0, "activeSpeaker", "Anna"), (1, "activeSpeaker", "Bo")])
        let words = [seg(.them, 0.0, 0.4, "good"), seg(.them, 0.5, 0.9, "morning"), seg(.them, 1.1, 1.5, "hi")]
        let out = SpeakerAttributor.attribute(words, timeline: tl)
        XCTAssertEqual(out.map(\.speaker.display), ["Anna", "Anna", "Bo"])
    }

    func test_leftEventEndsTheSpeakersInterval() {
        let tl = timeline([(0, "activeSpeaker", "Anna"), (2, "left", "Anna")])
        let out = SpeakerAttributor.attribute([seg(.them, 4, 6, "after she left")], timeline: tl)
        XCTAssertEqual(out[0].speaker, .them)
    }

    // MARK: - Unknown speaker

    func test_emptyTimeline_keepsThem() {
        let s = seg(.them, 0, 5, "anyone there")
        XCTAssertEqual(SpeakerAttributor.attribute([s], timeline: .empty), [s])
    }

    func test_segmentOutsideEveryInterval_keepsThem() {
        let tl = timeline([(0, "activeSpeaker", "Anna"), (2, "activeSpeaker", nil)])
        let out = SpeakerAttributor.attribute([seg(.them, 10, 12, "later")], timeline: tl)
        XCTAssertEqual(out[0].speaker, .them)
    }

    func test_attributeIfRecorded_withoutTimeline_doesNotDropEcho() {
        let segments = [seg(.me, 0, 5, "same"), seg(.them, 0, 5, "same")]
        XCTAssertEqual(SpeakerAttributor.attributeIfRecorded(segments, timeline: .empty), segments)
    }

    // MARK: - Echo

    func test_themOverlappedByMeOverHalf_isDropped() {
        let tl = timeline([(0, "activeSpeaker", "Anna")])
        let out = SpeakerAttributor.attribute([seg(.me, 0, 6, "my own voice"), seg(.them, 0, 10, "my own voice relayed")], timeline: tl)
        XCTAssertEqual(out.map(\.speaker), [.me])
    }

    func test_themOverlapOfExactlyHalf_isTrimmedNotDropped() {
        let out = SpeakerAttributor.attribute([seg(.me, 0, 5, "mine"), seg(.them, 0, 10, "one two three four")], timeline: timeline([]))
        let them = out.filter { $0.speaker != .me }
        XCTAssertEqual(them.count, 1)
        XCTAssertEqual(them[0].start, 5, accuracy: 0.001)
        XCTAssertEqual(them[0].end, 10, accuracy: 0.001)
        XCTAssertEqual(them[0].text, "three four")
    }

    func test_partialOverlapAtTheEnd_trimsTheTail() {
        let out = SpeakerAttributor.attribute([seg(.them, 0, 10, "a b c d e f g h i j"), seg(.me, 8, 12, "mine")], timeline: timeline([]))
        let them = out.first { $0.speaker != .me }
        XCTAssertEqual(them?.end ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(them?.text, "a b c d e f g h")
    }

    func test_meInTheMiddle_splitsIntoTwoPieces() {
        let out = SpeakerAttributor.attribute(
            [seg(.them, 0, 10, "a b c d e f g h i j"), seg(.me, 4, 6, "mine")],
            timeline: timeline([(0, "activeSpeaker", "Anna")])
        )
        let them = out.filter { $0.speaker.display == "Anna" }
        XCTAssertEqual(them.map(\.text), ["a b c d", "g h i j"])
    }

    func test_echoTrimmedSegmentIsStillNamed() {
        let tl = timeline([(0, "activeSpeaker", "Anna")])
        let out = SpeakerAttributor.attribute([seg(.me, 0, 2, "mine"), seg(.them, 0, 10, "a b c d e")], timeline: tl)
        XCTAssertEqual(out.last?.speaker.display, "Anna")
    }

    func test_singleWordThemBarelyOverlapped_survivesIntact() {
        let out = SpeakerAttributor.attribute([seg(.me, 0, 0.1, "uh"), seg(.them, 0, 0.5, "yes")], timeline: timeline([]))
        XCTAssertEqual(out.last?.text, "yes")
    }

    // MARK: - Names

    func test_normalizedName_stripsGuestMarker() {
        XCTAssertEqual(SpeakerAttributor.normalizedName("Anna Svensson (Guest)"), "Anna Svensson")
    }

    func test_normalizedName_stripsYouAndDuMarkers() {
        XCTAssertEqual(SpeakerAttributor.normalizedName("Bo Berg (You)"), "Bo Berg")
        XCTAssertEqual(SpeakerAttributor.normalizedName("Bo Berg (Du)"), "Bo Berg")
    }

    func test_normalizedName_collapsesWhitespaceAndStacksMarkers() {
        XCTAssertEqual(SpeakerAttributor.normalizedName("  Anna   Svensson  (Guest)  (You) "), "Anna Svensson")
    }

    func test_normalizedName_keepsParenthesesThatAreNotMarkers() {
        XCTAssertEqual(SpeakerAttributor.normalizedName("Anna (Sales)"), "Anna (Sales)")
    }

    func test_attributedLabelUsesTheNormalizedName() {
        let tl = timeline([(0, "activeSpeaker", "Anna Svensson (Guest)")])
        let out = SpeakerAttributor.attribute([seg(.them, 0, 5, "hi")], timeline: tl)
        XCTAssertEqual(out[0].speaker.display, "Anna Svensson")
        XCTAssertEqual(TwoTrackMerger.render(out), "Anna Svensson: hi")
    }

    // MARK: - Timeline file

    func test_parse_readsJsonlAndSkipsAHalfWrittenLine() {
        let jsonl = """
        {"t":0.5,"kind":"joined","name":"Anna (Guest)"}
        {"t":1.0,"kind":"activeSpeaker","name":"Anna (Guest)"}
        {"t":2.0,"kind":"activeSpeaker","name":null}
        {"t":3.0,"kin
        """
        let tl = SpeakerTimeline.parse(jsonl: jsonl)
        XCTAssertEqual(tl.events.count, 3)
        XCTAssertEqual(tl.names, ["Anna"])
        XCTAssertEqual(tl.intervals, [SpeakerTimeline.Interval(name: "Anna", start: 1.0, end: 2.0)])
    }

    func test_load_missingFile_isEmpty() {
        XCTAssertEqual(SpeakerTimeline.load(from: URL(fileURLWithPath: "/nonexistent/speakers.jsonl")), .empty)
    }

    // MARK: - Owner validation

    func test_ownerFromTheTimelineSurvivesEvenIfNeverSpokenAloud() {
        let item = DebriefActionItem(text: "Send the deck", owner: "Anna", due: nil)
        XCTAssertNil(item.validated(against: "Bo: hello").owner)
        XCTAssertEqual(item.validated(against: "Bo: hello", knownNames: ["Anna Svensson"]).owner, "Anna")
    }

    func test_stripLabels_removesNamedSpeakerLabels() {
        XCTAssertEqual(TwoTrackMerger.stripLabels("Anna Svensson: hi\n\nMe: yes"), "hi\n\nyes")
    }
}
