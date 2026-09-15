/// TranscriberPostProcessingTests — Unit tests for Transcriber.cleanSegments.
///
/// Self-contained: inlines the production `TranscriptSegment` type and
/// `Transcriber.cleanSegments` logic (same pattern as DiktaTests.swift), since the
/// main Dikta target is an executable and cannot be @testable-imported via Swift
/// Package Manager. When the production algorithm in Transcriber.swift changes,
/// update the inlined copy here too.
///
/// Run via: cd dikta-macos && swift test --filter TranscriberPostProcessingTests

import XCTest

// MARK: - Inlined production types (mirrors Transcriber.swift)

struct TranscriptSegment {
    let text: String
    let noSpeechProb: Float
}

/// Mirrors WhisperModel.swift. rawValue ("small"/"medium") is the persisted
/// identifier in AppConfig and must stay stable across the engine-qualified
/// `variant`/`repo` additions.
enum WhisperModel: String, Codable, CaseIterable {
    case small = "small"
    case medium = "medium"

    var repo: String {
        "argmaxinc/whisperkit-coreml"
    }

    var variant: String {
        switch self {
        case .small: return "openai_whisper-small"
        case .medium: return "openai_whisper-medium"
        }
    }
}

enum PostProcessing {
    /// Mirrors Transcriber.cleanSegments.
    static func cleanSegments(_ segments: [TranscriptSegment], noSpeechThreshold: Float) -> String {
        let validSegments = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.noSpeechProb < noSpeechThreshold
        }

        return validSegments.map { segment in
            segment.text
                .replacingOccurrences(of: "<\\|[^|]+\\|>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\[\\s*(?:BLANK_AUDIO|silence|no speech)\\s*\\]", with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Tests

final class TranscriberPostProcessingTests: XCTestCase {
    func test_cleanSegments_stripsControlTokens() {
        let segments = [
            TranscriptSegment(text: "<|startoftranscript|><|en|>Hello there<|endoftext|>", noSpeechProb: 0.0)
        ]
        XCTAssertEqual(PostProcessing.cleanSegments(segments, noSpeechThreshold: 0.3), "Hello there")
    }

    func test_cleanSegments_stripsBracketNoiseTokens() {
        let segments = [
            TranscriptSegment(text: "[BLANK_AUDIO]", noSpeechProb: 0.0),
            TranscriptSegment(text: "[ Silence ]", noSpeechProb: 0.0),
            TranscriptSegment(text: "[silence]", noSpeechProb: 0.0),
            TranscriptSegment(text: "[no speech]", noSpeechProb: 0.0),
            TranscriptSegment(text: "Actual words", noSpeechProb: 0.0)
        ]
        XCTAssertEqual(PostProcessing.cleanSegments(segments, noSpeechThreshold: 0.3), "Actual words")
    }

    func test_cleanSegments_dropsEmptyAndWhitespaceSegments() {
        // Note: production trims with .whitespaces (spaces/tabs), not
        // .whitespacesAndNewlines, so only space/tab-only segments are covered here.
        let segments = [
            TranscriptSegment(text: "", noSpeechProb: 0.0),
            TranscriptSegment(text: "   ", noSpeechProb: 0.0),
            TranscriptSegment(text: "\t\t", noSpeechProb: 0.0),
            TranscriptSegment(text: "Real text", noSpeechProb: 0.0)
        ]
        XCTAssertEqual(PostProcessing.cleanSegments(segments, noSpeechThreshold: 0.3), "Real text")
    }

    func test_cleanSegments_filtersNoSpeechSegmentsByThreshold() {
        let segments = [
            TranscriptSegment(text: "Kept, below threshold", noSpeechProb: 0.1),
            TranscriptSegment(text: "Dropped, at threshold", noSpeechProb: 0.3),
            TranscriptSegment(text: "Dropped, above threshold", noSpeechProb: 0.9)
        ]
        XCTAssertEqual(PostProcessing.cleanSegments(segments, noSpeechThreshold: 0.3), "Kept, below threshold")
    }

    func test_cleanSegments_joinsNormalTextWithSpaces() {
        let segments = [
            TranscriptSegment(text: "First segment.", noSpeechProb: 0.0),
            TranscriptSegment(text: "Second segment.", noSpeechProb: 0.0),
            TranscriptSegment(text: "Third segment.", noSpeechProb: 0.0)
        ]
        XCTAssertEqual(
            PostProcessing.cleanSegments(segments, noSpeechThreshold: 0.3),
            "First segment. Second segment. Third segment."
        )
    }

    func test_cleanSegments_emptyInputProducesEmptyString() {
        XCTAssertEqual(PostProcessing.cleanSegments([], noSpeechThreshold: 0.3), "")
    }

    func test_cleanSegments_allSegmentsFilteredProducesEmptyString() {
        let segments = [
            TranscriptSegment(text: "[BLANK_AUDIO]", noSpeechProb: 0.0),
            TranscriptSegment(text: "Noisy", noSpeechProb: 0.95)
        ]
        XCTAssertEqual(PostProcessing.cleanSegments(segments, noSpeechThreshold: 0.3), "")
    }
}

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
