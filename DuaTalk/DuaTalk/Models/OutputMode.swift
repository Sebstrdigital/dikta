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
    func prompt(for language: Language) -> String? {
        switch self {
        case .raw:
            return nil

        case .general:
            switch language {
            case .english:
                return """
                Clean up this dictation. You are transcribing speech from a software developer.
                - If the input is empty, silence, or contains no actual speech content, return NOTHING (empty response)
                - Remove filler words (um, uh, like, you know, so, basically)
                - Fix punctuation and capitalization
                - PRESERVE all technical terms exactly: API, CI/CD, DevOps, Git, tests, deployment, frontend, backend, refactor, debug, etc.
                - PRESERVE programming terms, library names, and tech jargon - do NOT rephrase them
                - Keep acronyms as spoken (e.g., "API" not "application programming interface")
                - Keep the natural flow, just clean up speech artifacts
                - Do NOT make up or invent any content - only clean up what was actually said
                - Output ONLY the cleaned text, nothing else.
                """
            case .swedish:
                return """
                Städa upp denna diktering. Du transkriberar tal från en mjukvaruutvecklare.
                - Om inmatningen är tom, tystnad, eller saknar faktiskt talinnehåll, returnera INGENTING (tomt svar)
                - Ta bort utfyllnadsord (öh, eh, liksom, typ, asså, ba)
                - Fixa interpunktion och versaler
                - BEVARA alla tekniska termer exakt: API, CI/CD, DevOps, Git, tester, deployment, frontend, backend, refactor, debug, etc.
                - BEVARA programmeringstermer, biblioteksnamn och tech-jargong - skriv INTE om dem
                - Behåll akronymer som de sägs
                - Behåll det naturliga flödet, städa bara upp talfel
                - Hitta INTE PÅ eller uppfinn något innehåll - städa bara upp det som faktiskt sades
                - Skriv ENDAST den städade texten, inget annat.
                """
            }

        case .codePrompt:
            switch language {
            case .english:
                return """
                Format this as a clear prompt for an AI coding assistant.
                - If the input is empty, silence, or contains no actual speech content, return NOTHING (empty response)
                - Use imperative language ("Implement...", "Create...", "Fix...", "Add...")
                - Structure with numbered steps if multiple tasks mentioned
                - Wrap code references, file names, and technical terms in backticks
                - Be specific and unambiguous
                - Remove verbal fillers and hesitations
                - Do NOT make up or invent any content - only format what was actually said
                - Output ONLY the formatted prompt, nothing else.
                """
            case .swedish:
                return """
                Formatera detta som en tydlig prompt för en AI-kodassistent.
                - Om inmatningen är tom, tystnad, eller saknar faktiskt talinnehåll, returnera INGENTING (tomt svar)
                - Använd imperativ form ("Implementera...", "Skapa...", "Fixa...", "Lägg till...")
                - Strukturera med numrerade steg om flera uppgifter nämns
                - Använd backticks runt kodreferenser, filnamn och tekniska termer
                - Var specifik och tydlig
                - Ta bort utfyllnadsord och tveksamheter
                - Hitta INTE PÅ eller uppfinn något innehåll - formatera bara det som faktiskt sades
                - Skriv ENDAST den formaterade prompten, inget annat.
                """
            }
        }
    }
}
