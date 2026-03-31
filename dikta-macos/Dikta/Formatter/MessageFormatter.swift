import Foundation

struct MessageFormatter: TextFormatter {
    func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }

        // Already formatted (contains paragraph breaks) — return as-is for idempotency
        if trimmed.contains("\n\n") { return trimmed }

        let sentences = splitSentences(trimmed)
        if sentences.count <= 1 { return trimmed }

        // 6-zone extraction: greeting → opening pleasantry → body → closing pleasantry → sign-off → name
        let (greeting, afterGreeting) = extractGreeting(trimmed)
        let (openingPleasantry, afterOpening) = extractOpeningPleasantry(afterGreeting)
        let (signOff, afterSignOffExtracted) = extractSignOff(afterOpening)
        let (closingPleasantry, body) = extractClosingPleasantry(afterSignOffExtracted)
        let structuredBody = StructuredTextFormatter().format(body)

        var parts: [String] = []
        if let g = greeting { parts.append(g) }
        if let op = openingPleasantry { parts.append(op) }
        if !structuredBody.isEmpty { parts.append(structuredBody) }
        if let cp = closingPleasantry { parts.append(cp) }
        if let s = signOff { parts.append(s) }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Zone 1: Greeting

    private func extractGreeting(_ text: String) -> (greeting: String?, remaining: String) {
        let lower = text.lowercased()

        let greetingPhrases = [
            "to whom it may concern",
            "good morning", "good afternoon", "good evening",
            "hello there", "hey there", "hi there",
            "dear", "hello", "hey", "hi", "greetings"
        ]

        var matchedPhrase: String? = nil
        for phrase in greetingPhrases {
            if lower.hasPrefix(phrase) {
                matchedPhrase = phrase
                break
            }
        }

        guard let phrase = matchedPhrase else {
            return (nil, text)
        }

        var remaining = String(text.dropFirst(phrase.count))
            .trimmingCharacters(in: .whitespaces)

        // Handle comma or exclamation after greeting phrase
        if remaining.hasPrefix(",") || remaining.hasPrefix("!") {
            let terminator = String(remaining.prefix(1))
            remaining = String(remaining.dropFirst()).trimmingCharacters(in: .whitespaces)

            // Check if next word is a name (capitalized) — capture it
            let firstWord = remaining.components(separatedBy: " ").first ?? ""
            if firstWord.first?.isUppercase == true {
                let (nameWords, afterName) = captureNameWords(remaining)
                let originalPhrase = String(text.prefix(phrase.count))
                if !nameWords.isEmpty {
                    let nameStr = nameWords.joined(separator: " ")
                        .trimmingCharacters(in: CharacterSet(charactersIn: ",!"))
                    let greetingEnd = terminator == "!" ? "!" : ","
                    return (originalPhrase + " " + nameStr + greetingEnd, afterName)
                }
            }

            // No name — bare greeting like "Hi," or "Hello!"
            let originalPhrase = String(text.prefix(phrase.count))
            return (originalPhrase + terminator, remaining)
        }

        // No punctuation — capture name words then add comma (e.g., "Dear Mr. Johnson")
        let (nameWords, afterName) = captureNameWords(remaining)

        let originalPhrase = String(text.prefix(phrase.count))
        var greetingLine = originalPhrase
        if !nameWords.isEmpty {
            let nameStr = nameWords.joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: ",!"))
            greetingLine += " " + nameStr
        }

        // Check if name ended with ! (e.g., "Hi Rickard!")
        let lastNameWord = nameWords.last ?? ""
        if lastNameWord.hasSuffix("!") {
            greetingLine += "!"
        } else if !greetingLine.hasSuffix(",") && !greetingLine.hasSuffix("!") {
            greetingLine += ","
        }

        remaining = afterName

        return (greetingLine, remaining)
    }

    private func captureNameWords(_ text: String) -> (nameWords: [String], remaining: String) {
        let titles: Set<String> = ["Mr.", "Mrs.", "Ms.", "Dr.", "Prof."]
        // Common words that are capitalized at sentence start but are NOT names
        let nonNameWords: Set<String> = [
            "so", "the", "i", "we", "he", "she", "it", "they", "you",
            "my", "our", "his", "her", "its", "their", "your",
            "this", "that", "these", "those",
            "but", "and", "or", "if", "when", "while", "since", "because",
            "just", "also", "anyway", "actually", "basically", "well",
            "regarding", "about", "concerning",
            "please", "thanks", "thank", "hope", "wanted", "need",
            "could", "would", "should", "can", "will", "shall",
            "as", "at", "by", "for", "from", "in", "of", "on", "to", "with",
            "how", "what", "where", "why", "which", "who",
            "do", "does", "did", "have", "has", "had", "am", "is", "are", "was", "were",
            "not", "no", "yes", "yeah", "okay", "ok",
            "i'm", "i've", "i'd", "i'll", "i've", "i'd", "i'll"
        ]
        var nameWords: [String] = []
        var temp = text

        for _ in 0..<3 {
            let words = temp.components(separatedBy: " ")
            guard let first = words.first, !first.isEmpty else { break }

            // Strip trailing punctuation for checking
            let cleaned = first.trimmingCharacters(in: CharacterSet(charactersIn: ",!."))

            let isTitle = titles.contains(first)
            let isCapitalized = first.first?.isUppercase == true
            let isNonName = nonNameWords.contains(cleaned.lowercased())

            // Stop if this is a common word, not a name
            if isNonName && !isTitle { break }

            if isTitle || isCapitalized {
                nameWords.append(first)
                temp = words.dropFirst().joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)

                // Name ends at comma, exclamation, or period
                if first.hasSuffix(",") || first.hasSuffix("!") {
                    break
                }
            } else {
                break
            }
        }

        return (nameWords, temp.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Zone 2: Opening Pleasantry

    private func extractOpeningPleasantry(_ text: String) -> (pleasantry: String?, remaining: String) {
        let sentences = splitSentences(text)
        guard let first = sentences.first else { return (nil, text) }

        let lower = first.lowercased()

        let pleasantryPatterns = [
            "hope you", "hope this", "hope your", "i hope",
            "how are you", "how are things", "how's everything", "how's it going",
            "how have you been", "how's your",
            "thanks for reaching", "thank you for your", "thank you for getting",
            "great seeing you", "nice to hear from", "good to hear from",
            "i hope you had", "hope you had",
            "trust you are", "trust this finds"
        ]

        let isPleasantry = pleasantryPatterns.contains { lower.contains($0) }

        // Must be short (under ~20 words) and not substantive
        let wordCount = first.components(separatedBy: " ").count
        if isPleasantry && wordCount <= 20 {
            let remaining = sentences.dropFirst().map { $0 }.joined(separator: " ")
            return (first, remaining.trimmingCharacters(in: .whitespaces))
        }

        return (nil, text)
    }

    // MARK: - Zone 4: Closing Pleasantry

    private func extractClosingPleasantry(_ text: String) -> (pleasantry: String?, body: String) {
        let sentences = splitSentences(text)
        guard sentences.count >= 2 else { return (nil, text) }

        let last = sentences.last!
        let lower = last.lowercased()

        let closingPatterns = [
            "have a good", "have a great", "have a nice", "have a wonderful",
            "enjoy the rest", "enjoy your",
            "looking forward", "look forward to", "i look forward",
            "don't hesitate", "do not hesitate",
            "let me know if you have any", "let me know if there",
            "please don't hesitate", "please do not hesitate",
            "hope to hear from you", "hope to see you",
            "talk soon", "speak soon", "take care"
        ]

        let isClosing = closingPatterns.contains { lower.contains($0) }

        if isClosing {
            let body = sentences.dropLast().joined(separator: " ")
            // Clean up the closing — ensure it ends with a period
            var closing = last.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            closing += "."
            return (closing, body.trimmingCharacters(in: .whitespaces))
        }

        return (nil, text)
    }

    // MARK: - Zone 5+6: Sign-off + Name

    private func extractSignOff(_ text: String) -> (signOff: String?, body: String) {
        let words = text.components(separatedBy: " ")
        if words.count < 2 { return (nil, text) }

        let signOffPhrases = [
            "with kind regards", "with best regards",
            "best regards", "kind regards", "warm regards",
            "yours sincerely", "yours truly", "yours faithfully",
            "all the best",
            "many thanks", "thanks a lot", "thank you",
            "regards", "sincerely", "respectfully",
            "thanks", "cheers", "best", "warmly", "cordially"
        ]

        // Only search in the last 30 words
        let searchStart = max(0, words.count - 30)
        let searchArea = words[searchStart...].joined(separator: " ")
        let searchLower = searchArea.lowercased()

        for phrase in signOffPhrases {
            guard let range = searchLower.range(of: phrase) else { continue }

            let afterPhrase = String(searchArea[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)

            // Check what comes after the sign-off phrase
            let afterWords = afterPhrase
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
                .components(separatedBy: " ")
                .filter { !$0.isEmpty }

            // If 4+ words follow, or non-capitalized words follow, it's not a sign-off
            let allCapitalized = afterWords.allSatisfy { $0.first?.isUppercase == true }
            if afterWords.count > 3 || (!allCapitalized && !afterWords.isEmpty) {
                continue
            }

            // Build the sign-off block
            let phraseStart = searchArea[range.lowerBound...]
            let originalPhrase = String(phraseStart.prefix(phrase.count))
            var signOffBlock = originalPhrase
            if !signOffBlock.hasSuffix(",") {
                signOffBlock += ","
            }

            // Name directly below sign-off (no blank line between them)
            if !afterWords.isEmpty && allCapitalized {
                let name = afterWords.joined(separator: " ")
                signOffBlock += "\n" + name
            }

            // Extract body (everything before this sign-off)
            let bodyEnd = text.range(of: searchArea[range.lowerBound...].prefix(phrase.count),
                                        options: .backwards)
            let body: String
            if let bodyEnd = bodyEnd {
                body = String(text[..<bodyEnd.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            } else {
                body = text
            }

            return (signOffBlock, body)
        }

        return (nil, text)
    }

}
