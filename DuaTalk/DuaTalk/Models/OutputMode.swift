import Foundation

/// Available output modes for dictation formatting
enum OutputMode: String, Codable, CaseIterable {
    case raw = "raw"
    case general = "general"
    case codePrompt = "code_prompt"

    /// Display name for the mode
    var displayName: String {
        switch self {
        case .raw: return "Raw"
        case .general: return "General"
        case .codePrompt: return "Code Prompt"
        }
    }

    /// Whether this mode requires Ollama
    var requiresOllama: Bool {
        self != .raw
    }

    /// The LLM prompt for this mode (nil for raw)
    var prompt: String? {
        switch self {
        case .raw:
            return nil

        case .general:
            return """
            Clean up this dictation for general use.
            - Remove filler words (um, uh, like, you know, so, basically)
            - Fix punctuation and capitalization
            - Keep the natural conversational flow
            - Output ONLY the cleaned text, nothing else.
            """

        case .codePrompt:
            return """
            Format this as a clear prompt for an AI coding assistant.
            - Use imperative language ("Implement...", "Create...", "Fix...", "Add...")
            - Structure with numbered steps if multiple tasks mentioned
            - Wrap code references, file names, and technical terms in backticks
            - Be specific and unambiguous
            - Remove verbal fillers and hesitations
            - Output ONLY the formatted prompt, nothing else.
            """
        }
    }
}
