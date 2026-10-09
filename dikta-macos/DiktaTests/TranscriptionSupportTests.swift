import XCTest
@testable import Dikta

/// Backend-neutral cleanup tests. These helpers were extracted before the
/// obsolete Whisper implementation was removed.
final class TranscriptionSupportPostProcessingTests: XCTestCase {
    func test_cleanSegments_stripsControlTokens() {
        let segments = [RawTranscriptSegment(text: "<|startoftranscript|><|en|>Hello there<|endoftext|>")]
        XCTAssertEqual(TranscriptionSupport.cleanSegments(segments), "Hello there")
    }

    func test_cleanSegments_stripsBracketNoiseTokens() {
        let segments = [
            RawTranscriptSegment(text: "[BLANK_AUDIO]"),
            RawTranscriptSegment(text: "[ Silence ]"),
            RawTranscriptSegment(text: "[silence]"),
            RawTranscriptSegment(text: "[no speech]"),
            RawTranscriptSegment(text: "Actual words")
        ]
        XCTAssertEqual(TranscriptionSupport.cleanSegments(segments), "Actual words")
    }

    func test_cleanSegments_dropsEmptyAndWhitespaceSegments() {
        let segments = [
            RawTranscriptSegment(text: ""), RawTranscriptSegment(text: "   "),
            RawTranscriptSegment(text: "\t\t"), RawTranscriptSegment(text: "Real text")
        ]
        XCTAssertEqual(TranscriptionSupport.cleanSegments(segments), "Real text")
    }

    func test_cleanSegments_joinsNormalTextWithSpaces() {
        let segments = [
            RawTranscriptSegment(text: "First segment."),
            RawTranscriptSegment(text: "Second segment."),
            RawTranscriptSegment(text: "Third segment.")
        ]
        XCTAssertEqual(TranscriptionSupport.cleanSegments(segments), "First segment. Second segment. Third segment.")
    }

    func test_cleanSegments_emptyInputProducesEmptyString() {
        XCTAssertEqual(TranscriptionSupport.cleanSegments([]), "")
    }

    func test_cleanSegments_allSegmentsFilteredProducesEmptyString() {
        XCTAssertEqual(TranscriptionSupport.cleanSegments([
            RawTranscriptSegment(text: "[BLANK_AUDIO]"), RawTranscriptSegment(text: "   ")
        ]), "")
    }

    func test_defaultDiskSpaceProbeReturnsNonnegativeValue() {
        XCTAssertGreaterThanOrEqual(TranscriptionSupport.defaultFreeDiskSpace(), 0)
    }
}
