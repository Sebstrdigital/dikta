import Foundation
import NaturalLanguage

/// Conservative language inference for language-sensitive consumers.
/// Ultra itself is multilingual and receives no language hint; this helper is
/// deliberately applied only after text exists. `nil` means ambiguous,
/// mixed, short, unsupported, or low-confidence text.
enum TextLanguageInference {
    /// Languages whose existing formatter behavior is meaningful. Swedish is
    /// included for Debrief selection and retains heuristic-only formatting;
    /// the other values preserve embedding eligibility from `Language`.
    private static let supported: Set<Language> = [
        .english, .swedish, .spanish, .french, .german,
        .portuguese, .italian, .dutch
    ]
    private static let englishMarkers: Set<String> = [
        "the", "and", "this", "that", "with", "we", "our", "is", "are", "tomorrow"
    ]
    private static let swedishMarkers: Set<String> = [
        "och", "det", "den", "med", "vi", "vår", "är", "att", "som", "imorgon", "morgon"
    ]

    static func infer(from text: String) -> Language? {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard words.count >= 4, text.count >= 20 else { return nil }

        // NaturalLanguage often assigns a mixed EN/SV take wholly to whichever
        // language appears last. Explicit markers keep genuine code-switching
        // conservative instead of presenting that as confident detection.
        let englishCount = words.reduce(0) { $0 + (englishMarkers.contains($1) ? 1 : 0) }
        let swedishCount = words.reduce(0) { $0 + (swedishMarkers.contains($1) ? 1 : 0) }
        if englishCount >= 2, swedishCount >= 2 { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }
        guard let first = hypotheses.first,
              first.value >= 0.65,
              first.value - (hypotheses.dropFirst().first?.value ?? 0) >= 0.20,
              let language = Language(rawValue: first.key.rawValue),
              supported.contains(language) else {
            return nil
        }
        return language
    }

    /// Debrief supports English and Swedish. Its conservative fallback for
    /// every uncertain, mixed, or unsupported transcript is English.
    static func debriefCode(for text: String) -> String {
        infer(from: text) == .swedish ? "sv" : "en"
    }
}
