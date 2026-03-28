import Foundation

struct MessageFormatter: TextFormatter {
    func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }

        let sentences = splitSentences(trimmed)
        if sentences.count <= 1 { return trimmed  }
        
        let (greeting, afterGreeting) = extractGreeting(trimmed)
        let (signOff, body) = extractSignOff(afterGreeting)
        let structuredBody = structureBody(body)

        var parts: [String] = []
        if let g = greeting { parts.append(g) }
        parts.append(structuredBody)
        if let s = signOff { parts.append(s) }

        return parts.joined(separator: "\n\n")
    }

    private func extractGreeting(_ text: String) -> (greeting: String?, remaining: String) {
        let lower = text.lowercased()

        let greetingPhrases = [
            "good morning", "good afternoon", "good evening",
            "hello there", "hey there", "hi there",
            "dear", "hello", "hey", "hi"
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

        // Capture name: 0-3 consecutive capitalized words or titles
        let titles: Set<String> = ["Mr.",  "Mrs.", "Ms.", "Dr.", "Prof."]
        var nameWords: [String] = []
        var temp = remaining

        // Skip comma right after greeting (e.g., "Hi, how are you")
        if temp.hasPrefix(",") {
            remaining = String(temp.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            let greetingLine = text.prefix(phrase.count)
                .prefix(1).uppercased() + text.dropFirst().prefix(phrase.count - 1)
            return (String(greetingLine) + ",", remaining)
        }

        for _ in 0..<3 {
            let words = temp.components(separatedBy: " ")
            guard let first = words.first, !first.isEmpty else { break }

            let isTitle = titles.contains(first)
            let isCapitalized = first.first?.isUppercase == true

            if isTitle || isCapitalized {
                nameWords.append(first)
                temp = words.dropFirst().joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)

                // If word ends with comma, name is done
                if first.hasSuffix(",") {
                    temp = temp.trimmingCharacters(in: .whitespaces)
                    break
                }
            } else {
                break
            }
        }

        // Build the greeting line
        let originalPhrase = String(text.prefix(phrase.count))
        var greetingLine = originalPhrase
        if !nameWords.isEmpty {
            let nameStr = nameWords.joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: ","))
            greetingLine += " " + nameStr
        }
        if !greetingLine.hasSuffix(",") {
            greetingLine += ","
        }

        remaining = temp.trimmingCharacters(in: .whitespaces)

        // Capitalize first letter of remaining
        if !remaining.isEmpty {
            remaining = remaining.prefix(1).uppercased()
                + remaining.dropFirst()
        }

        return (greetingLine, remaining)
    }

    private func extractSignOff(_ text: String) -> (signOff: String?, body: String) {
        let words = text.components(separatedBy: " ")
        if words.count < 2 { return (nil, text)  }

        let signOffPhrases = [
            "best regards", "kind regards", "warm regards",
            "yours sincerely", "yours truly",
            "all the best", "talk soon", "speak soon", "take care",
            "many thanks", "thanks a lot", "thank you",
            "regards", "sincerely", "thanks", "cheers", "best"
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
                .trimmingCharacters(in: CharacterSet(charactersIn: ","))
                .components(separatedBy: " ")
                .filter { !$0.isEmpty }

            // If 4+ non-name words follow, it's not a sign-off
            let allCapitalized = afterWords.allSatisfy { $0.first?.isUppercase == true }
            if afterWords.count > 3 || (!allCapitalized && !afterWords.isEmpty) {
                continue
            }

            // Build the sign-off block
            let phraseStart = searchArea[range.lowerBound...]
            let originalPhrase = String(phraseStart.prefix(phrase.count))
            var signOffBlock = originalPhrase

            // Handle name after sign-off
            if !afterWords.isEmpty && allCapitalized {
                let name = afterWords.joined(separator: " ")
                if !signOffBlock.hasSuffix(",") {
                    signOffBlock += ","
                }
                signOffBlock += "\n" + name
            }


            // Extract body (everything before this sign-off)
            let bodyEnd = text.range(of: searchArea[range.lowerBound...].prefix(phrase.count),
                                        options: .backwards)
            let body: String
            if let bodyEnd = bodyEnd {
                body = String(text[..<bodyEnd.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "."
            } else {
                body = text
            }

            return (signOffBlock, body)
        }

        return (nil, text)
    }

    private func structureBody(_ text: String) -> String {
        let sentences = splitSentences(text)
        if sentences.count <= 1 { return text }

        let transitionPhrases = [
            "by the way", "another thing", "on another note",
            "on a different note", "on the other hand",
            "in addition", "one more thing", "besides that",
            "apart from that", "moving on", 
            "additionally", "furthermore", "moreover",
            "separately", "regarding", "as for",
            "also", "however", "that said", "anyway"
        ]

        // Group sentences into paragraphs by splitting on transition words
        var paragraphs: [[String]] = [[]]

        for sentence in sentences {
            let lower = sentence.lowercased()
            let startsWithTransition = transitionPhrases.contains { lower.hasPrefix($0) }

            if startsWithTransition && !paragraphs.last!.isEmpty {
                paragraphs.append([sentence])
            } else {
                paragraphs[paragraphs.count - 1].append(sentence)
            }
        }

        // Fallback: if no transitions found and text is long, split every 3 sentences
        if paragraphs.count == 1 && sentences.count > 4 {
            paragraphs = []
            for i in stride(from: 0, to: sentences.count, by: 3) {
                let end = min(i + 3, sentences.count)
                paragraphs.append(Array(sentences[i..<end]))
            }
        }

        // Keep question cluster together
        var merged: [[String]] = [paragraphs[0]]
        for i in 1..<paragraphs.count {
            let prevLast = merged.last?.last ?? ""
            let currFirst = paragraphs[i].first?.lowercased() ?? ""

            if prevLast.hasSuffix("?") &&
                (currFirst.hasPrefix("or ") || currFirst.hasPrefix("and ") ||
                currFirst.hasPrefix("what about") || currFirst.hasPrefix("how about") ||
                currFirst.hasPrefix("should i")) {
                merged[merged.count - 1].append(contentsOf: paragraphs[i])
            } else {
                merged.append(paragraphs[i])
            }
        }

        return merged.map { $0.joined(separator: " ") }
                    .joined(separator: "\n\n")
    }
}








