/// FormatterTests — Comprehensive test suite for MessageFormatter and StructuredTextFormatter.
///
/// 105 test cases across 5 categories:
///   A: Body paragraph splitting (40 cases)
///   B: List detection (20 cases)
///   C: Greeting/sign-off/pleasantry extraction (20 cases)
///   D: Edge cases (20 cases)
///   E: Combined/complex scenarios (5 cases)
///
/// These tests define the SPECIFICATION for correct formatting. The formatter
/// implementation should be iterated until these pass at 90%+.
///
/// Self-contained: inlines all production types (same pattern as DiktaTests.swift).
/// When production code changes, the inlined code here MUST be updated to match.
///
/// Run via: cd dikta-macos && swift test --filter FormatterTests

import XCTest

// =============================================================================
// MARK: - Inlined production types
// =============================================================================

// -- TextHelpers.swift --

private let abbreviations: Set<String> = [
    "Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "Jr.", "Sr.", "St.",
    "e.g.", "i.e.", "etc.", "vs.", "approx.", "dept.", "govt.", "corp."
]

private func isFragment(_ sentence: String) -> Bool {
    if sentence.count <= 2 && sentence.hasSuffix(".") { return true }
    if abbreviations.contains(sentence) { return true }
    return false
}

func splitSentences(_ text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return [] }
    var sentences: [String] = []
    trimmed.enumerateSubstrings(in: trimmed.startIndex..<trimmed.endIndex, options: .bySentences) { substring, _, _, _ in
        if let sentence = substring {
            let cleaned = sentence.trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { sentences.append(cleaned) }
        }
    }
    var merged: [String] = []
    var carry = ""
    for sentence in sentences {
        if !carry.isEmpty {
            carry += " " + sentence
            if isFragment(sentence) { continue }
            merged.append(carry); carry = ""
        } else if isFragment(sentence) { carry = sentence }
        else { merged.append(sentence) }
    }
    if !carry.isEmpty {
        if merged.isEmpty { merged.append(carry) }
        else { merged[merged.count - 1] += " " + carry }
    }
    return merged
}

func trimItem(_ text: String) -> String {
    var result = text.trimmingCharacters(in: .whitespaces)
    if result.isEmpty { return "" }
    for prefix in ["and ", "or ", "but "] {
        if result.lowercased().hasPrefix(prefix) { result = String(result.dropFirst(prefix.count)); break }
    }
    if result.hasSuffix(".") { result = String(result.dropLast()) }
    result = result.prefix(1).uppercased() + result.dropFirst()
    return result.trimmingCharacters(in: .whitespaces)
}

func findPreamble(_ sentences: [String], beforeIndex: Int) -> String? {
    if beforeIndex <= 0 { return nil }
    return sentences[0..<beforeIndex].joined(separator: " ")
}

// -- TextFormatter.swift --
protocol TextFormatter { func format(_ text: String) -> String }

// -- FormatterStyle.swift --
enum FormatterStyle: String, CaseIterable { case message, structure }

// -- FormatterEngine.swift --
struct FormatterEngine {
    func format(_ text: String, style: FormatterStyle) -> String {
        switch style {
        case .message: return MessageFormatter().format(text)
        case .structure: return StructuredTextFormatter().format(text)
        }
    }
}

// -- StructuredTextFormatter.swift --
// IMPORTANT: This must mirror the production StructuredTextFormatter exactly.
// takt agents: update this when you change production code.

struct StructuredTextFormatter: TextFormatter {

    enum ContentType {
        case bulletList(items: [String], preamble: String?)
        case numberedList(items: [String], preamble: String?)
        case sections(groups: [(heading: String, body: String)])
        case paragraphs(groups: [[String]])
        case noChange
    }

    func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return ""  }

        // Already formatted?
        if trimmed.contains("\n- ") || trimmed.hasPrefix("- ")
            || trimmed.contains("\n1.") || trimmed.hasPrefix("1. ") { return trimmed }

        let sentences = splitSentences(trimmed)

        let contentType = analyze(sentences, fullText: trimmed)

        switch contentType {
        case .bulletList(let items, let preamble):
            return formatBullets(items, preamble: preamble)
        case .numberedList(let items, let preamble):
            return formatNumbered(items, preamble: preamble)
        case .sections(let groups):
            return formatSections(groups)
        case .paragraphs(let groups):
            return formatParagraphs(groups)
        case .noChange:
            return trimmed
        }
    }

    private func analyze(_ sentences: [String], fullText: String) -> ContentType {

        // Check A - Explicit enumeration

        let orderedMarkers = [
            "first", "firstly", "first of all",
            "second", "secondly", "third", "thirdly",
            "then", "next", "after that",
            "finally", "lastly", "last",
            "step one", "step two", "step three",
            "number one", "number two",
            "start by"
        ]

        let unorderedMarkers = [
            "also", "another", "another thing",
            "in addition", "plus", "on top of that"
        ]

        var orderedCount = 0

        var unorderedCount = 0
        var markerIndices: [Int] = []

        for (i, sentence) in sentences.enumerated() {

            let lower = sentence.lowercased()

            if orderedMarkers.contains(where: { lower.hasPrefix($0) }) {

                orderedCount += 1
                markerIndices.append(i)
            } else if unorderedMarkers.contains(where: { lower.hasPrefix($0) }) {

                unorderedCount += 1
                markerIndices.append(i)
            }
        }

        let totalMarkers = orderedCount + unorderedCount
        if totalMarkers >= 3 {
            let startIndex = markerIndices.first ?? 0

            let items = markerIndices.map { sentences[$0] }
            let preamble = findPreamble(sentences, beforeIndex: startIndex)

            if orderedCount > unorderedCount {

                return .numberedList(items: items, preamble: preamble)
            } else {

                return .bulletList(items: items, preamble: preamble)
            }
        }

        // Check for "and then" chains in a single sentence

        if sentences.count <= 2 {
            let joined = sentences.joined(separator: " ")

            let parts = joined.components(separatedBy: " and then ")
            if parts.count >= 3 {

                return .numberedList(items: parts, preamble: nil)
            }

            let commaParts = joined.components(separatedBy: ", then ")
            if commaParts.count >= 3 {

                return .numberedList(items: commaParts, preamble: nil)
            }
        }

        // Check B - Colon-list

        if let colonIndex = fullText.firstIndex(of: ":") {
            let afterColon = String(fullText[fullText.index(after: colonIndex)...])

                .trimmingCharacters(in: .whitespaces)

            let beforeColon = String(fullText[..<colonIndex])

            // Check if what follows is a comma-seperated list ending the sentence
            let items = afterColon

                .trimmingCharacters(in: CharacterSet(charactersIn: "."))

                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }

                .map { item -> String in

                    var cleaned = item
                    for prefix in ["and ", "or "] {

                        if cleaned.lowercased().hasPrefix(prefix) {
                            cleaned = String(cleaned.dropFirst(prefix.count))

                        }
                    }

                    return cleaned
                }
                .filter { !$0.isEmpty }
            if items.count >= 3 {

                return .bulletList(items: items, preamble: beforeColon + ":")
            }

        }

        // Check C - Homogeneous short sentences
        // Skip if any sentence starts with a topic-shift transition phrase — those should
        // be handled by the paragraph-splitting pass below instead.
        let topicShiftPrefixes = [
            "how about", "by the way", "on another note", "on a different note",
            "on the other hand", "one more thing", "besides that", "apart from that",
            "moving on", "additionally", "furthermore", "moreover", "separately",
            "regarding", "as for", "however", "that said", "anyway", "also",
            "okay", "ok", "yeah", "alright"
        ]
        let hasTopicShift = sentences.contains { s in
            let lower = s.lowercased()
            return topicShiftPrefixes.contains(where: { lower.hasPrefix($0) })
        }

        let allShort = sentences.allSatisfy { $0.components(separatedBy: " ").count < 15 }
        if allShort && sentences.count >= 3 && !hasTopicShift {

            let nonVerbStarts: Set<String> = [
                "i", "we", "he", "she", "it", "they", "you",
                "my", "our", "his", "her", "its", "their",
                "the", "a", "an", "in", "on", "at", "for", "with", "to",
                "from", "by", "of", "about", "and", "but", "or", "so", "yet",
                "this", "that", "these", "those", "one", "two", "first",
                "second", "each", "all", "most", "some", "many", "every",
                "several", "both", "neither", "either"
            ]

            let imperativeCount = sentences.filter { sentence in

                let firstWord = sentence.components(separatedBy: " ").first?
                    .lowercased()

                    .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,")) ?? ""
                return !nonVerbStarts.contains(firstWord)

            }.count

            let ratio = Double(imperativeCount) / Double(sentences.count)

            if ratio >= 0.6 {
                return .numberedList(items: sentences, preamble: nil)
            } else if sentences.count < 5 {
                return .bulletList(items: sentences, preamble: nil)
            }
            // For 5+ sentences with low imperative ratio, fall through to
            // paragraph splitting / long-text fallback below.

        }

        // Check D - Sections / Paragraph Splitting
        let transitionPhrases = [
            "how about",
            "by the way", "another thing", "on another note",
            "on a different note", "on the other hand",
            "in addition", "one more thing", "besides that",
            "apart from that", "moving on",
            "additionally", "furthermore", "moreover",
            "separately", "regarding", "as for",
            "also", "however", "that said", "anyway",
            "okay", "ok", "yeah", "alright"
        ]

        var groups: [[String]] = [[]]

        for sentence in sentences {
            let lower = sentence.lowercased()

            let isTransition = transitionPhrases.contains { lower.hasPrefix($0) }

            if isTransition && !groups.last!.isEmpty {
                groups.append([sentence])

            } else {
                groups[groups.count - 1].append(sentence)
            }
        }

        if groups.count >= 2 && groups.count <= 8 && !groups[0].isEmpty {
            // Use rich section format when all groups have multiple sentences
            if groups.allSatisfy({ $0.count >= 2 }) {
                let sectionGroups = groups.map { group -> (heading: String, body: String) in
                    let heading = extractHeading(from: group[0])
                    let body = group.joined(separator: " ")
                    return (heading: heading, body: body)
                }
                return .sections(groups: sectionGroups)
            }
            // Otherwise use plain paragraph breaks
            return .paragraphs(groups: groups)
        }

        // Check E - Long-text fallback: split at midpoint when many sentences
        if sentences.count >= 5 {
            let mid = sentences.count / 2
            let firstHalf = Array(sentences[0..<mid])
            let secondHalf = Array(sentences[mid...])
            return .paragraphs(groups: [firstHalf, secondHalf])
        }

        // Check F - No pattern
        return .noChange
    }

    private func extractHeading(from sentence: String) -> String {

        let skipWords: Set<String> = [
            "the", "a", "an", "we", "i", "our", "my",
            "need", "should", "must", "have", "is", "are",
            "to", "for", "of", "in", "on", "at", "by", "with",
            "regarding", "as", "also", "however", "additionally",
            "furthermore", "moreover", "separately", "anyway",
            "by the way", "on a different note", "on another note",
            "that said", "moving on"
        ]

        let words = sentence
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            .components(separatedBy: " ")

            .filter { !skipWords.contains($0.lowercased()) }

        let headingWords = Array(words.prefix(2))

        if headingWords.isEmpty { return "Section" }

        return headingWords

            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private let sequenceMarkers = [
        "first, ", "firstly, ", "first of all, ",
        "second, ", "secondly, ", "third, ", "thirdly, ",
        "also, ", "also ", "another thing, ", "another thing is ",
        "in addition, ", "plus, ", "plus ", "next, ", "next ",
        "finally, ", "lastly, ", "last, ", "on top of that, ",
        "then, ", "then ", "after that, ", "after that ",
        "start by ", "step one, ", "step two, ", "step three, ",
        "number one, ", "number two, "
    ]

    private func stripMarker(_ text: String) -> String {
        let lower = text.lowercased()
        for marker in sequenceMarkers {
            if lower.hasPrefix(marker) {
                return String(text.dropFirst(marker.count))
            }
        }
        return text
    }

    private func stripFiller(_ text: String) -> String {
        let lower = text.lowercased()
        let fillers = [
            "you need to ", "you should ", "you have to ",
            "you can ", "you "
        ]
        for filler in fillers {
            if lower.hasPrefix(filler) {
                return String(text.dropFirst(filler.count))
            }
        }
        return text
    }

    private func formatBullets(_ items: [String], preamble: String?) -> String {
        var result = ""
        if let p = preamble {
            result += p + "\n\n"
        }
        let bullets = items.map { "- " + trimItem(stripMarker($0)) }
        result += bullets.joined(separator: "\n")
        return result
    }

    private func formatNumbered(_ items: [String], preamble: String?) -> String {
        var result = ""
        if let p = preamble {
            result += p + "\n\n"
        }
        let steps = items.enumerated().map { (i, item) in
            "\(i + 1). " + trimItem(stripFiller(stripMarker(item)))
        }
        result += steps.joined(separator: "\n")
        return result
    }

    private func formatSections(_ groups: [(heading: String, body: String)]) -> String {
        return groups.map { "## \($0.heading)\n\n\($0.body)" }
                     .joined(separator: "\n\n")
    }

    private func formatParagraphs(_ groups: [[String]]) -> String {
        return groups
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: " ") }
            .joined(separator: "\n\n")
    }

}

// -- MessageFormatter.swift --
// IMPORTANT: This must mirror the production MessageFormatter exactly.
// takt agents: update this when you change production code.

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

// =============================================================================
// MARK: - A: Body Paragraph Splitting (40 cases)
// =============================================================================

final class BodyParagraphSplittingTests: XCTestCase {
    let f = StructuredTextFormatter()

    // --- A1: Topic shift via question ---
    func testA01_QuestionAfterStatement() { let r = f.format("I finished the report yesterday. The numbers look good. How about we schedule a review meeting for Thursday?"); XCTAssertTrue(r.contains("\n\n"), "Question should trigger paragraph break") }
    func testA02_MultipleTopicQuestions() { let r = f.format("The project is on track. We shipped the first milestone. How about we discuss the budget next? Also, when can we get the design files?"); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA03_RhetoricalQuestionSameTopic() { let r = f.format("The server went down at 3am. Can you believe it? We lost two hours of data."); XCTAssertTrue(r.contains("Can you believe it")) }
    func testA04_QuestionFollowedByAnswer() { let r = f.format("What did the client say? They approved the proposal. We can start next week."); XCTAssertTrue(r.contains("What did the client say")) }
    func testA05_HowAboutTopicShift() { let r = f.format("I fixed the login bug and deployed it. The tests are passing now. How about we tackle the search feature next? I think it needs a complete rewrite."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }

    // --- A2: Casual marker topic shifts ---
    func testA06_AnywayMarker() { let r = f.format("I spent three hours debugging that issue. The problem was a missing semicolon. Anyway, I also wanted to talk about the new hire."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA07_ByTheWayMarker() { let r = f.format("The deployment went smoothly. All services are healthy. By the way, did you see the email from marketing? They want to change the landing page."); XCTAssertTrue(r.contains("\n\nBy the way") || r.contains("\n\n## ")) }
    func testA08_OkayMovingOn() { let r = f.format("We need to finalize the API design. The endpoint names should be consistent. Moving on, the database migration needs to happen before Friday."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA09_AlsoTopicShift() { let r = f.format("The server migration is complete. All data has been transferred successfully. Also, we received the new security audit results and there are a few findings we need to address."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA10_HoweverContrast() { let r = f.format("The performance improvements are significant. Page load times dropped by 40 percent. However, we noticed that memory usage has increased on the backend servers."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA11_ThatSaidTransition() { let r = f.format("The prototype looks amazing. The animations are smooth and the colors are perfect. That said, we need to reconsider the navigation flow because users found it confusing."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA12_RegardingTopicIntro() { let r = f.format("The sprint went well overall. Regarding the performance issues, I've identified the root cause and it's a database query that needs optimization."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }

    // --- A3: No split needed ---
    func testA13_SingleTopicParagraph() { let r = f.format("The weather is nice today. The sun is shining and there are no clouds. It's a perfect day for a walk in the park."); XCTAssertEqual(r.components(separatedBy: "\n\n").count, 1, "Same topic, no split") }
    func testA14_TwoRelatedSentences() { let r = f.format("Please send me the report. I need it before noon."); XCTAssertEqual(r.components(separatedBy: "\n\n").count, 1) }
    func testA15_ThreeRelatedSentences() { let r = f.format("The meeting is at 3pm. It will be in the conference room. Please bring your laptop."); XCTAssertEqual(r.components(separatedBy: "\n\n").count, 1) }

    // --- A4: Real dictation patterns ---
    func testA16_StatusThenPersonal() { let r = f.format("So regarding your questions, I have fixed everything and it's up and running. How about we set up a meeting for tomorrow? I'm eager to get going with our latest project. How are the wife and the kids by the way? Okay enough about that. Yeah, I'm heading out to the beach."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 3) }
    func testA17_ProjectUpdate() { let r = f.format("I wanted to give you an update on the project. We finished the authentication module yesterday. The tests are all green. Moving on to the next thing, we need to discuss the payment integration. I've been looking at Stripe and it seems like a good fit."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA18_MeetingRecap() { let r = f.format("The meeting was productive. We agreed on the timeline and the budget. However, there's still disagreement about the tech stack. John wants to use React but Maria prefers Vue. Anyway, we'll decide next week."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }

    // --- A5: Long text fallback ---
    func testA19_LongTextNoMarkers() { let r = f.format("The system processes requests through a queue. Each request is validated before processing. Invalid requests are logged and rejected. The processing engine runs on three servers. Load balancing distributes requests evenly. Response times average under 200 milliseconds."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2, "Long text should split") }
    func testA20_VeryLongDictation() { let r = f.format("I woke up this morning and checked my email. There were about 50 new messages. Most of them were spam but a few were important. I replied to the client and forwarded the contract to legal. Then I had breakfast and drove to the office. Traffic was terrible as usual. I got to the office around 9:30. The first meeting was at 10. We discussed the quarterly results. Revenue is up 15 percent. Expenses are also up but less than expected. The CEO was happy with the numbers."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }

    // --- A6: Transition NOT at sentence start ---
    func testA21_HoweverMidSentence() { let r = f.format("The results were however not what we expected. The data showed a different pattern."); XCTAssertTrue(r.contains("however not")) }
    func testA22_AlsoMidSentence() { let r = f.format("She also mentioned the budget concerns. The team agreed."); XCTAssertEqual(r.components(separatedBy: "\n\n").count, 1) }

    // --- A7: Question clusters ---
    func testA23_ConsecutiveRelatedQuestions() { let r = f.format("Do you want to go with the blue design? Or should we stick with the green one? What does the client prefer?"); XCTAssertEqual(r.components(separatedBy: "\n\n").count, 1, "Related questions stay together") }
    func testA24_QuestionsThenStatement() { let r = f.format("Have you seen the latest designs? What do you think? I personally like the minimalist approach."); XCTAssertTrue(r.contains("I personally like")) }

    // --- A8: Discourse fillers (NOT topic shifts) ---
    func testA25_WellAtStart() { let r = f.format("Well the thing is we need more time. The deadline is too tight. I don't think we can make it."); XCTAssertTrue(r.contains("Well the thing is")) }
    func testA26_SoAsConnector() { let r = f.format("The tests failed. So we need to fix the build before deploying."); XCTAssertEqual(r.components(separatedBy: "\n\n").count, 1) }

    // --- A9: Formal transitions ---
    func testA27_FormalTransitions() { let r = f.format("The quarterly results exceeded expectations. Revenue grew by 12 percent year over year. Furthermore, our customer retention rate improved significantly. Additionally, we expanded into three new markets during this period."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA28_FurthermoreMoreover() { let r = f.format("We completed the migration ahead of schedule. Furthermore, we identified and fixed two critical bugs. Moreover, the team documented the entire process for future reference."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }

    // --- A10: More topic markers ---
    func testA29_AsForTopicIntro() { let r = f.format("The frontend team is on schedule. As for the backend, we're behind by about three days due to the authentication issue."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA30_OneMoreThing() { let r = f.format("I think we covered everything for the release. The QA team signed off. One more thing, we need to update the changelog before pushing to production."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA31_BesidesMarker() { let r = f.format("The core feature is complete and tested. Besides that, I've also added some quality of life improvements to the admin panel."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA32_ApartFromThat() { let r = f.format("The main deployment is done. Apart from that, we still need to set up the monitoring dashboards."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA33_OnTheOtherHand() { let r = f.format("The desktop version works perfectly. On the other hand, the mobile experience needs significant work on the responsive layout."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA34_OnAnotherNote() { let r = f.format("The release went smoothly. On another note, the client requested a meeting to discuss phase two features."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }
    func testA35_Separately() { let r = f.format("The database backup completed at midnight. Separately, we should discuss the new data retention policy."); XCTAssertGreaterThanOrEqual(r.components(separatedBy: "\n\n").count, 2) }

    // --- A11: Content preservation ---
    func testA36_AllContentPreserved() { let input = "The server is stable. However, the memory leak we found needs to be patched. Also, consider upgrading the load balancer."; let r = f.format(input); for w in ["server", "stable", "memory", "leak", "patched", "upgrading", "load balancer"] { XCTAssertTrue(r.contains(w), "'\(w)' should be preserved") } }
    func testA37_PunctuationPreserved() { let input = "Did you see that? It's amazing! We should tell everyone."; let r = f.format(input); XCTAssertTrue(r.contains("?") && r.contains("!")) }
    func testA38_NumbersPreserved() { let input = "Revenue was $1.2M in Q3. However, expenses rose to $800K."; let r = f.format(input); XCTAssertTrue(r.contains("$1.2M") && r.contains("$800K")) }

    // --- A12: Misc ---
    func testA39_MixedLongShort() { let r = f.format("I need to tell you about the infrastructure changes we made over the weekend because they affect your deployment pipeline. The DNS records changed. Update your config."); XCTAssertTrue(r.contains("DNS records changed")) }
    func testA40_CasualRambling() { let r = f.format("Yeah so I was thinking about the project. It's going pretty well actually. By the way, the client loved the demo we showed them last week. That was a huge win for us."); XCTAssertTrue(r.contains("By the way") && r.contains("huge win")) }
}

// =============================================================================
// MARK: - B: List Detection (20 cases)
// =============================================================================

final class ListDetectionTests: XCTestCase {
    let f = StructuredTextFormatter()

    // --- B1: Explicit ordinals ---
    func testB01_FirstSecondThird() { let r = f.format("Here's what we need to do. First, create the database schema. Second, build the API endpoints. Third, implement the frontend."); XCTAssertTrue(r.contains("1.") && r.contains("2.") && r.contains("3.")) }
    func testB02_FirstlySecondlyThirdly() { let r = f.format("Firstly, we need to assess the situation. Secondly, we should develop a plan. Thirdly, we execute and monitor."); XCTAssertTrue(r.contains("1.")) }
    func testB03_StepOneStepTwo() { let r = f.format("Step one, open the application. Step two, navigate to settings. Step three, click on advanced options."); XCTAssertTrue(r.contains("1.")) }
    func testB04_NumberOneNumberTwo() { let r = f.format("Number one, we need better documentation. Number two, we need automated tests. Number three, we need a CI pipeline."); XCTAssertTrue(r.contains("1.")) }
    func testB05_StartByThenNextFinally() { let r = f.format("Start by backing up the database. Then migrate the schema. Next, update the application code. After that, run the tests. Finally, deploy to production."); XCTAssertTrue(r.contains("1.")) }

    // --- B2: Colon-list ---
    func testB06_ColonCommaList() { let r = f.format("We need the following items: notebooks, pens, markers, and sticky notes."); XCTAssertTrue(r.contains("- ")) }
    func testB07_ColonListWithOr() { let r = f.format("The options are: upgrade the existing system, build a new one from scratch, or hire a vendor."); XCTAssertTrue(r.contains("- ")) }
    func testB08_ColonInTimeNotList() { let r = f.format("The time is 3:30. We should leave soon."); XCTAssertFalse(r.contains("- "), "Time colon not a list") }

    // --- B3: Implicit parallel structure ---
    func testB09_RepeatedImperatives() { let r = f.format("Check the logs. Restart the server. Clear the cache. Update the configuration. Verify the deployment."); XCTAssertTrue(r.contains("- ") || r.contains("1."), "Imperatives should become list") }
    func testB10_RepeatedWeNeed() { let r = f.format("We need better testing. We need faster deployments. We need clearer documentation. We need stronger security."); XCTAssertTrue(r.contains("- "), "Parallel we-need should become bullets") }
    func testB11_AndThenChain() { let r = f.format("Take the bus to the station and then transfer to the train and then walk two blocks and then you'll see the office."); XCTAssertTrue(r.contains("1.")) }

    // --- B4: Unordered markers ---
    func testB12_AlsoAnotherPlus() { let r = f.format("We should improve the UI. Also, the API needs better error handling. Another thing is the deployment process needs automation. Plus, we should add monitoring."); XCTAssertTrue(r.contains("- ")) }
    func testB13_InAdditionOnTopOfThat() { let r = f.format("The salary is competitive. In addition, we offer health insurance. On top of that, there's a generous vacation policy. Plus, you get stock options."); XCTAssertTrue(r.contains("- ")) }

    // --- B5: Mixed list + prose ---
    func testB14_PreambleThenList() { let r = f.format("I've identified several issues with the current system. First, the authentication is too slow. Second, the database queries are not optimized. Third, there's no caching layer."); XCTAssertTrue(r.contains("1.") && r.contains("I've identified")) }
    func testB15_ListThenConclusion() { let r = f.format("First, back up the data. Second, run the migration. Third, verify the results. That should take about an hour."); XCTAssertTrue(r.contains("1.")) }

    // --- B6: False positive avoidance ---
    func testB16_FirstInNarrative() { let r = f.format("The first thing I noticed was the broken window. The room was a mess. Papers were scattered everywhere."); XCTAssertFalse(r.contains("1.") && r.contains("2."), "Narrative first not a list") }
    func testB17_AlsoInNarrative() { let r = f.format("I went to the store and also picked up some flowers. They looked beautiful."); XCTAssertEqual(r.components(separatedBy: "\n\n").count, 1) }
    func testB18_ThenInNarrative() { let r = f.format("I woke up and then realized it was Saturday. I went back to sleep."); XCTAssertFalse(r.contains("1.")) }

    // --- B7: Mixed + chain ---
    func testB19_MixedMarkers() { let r = f.format("There are a few things to discuss. First, the budget needs approval. Also, we need to hire two more developers. In addition, the office lease is up for renewal. Finally, we should plan the holiday party."); XCTAssertTrue(r.contains("- ") || r.contains("1.")) }
    func testB20_ThenCommaChain() { let r = f.format("Open the terminal, then navigate to the project directory, then run npm install, then start the dev server."); XCTAssertTrue(r.contains("1.")) }
}

// =============================================================================
// MARK: - C: Greeting/Sign-off/Pleasantry (20 cases)
// =============================================================================

final class GreetingSignOffTests: XCTestCase {
    let f = MessageFormatter()

    // --- C1: Greeting variations ---
    func testC01_BareHi() { let r = f.format("Hi, I wanted to ask about the project timeline. Thanks, Alex"); XCTAssertTrue(r.hasPrefix("Hi,")) }
    func testC02_HiWithName() { let r = f.format("Hi John, I wanted to ask about the project timeline. Thanks, Alex"); XCTAssertTrue(r.hasPrefix("Hi John,")) }
    func testC03_HelloExclamation() { let r = f.format("Hello! I'm reaching out about the partnership proposal. Best regards, Maria"); XCTAssertTrue(r.hasPrefix("Hello!")) }
    func testC04_DearFormal() { let r = f.format("Dear Mr. Thompson, I am writing to inquire about the open position. Sincerely, James"); XCTAssertTrue(r.hasPrefix("Dear Mr. Thompson,")) }
    func testC05_GoodMorning() { let r = f.format("Good morning, just a quick update on the server status. Cheers, DevOps"); XCTAssertTrue(r.hasPrefix("Good morning,")) }
    func testC06_HeyNameExclamation() { let r = f.format("Hey Sarah! How's it going? I was wondering if you had time for a call. Talk soon, Mike"); XCTAssertTrue(r.hasPrefix("Hey Sarah!")) }
    func testC07_NoGreeting() { let r = f.format("The report is attached. Please review and let me know. Thanks, Pat"); XCTAssertTrue(r.hasPrefix("The report")) }
    func testC08_HiMultiWordName() { let r = f.format("Hi Sarah Jane, could you send me the latest draft? Best, Tom"); XCTAssertTrue(r.contains("Sarah") && r.contains("Jane")) }

    // --- C2: Opening pleasantry ---
    func testC09_HopeYoureWell() { let r = f.format("Hi, I hope you're doing well. I wanted to discuss the contract. Best, Sam"); XCTAssertTrue(r.contains("hope you're doing well")) }
    func testC10_HowAreThings() { let r = f.format("Hi, how are things with you? I was wondering about the deadline. Thanks, Emma"); XCTAssertTrue(r.contains("how are things")) }
    func testC11_ThanksForReaching() { let r = f.format("Hi, thanks for reaching out. I'd be happy to discuss. Best, Chris"); XCTAssertTrue(r.contains("thanks for reaching out")) }
    func testC12_NoPleasantry() { let r = f.format("Hi, the server is down. Can you check immediately? Thanks, Ops"); XCTAssertTrue(r.contains("the server is down")) }

    // --- C3: Sign-off variations ---
    func testC13_BestRegards() { let r = f.format("Hi, the project is complete. Best regards, Sebastian"); XCTAssertTrue(r.contains("Best regards,\nSebastian")) }
    func testC14_Thanks() { let r = f.format("Hi, can you send me the file? Thanks, Alex"); XCTAssertTrue(r.contains("Thanks,\nAlex")) }
    func testC15_Cheers() { let r = f.format("Hi, the update is live. Cheers, DevTeam"); XCTAssertTrue(r.contains("Cheers,")) }
    func testC16_NoSignOff() { let r = f.format("Hi, I'll be there at 3pm."); XCTAssertTrue(r.contains("I'll be there")) }

    // --- C4: Closing pleasantry ---
    func testC17_HaveAGoodDay() { let r = f.format("Hi, the meeting is confirmed for 2pm. Have a good day. Best, Lisa"); XCTAssertTrue(r.contains("Have a good day.")) }
    func testC18_LookingForward() { let r = f.format("Hi, I'll send the proposal by Friday. Looking forward to hearing from you. Best regards, David"); XCTAssertTrue(r.contains("Looking forward to hearing from you.")) }
    func testC19_LetMeKnow() { let r = f.format("Hi, I've updated the document with your feedback. Let me know if you have any questions. Thanks, Rachel"); XCTAssertTrue(r.contains("Let me know if you have any questions.")) }
    func testC20_SignOffNoName() { let r = f.format("Hi, the documents are attached. Best regards"); XCTAssertTrue(r.contains("Best regards,")) }
}

// =============================================================================
// MARK: - D: Edge Cases (20 cases)
// =============================================================================

final class EdgeCaseTests: XCTestCase {
    let mf = MessageFormatter()
    let sf = StructuredTextFormatter()
    let engine = FormatterEngine()

    // --- D1: Degenerate inputs ---
    func testD01_EmptyString() { XCTAssertEqual(mf.format(""), ""); XCTAssertEqual(sf.format(""), "") }
    func testD02_SingleWord() { XCTAssertEqual(mf.format("Hello"), "Hello"); XCTAssertEqual(sf.format("Hello"), "Hello") }
    func testD03_SingleSentence() { let i = "The quick brown fox jumps over the lazy dog."; XCTAssertEqual(mf.format(i), i); XCTAssertEqual(sf.format(i), i) }
    func testD04_WhitespaceOnly() { XCTAssertEqual(mf.format("   "), ""); XCTAssertEqual(sf.format("   "), "") }
    func testD05_TwoWords() { XCTAssertEqual(mf.format("Thank you"), "Thank you") }

    // --- D2: Idempotency ---
    func testD06_MessageIdempotent() { let i = "Hi John, I wanted to follow up on the meeting. We discussed the budget and the timeline. Have a good day. Best regards, Sarah"; let p1 = mf.format(i); let p2 = mf.format(p1); XCTAssertEqual(p1, p2) }
    func testD07_StructureIdempotent() { let i = "First, check the logs. Second, restart the server. Third, verify the fix."; let p1 = sf.format(i); let p2 = sf.format(p1); XCTAssertEqual(p1, p2) }
    func testD08_AlreadyFormattedBullets() { let i = "Tasks:\n\n- Check logs\n- Restart server\n- Verify fix"; XCTAssertEqual(sf.format(i), i) }
    func testD09_AlreadyFormattedNumbered() { let i = "Steps:\n\n1. Check logs\n2. Restart server\n3. Verify fix"; XCTAssertEqual(sf.format(i), i) }

    // --- D3: No formatting needed ---
    func testD10_SimpleStatement() { XCTAssertEqual(mf.format("I agree with your suggestion."), "I agree with your suggestion.") }
    func testD11_ShortQuestion() { XCTAssertEqual(mf.format("When is the meeting?"), "When is the meeting?") }

    // --- D4: Content preservation ---
    func testD12_AllQuestionsPreserved() { let r = mf.format("What time is the meeting? Where is it being held? Do I need to bring anything? Who else is attending?"); XCTAssertTrue(r.contains("What time") && r.contains("Where") && r.contains("Who")) }
    func testD13_ExclamationsPreserved() { let r = mf.format("Great news! The project launched! Users love it! We hit our targets!"); XCTAssertTrue(r.contains("Great news!")) }
    func testD14_NumbersPreserved() { let r = mf.format("The budget is $50,000. We need 3 developers. The deadline is March 15th."); XCTAssertTrue(r.contains("$50,000") && r.contains("March 15th")) }
    func testD15_AbbreviationsPreserved() { let r = mf.format("Dr. Smith called about the project. He said e.g. the timeline needs to change. Mrs. Johnson agreed."); XCTAssertTrue(r.contains("Dr. Smith") && r.contains("e.g.")) }

    // --- D5: Mixed zones ---
    func testD16_GreetingListSignOff() { let r = mf.format("Hi Team, here's the plan. First, review the code. Second, run the tests. Third, deploy to staging. Best regards, Lead Dev"); XCTAssertTrue(r.contains("Hi Team,") && r.contains("Best regards,")) }
    func testD17_FullSixZone() { let r = mf.format("Hi Sarah, hope you're doing well. I wanted to discuss the quarterly review. The numbers look promising and we're ahead of schedule. Looking forward to your feedback. Best regards, Tom"); XCTAssertTrue(r.contains("Hi Sarah,") && r.contains("hope you're doing well") && r.contains("quarterly review") && r.contains("Looking forward") && r.contains("Best regards,") && r.contains("Tom")) }

    // --- D6: No double punctuation ---
    func testD18_NoDoublePunctuation() { let r = mf.format("Hi, how are things with you? I was wondering if you would like to grab a coffee tomorrow? Have a good day, Best regards Sebastian"); XCTAssertFalse(r.contains(",.") || r.contains(".,") || r.contains("..") || r.contains(",,")) }

    // --- D7: Engine routing ---
    func testD19_EngineMessageStyle() { let r = engine.format("Hi, the report is ready. Best, Alex", style: .message); XCTAssertTrue(r.contains("Hi,")) }
    func testD20_EngineStructureStyle() { let r = engine.format("First, check logs. Second, restart. Third, verify.", style: .structure); XCTAssertTrue(r.contains("1.")) }

    // --- D8: Session regression tests ---
    func testD21_SessionInput1() { let r = mf.format("Hi, how are things with you? I was wondering if you would like to grab a coffee tomorrow? Have a good day, Best regards Sebastian"); XCTAssertTrue(r.contains("Hi,") && r.contains("Best regards,") && r.contains("Sebastian") && r.contains("Have a good day")) }
    func testD22_SessionInput2() { let r = mf.format("Hi Rickad! So regarding your questions, I have fixed everything and it's up and running. How about we set up a meeting for tomorrow? I'm eager to get going with our latest project. How are the wife and the kids by the way? Okay enough about that. Yeah, I'm heading out to the beach. Have a good day. Best regards, Sebastian."); XCTAssertTrue(r.contains("Hi Rickad!") && !r.contains("Hi Rickad! So,") && r.contains("Best regards,") && r.contains("Sebastian")) }
}

// =============================================================================
// MARK: - E: Combined/Complex Scenarios (5 cases)
// =============================================================================

final class CombinedScenarioTests: XCTestCase {
    let mf = MessageFormatter()
    let sf = StructuredTextFormatter()

    func testE01_LongBusinessEmail() { let r = mf.format("Dear Mr. Johnson, I hope this message finds you well. I'm writing to follow up on our conversation from last week about the partnership opportunity. We've reviewed the terms and everything looks good on our end. However, we'd like to request a few modifications to the payment schedule. Furthermore, our legal team has some questions about the liability clause. Could you arrange a meeting with your legal department? Looking forward to hearing from you. Kind regards, Sarah Chen"); XCTAssertTrue(r.contains("Dear Mr. Johnson,") && r.contains("hope this message finds you well") && r.contains("Looking forward") && r.contains("Kind regards,") && r.contains("Sarah Chen")) }

    func testE02_CasualSlack() { let r = mf.format("Hey, just wanted to let you know the deploy is done. Everything looks good so far. By the way, the standup is moved to 2pm tomorrow. Cheers"); XCTAssertTrue(r.contains("Hey,") && r.contains("Cheers,")) }

    func testE03_InstructionListWithContext() { let r = sf.format("I need you to do a few things before the release. First, run the full test suite. Second, update the version number. Third, create the changelog. Finally, tag the release in Git."); XCTAssertTrue(r.contains("1.") && r.contains("I need you")) }

    func testE04_BulletOptions() { let r = sf.format("For the tech stack we have several options: React with TypeScript, Vue with JavaScript, Angular with TypeScript, and Svelte with TypeScript."); XCTAssertTrue(r.contains("- ")) }

    func testE05_TrivialNoChange() { XCTAssertEqual(mf.format("See you at 3pm."), "See you at 3pm.") }
}

// =============================================================================
// MARK: - Existing Phase 1-3 tests (preserved)
// =============================================================================

class SplitSentencesTests: XCTestCase {
    func testSimpleTwoSentences() { XCTAssertEqual(splitSentences("Hello. World."), ["Hello.", "World."]) }
    func testAbbreviation() { XCTAssertEqual(splitSentences("Dr. Smith went home. He was tired."), ["Dr. Smith went home.", "He was tired."]) }
    func testMixedPunctuation() { XCTAssertEqual(splitSentences("What? Really! Yes."), ["What?", "Really!", "Yes."]) }
    func testDecimalNumber() { XCTAssertEqual(splitSentences("Version 1.0 is out. Update now."), ["Version 1.0 is out.", "Update now."]) }
    func testEllipsis() { XCTAssertEqual(splitSentences("She said hello... Then she left."), ["She said hello...", "Then she left."]) }
    func testSingleSentence() { XCTAssertEqual(splitSentences("One sentence."), ["One sentence."]) }
    func testEmptyString() { XCTAssertEqual(splitSentences(""), []) }
    func testWhitespaceOnly() { XCTAssertEqual(splitSentences("   "), []) }
    func testNoPeriod() { XCTAssertEqual(splitSentences("No period at the end"), ["No period at the end"]) }
    func testCommonAbbreviations() { XCTAssertEqual(splitSentences("Check e.g. the docs. Then proceed."), ["Check e.g. the docs.", "Then proceed."]) }
    func testInitials() { XCTAssertEqual(splitSentences("J. K. Rowling wrote Harry Potter. It sold millions."), ["J. K. Rowling wrote Harry Potter.", "It sold millions."]) }
}

class TrimItemTests: XCTestCase {
    func testBasicTrim() { XCTAssertEqual(trimItem("  buy milk.  "), "Buy milk") }
    func testLeadingAnd() { XCTAssertEqual(trimItem("and fix the bug."), "Fix the bug") }
    func testLeadingOr() { XCTAssertEqual(trimItem("or skip this step."), "Skip this step") }
    func testLeadingBut() { XCTAssertEqual(trimItem("but not this one."), "Not this one") }
    func testKeepsQuestionMark() { XCTAssertEqual(trimItem("is it ready?"), "Is it ready?") }
    func testKeepsExclamation() { XCTAssertEqual(trimItem("wow!"), "Wow!") }
    func testAlreadyCapitalized() { XCTAssertEqual(trimItem("Already capitalized."), "Already capitalized") }
    func testEmptyAfterTrim() { XCTAssertEqual(trimItem("  "), "") }
}

class FindPreambleTests: XCTestCase {
    func testPreambleExists() { XCTAssertEqual(findPreamble(["We need three things.", "Buy milk.", "Buy eggs."], beforeIndex: 1), "We need three things.") }
    func testNoPreamble() { XCTAssertNil(findPreamble(["Buy milk.", "Buy eggs.", "Buy bread."], beforeIndex: 0)) }
    func testMultiSentencePreamble() { XCTAssertEqual(findPreamble(["Intro one.", "Intro two.", "First item.", "Second item."], beforeIndex: 2), "Intro one. Intro two.") }
}
