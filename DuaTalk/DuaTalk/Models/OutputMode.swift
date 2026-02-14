import Foundation

/// Available output modes for dictation formatting
enum OutputMode: String, Codable, CaseIterable {
    case raw = "raw"
    case general = "general"
    case custom = "custom"

    /// Display name for the mode
    var displayName: String {
        switch self {
        case .raw: return "Raw"
        case .general: return "General"
        case .custom: return "Custom"
        }
    }

    /// Whether this mode requires the local LLM model
    var requiresLLM: Bool {
        self != .raw
    }

    /// The LLM prompt for this mode (nil for raw and custom — custom prompt comes from config)
    func prompt(for language: Language) -> String? {
        switch self {
        case .raw, .custom:
            return nil

        case .general:
            switch language {
            case .english:
                return """
                You are a dictation formatter. Clean up the spoken text below into well-structured written text.

                Rules:
                - Remove filler words and hesitations that add no meaning
                - Remove stuttering and repeated words
                - Fix punctuation, grammar, and sentence structure
                - Keep technical terms and meaningful content exactly as spoken
                - Break into paragraphs when the topic shifts, the time or date changes, or the speaker says "new paragraph" or "new line"
                - For emails: put a blank line after the greeting, between paragraphs, and before the sign-off. Put the name on its own line after the sign-off
                - Output only the cleaned text, nothing else
                """
            case .swedish:
                return """
                Du är en dikteringsformaterare. Städa upp den talade texten nedan till välstrukturerad skriven text.

                Regler:
                - Ta bort utfyllnadsord och tvekanden som inte tillför mening
                - Ta bort stamning och upprepade ord
                - Fixa interpunktion, grammatik och meningsuppbyggnad
                - Bevara tekniska termer och meningsfullt innehåll exakt som det sägs
                - Dela upp i stycken när ämnet skiftar, tid eller datum ändras, eller talaren säger "nytt stycke" eller "ny rad"
                - För mejl: lägg en tom rad efter hälsningen, mellan stycken, och före avslutningen. Sätt namnet på en egen rad efter avslutningen
                - Skriv bara den städade texten, inget annat
                """
            }
        }
    }

    /// Backward-compatible decoding: maps "code_prompt" → .custom
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "code_prompt":
            self = .custom
        default:
            guard let mode = OutputMode(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown output mode: \(rawValue)")
            }
            self = mode
        }
    }
}
