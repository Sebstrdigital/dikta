import Foundation

/// A backend-neutral transcript fragment used by the common cleanup pass.
struct RawTranscriptSegment {
    let text: String
}

/// Helpers shared by every transcription entry point.
enum TranscriptionSupport {
    /// Bytes free on the Application Support volume. A failed probe must not
    /// prevent the model loader from reporting its own actionable error.
    nonisolated static func defaultFreeDiskSpace() -> Int64 {
        let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory()
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let freeSize = attributes[.systemFreeSize] as? NSNumber else {
            return .max
        }
        return freeSize.int64Value
    }

    static func cleanSegments(_ segments: [RawTranscriptSegment]) -> String {
        segments
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { sanitizedText($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func sanitizeAndDropEmpty(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.compactMap { segment in
            let text = sanitizedText(segment.text)
            guard !text.isEmpty else { return nil }
            var cleaned = segment
            cleaned.text = text
            return cleaned
        }
    }

    static func sortMonotonic(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let wasOrdered = zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start }
        if !wasOrdered {
            AppLogger.transcription.error("transcribeSegments: backend returned segments out of order by start; sorting")
        }
        return segments.sorted { $0.start < $1.start }
    }

    private static func sanitizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<\\|[^|]+\\|>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[\\s*(?:BLANK_AUDIO|silence|no speech)\\s*\\]", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }
}
