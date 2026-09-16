/// TranscriberPostProcessingTests — Unit tests for the real Transcriber.cleanSegments
/// and WhisperModel, via `@testable import Dikta` (see DiktaTests.swift for why the
/// hand-copied-type pattern is no longer used).
///
/// Run via: cd dikta-macos && swift test --filter TranscriberPostProcessingTests

import XCTest
@testable import Dikta

// MARK: - Transcriber.cleanSegments

// Transcriber is @MainActor, so cleanSegments (a static member) is too.
@MainActor
final class TranscriberPostProcessingTests: XCTestCase {
    func test_cleanSegments_stripsControlTokens() {
        let segments = [
            TranscriptSegment(text: "<|startoftranscript|><|en|>Hello there<|endoftext|>")
        ]
        XCTAssertEqual(Transcriber.cleanSegments(segments), "Hello there")
    }

    func test_cleanSegments_stripsBracketNoiseTokens() {
        let segments = [
            TranscriptSegment(text: "[BLANK_AUDIO]"),
            TranscriptSegment(text: "[ Silence ]"),
            TranscriptSegment(text: "[silence]"),
            TranscriptSegment(text: "[no speech]"),
            TranscriptSegment(text: "Actual words")
        ]
        XCTAssertEqual(Transcriber.cleanSegments(segments), "Actual words")
    }

    func test_cleanSegments_dropsEmptyAndWhitespaceSegments() {
        // Note: production trims with .whitespaces (spaces/tabs), not
        // .whitespacesAndNewlines, so only space/tab-only segments are covered here.
        let segments = [
            TranscriptSegment(text: ""),
            TranscriptSegment(text: "   "),
            TranscriptSegment(text: "\t\t"),
            TranscriptSegment(text: "Real text")
        ]
        XCTAssertEqual(Transcriber.cleanSegments(segments), "Real text")
    }

    func test_cleanSegments_joinsNormalTextWithSpaces() {
        let segments = [
            TranscriptSegment(text: "First segment."),
            TranscriptSegment(text: "Second segment."),
            TranscriptSegment(text: "Third segment.")
        ]
        XCTAssertEqual(
            Transcriber.cleanSegments(segments),
            "First segment. Second segment. Third segment."
        )
    }

    func test_cleanSegments_emptyInputProducesEmptyString() {
        XCTAssertEqual(Transcriber.cleanSegments([]), "")
    }

    func test_cleanSegments_allSegmentsFilteredProducesEmptyString() {
        let segments = [
            TranscriptSegment(text: "[BLANK_AUDIO]"),
            TranscriptSegment(text: "   ")
        ]
        XCTAssertEqual(Transcriber.cleanSegments(segments), "")
    }
}

// MARK: - WhisperModel decoding

/// Proves the persisted rawValues ("small"/"medium") still decode after
/// WhisperModel gained engine-qualified `repo`/`variant` identity — a saved
/// AppConfig's `whisper_model` string must keep mapping to the same case.
final class WhisperModelDecodingTests: XCTestCase {
    func test_decode_smallRawValue() throws {
        let json = "\"small\"".data(using: .utf8)!
        let model = try JSONDecoder().decode(WhisperModel.self, from: json)
        XCTAssertEqual(model, .small)
        XCTAssertEqual(model.rawValue, "small")
        XCTAssertEqual(model.variant, "openai_whisper-small")
        XCTAssertEqual(model.repo, "argmaxinc/whisperkit-coreml")
    }

    func test_decode_mediumRawValue() throws {
        let json = "\"medium\"".data(using: .utf8)!
        let model = try JSONDecoder().decode(WhisperModel.self, from: json)
        XCTAssertEqual(model, .medium)
        XCTAssertEqual(model.rawValue, "medium")
        XCTAssertEqual(model.variant, "openai_whisper-medium")
    }
}
