import Foundation

/// Shared rules for deciding whether a Whisper transcript actually contains
/// speech. Whisper doesn't return an empty string for silence — it returns a
/// placeholder token such as `[BLANK_AUDIO]` — so both the dictation path and
/// the debrief pipeline have to reject the same set of markers. Keeping the
/// list in one place stops the two paths from drifting apart.
enum TranscriptSanitizer {
    /// Markers Whisper emits in place of speech, lowercased.
    static let silenceIndicators = [
        "[silence]",
        "[blank_audio]",
        "[no speech]",
        "(silence)",
        "[ silence ]"
    ]

    /// The marker that matched, or nil when the text looks like real speech.
    /// Empty (or whitespace-only) text reports `nil` — callers check
    /// `isEffectivelyEmpty` for the combined verdict and use this only to
    /// explain *why* in a diagnostic log.
    static func matchedSilenceIndicator(_ text: String) -> String? {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return silenceIndicators.first { normalized.contains($0) }
    }

    /// True when the transcript carries no usable speech: blank, whitespace
    /// only, or nothing but one of Whisper's silence markers.
    static func isEffectivelyEmpty(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return true }
        return silenceIndicators.contains { normalized.contains($0) }
    }
}
