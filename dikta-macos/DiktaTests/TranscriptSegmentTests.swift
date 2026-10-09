/// TranscriptSegmentTests — Codable round-trip for `TranscriptSegment`, plus
/// the backend-neutral cleanup helpers used by Ultra's segment API.
/// No test loads a real FluidAudio model.
///
/// Run via: cd dikta-macos && swift test --filter TranscriptSegmentTests

import XCTest
@testable import Dikta

final class TranscriptSegmentTests: XCTestCase {

    // MARK: - Codable round-trip

    func test_codable_roundTrip() throws {
        let original = TranscriptSegment(start: 1.5, end: 3.25, text: "Hello there")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func test_codable_roundTrip_array() throws {
        let original = [
            TranscriptSegment(start: 0, end: 1, text: "First"),
            TranscriptSegment(start: 1, end: 2.5, text: "Second")
        ]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([TranscriptSegment].self, from: data)

        XCTAssertEqual(decoded, original)
    }
}

// MARK: - TranscriptionSupport.sanitizeAndDropEmpty

// Transcription cleanup helpers are backend-neutral.
@MainActor
final class TranscriptionSupportSanitizeAndDropEmptyTests: XCTestCase {
    func test_stripsControlTokensAndBracketNoiseFromText() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "<|startoftranscript|><|en|>Hello there<|endoftext|>"),
            TranscriptSegment(start: 1, end: 2, text: "[BLANK_AUDIO]"),
            TranscriptSegment(start: 2, end: 3, text: "Actual words")
        ]

        let result = TranscriptionSupport.sanitizeAndDropEmpty(segments)

        XCTAssertEqual(result, [
            TranscriptSegment(start: 0, end: 1, text: "Hello there"),
            TranscriptSegment(start: 2, end: 3, text: "Actual words")
        ])
    }

    func test_dropsSegmentsThatSanitizeToEmpty() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "[silence]"),
            TranscriptSegment(start: 1, end: 2, text: "   "),
            TranscriptSegment(start: 2, end: 3, text: "")
        ]

        XCTAssertEqual(TranscriptionSupport.sanitizeAndDropEmpty(segments), [])
    }

    func test_preservesTimestampsOnKeptSegments() {
        let segments = [TranscriptSegment(start: 12.5, end: 14.0, text: "  Real text  ")]

        let result = TranscriptionSupport.sanitizeAndDropEmpty(segments)

        XCTAssertEqual(result, [TranscriptSegment(start: 12.5, end: 14.0, text: "Real text")])
    }

    func test_emptyInputProducesEmptyOutput() {
        XCTAssertEqual(TranscriptionSupport.sanitizeAndDropEmpty([]), [])
    }
}

// MARK: - TranscriptionSupport.sortMonotonic

@MainActor
final class TranscriptionSupportSortMonotonicTests: XCTestCase {
    func test_alreadySortedSegmentsAreUnchanged() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "a"),
            TranscriptSegment(start: 1, end: 2, text: "b"),
            TranscriptSegment(start: 2, end: 3, text: "c")
        ]

        XCTAssertEqual(TranscriptionSupport.sortMonotonic(segments), segments)
    }

    func test_outOfOrderSegmentsAreSortedByStart() {
        let segments = [
            TranscriptSegment(start: 5, end: 6, text: "second"),
            TranscriptSegment(start: 0, end: 1, text: "first")
        ]

        XCTAssertEqual(TranscriptionSupport.sortMonotonic(segments), [
            TranscriptSegment(start: 0, end: 1, text: "first"),
            TranscriptSegment(start: 5, end: 6, text: "second")
        ])
    }

    func test_tiedStartsAreKeptAndNotDropped() {
        let segments = [
            TranscriptSegment(start: 3, end: 4, text: "a"),
            TranscriptSegment(start: 3, end: 4, text: "b")
        ]

        let result = TranscriptionSupport.sortMonotonic(segments)

        XCTAssertEqual(result.count, 2)
        XCTAssertGreaterThanOrEqual(result[1].start, result[0].start)
    }

    func test_startsAreMonotonicNonDecreasingAfterSort() {
        let segments = [
            TranscriptSegment(start: 10, end: 11, text: "c"),
            TranscriptSegment(start: -5, end: -4, text: "a"),
            TranscriptSegment(start: 2, end: 3, text: "b")
        ]

        let result = TranscriptionSupport.sortMonotonic(segments)

        for i in 1..<result.count {
            XCTAssertGreaterThanOrEqual(result[i].start, result[i - 1].start)
        }
    }

    func test_emptyInputProducesEmptyOutput() {
        XCTAssertEqual(TranscriptionSupport.sortMonotonic([]), [])
    }

    func test_singleSegmentIsUnchanged() {
        let segments = [TranscriptSegment(start: 4, end: 5, text: "solo")]

        XCTAssertEqual(TranscriptionSupport.sortMonotonic(segments), segments)
    }
}
