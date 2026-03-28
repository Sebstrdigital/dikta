/// FormatterTests — Unit tests for the formatter helpers.
///
/// Since the main Dikta target is an executable (not a library), we duplicate
/// the helper functions here. If you change the production code, update these too.
///
/// Run via: cd dikta-macos && swift test

import XCTest

// MARK: - Inlined production functions (mirrors Formatter/TextHelpers.swift)

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
    trimmed.enumerateSubstrings(
        in: trimmed.startIndex..<trimmed.endIndex,
        options: .bySentences
    ) { substring, _, _, _ in
        if let sentence = substring {
            let cleaned = sentence.trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty {
                sentences.append(cleaned)
            }
        }
    }

    // Merge single-letter "sentences" (initials like J. K.) back into the next sentence
    var merged: [String] = []
    var carry = ""
    for sentence in sentences {
        if !carry.isEmpty {
            carry += " " + sentence
            if isFragment(sentence) {
                continue
            }
            merged.append(carry)
            carry = ""
        } else if isFragment(sentence) {
            carry = sentence
        } else {
            merged.append(sentence)
        }
    }
    if !carry.isEmpty {
        if merged.isEmpty {
            merged.append(carry)
        } else {
            merged[merged.count - 1] += " " + carry
        }
    }

    return merged
}

func trimItem(_ text: String) -> String {
    var result = text.trimmingCharacters(in: .whitespaces)
    if result.isEmpty { return "" }

    for prefix in ["and ", "or ", "but "] {
        if result.lowercased().hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
            break
        }
    }

    if result.hasSuffix(".") {
        result = String(result.dropLast())
    }

    result = result.prefix(1).uppercased() + result.dropFirst()

    return result.trimmingCharacters(in: .whitespaces)
}

func findPreamble(_ sentences: [String], beforeIndex: Int) -> String? {
    if beforeIndex <= 0 { return nil }
    let preamble = sentences[0..<beforeIndex].joined(separator: " ")
    return preamble
}

// MARK: - splitSentences Tests

class SplitSentencesTests: XCTestCase {

    func testSimpleTwoSentences() {
        XCTAssertEqual(splitSentences("Hello. World."), ["Hello.", "World."])
    }

    func testAbbreviation() {
        XCTAssertEqual(
            splitSentences("Dr. Smith went home. He was tired."),
            ["Dr. Smith went home.", "He was tired."]
        )
    }

    func testMixedPunctuation() {
        XCTAssertEqual(
            splitSentences("What? Really! Yes."),
            ["What?", "Really!", "Yes."]
        )
    }

    func testDecimalNumber() {
        XCTAssertEqual(
            splitSentences("Version 1.0 is out. Update now."),
            ["Version 1.0 is out.", "Update now."]
        )
    }

    func testEllipsis() {
        XCTAssertEqual(
            splitSentences("She said hello... Then she left."),
            ["She said hello...", "Then she left."]
        )
    }

    func testSingleSentence() {
        XCTAssertEqual(splitSentences("One sentence."), ["One sentence."])
    }

    func testEmptyString() {
        XCTAssertEqual(splitSentences(""), [])
    }

    func testWhitespaceOnly() {
        XCTAssertEqual(splitSentences("   "), [])
    }

    func testNoPeriod() {
        XCTAssertEqual(splitSentences("No period at the end"), ["No period at the end"])
    }

    func testCommonAbbreviations() {
        XCTAssertEqual(
            splitSentences("Check e.g. the docs. Then proceed."),
            ["Check e.g. the docs.", "Then proceed."]
        )
    }

    func testInitials() {
        XCTAssertEqual(
            splitSentences("J. K. Rowling wrote Harry Potter. It sold millions."),
            ["J. K. Rowling wrote Harry Potter.", "It sold millions."]
        )
    }
}

// MARK: - trimItem Tests

class TrimItemTests: XCTestCase {

    func testBasicTrim() {
        XCTAssertEqual(trimItem("  buy milk.  "), "Buy milk")
    }

    func testLeadingAnd() {
        XCTAssertEqual(trimItem("and fix the bug."), "Fix the bug")
    }

    func testLeadingOr() {
        XCTAssertEqual(trimItem("or skip this step."), "Skip this step")
    }

    func testLeadingBut() {
        XCTAssertEqual(trimItem("but not this one."), "Not this one")
    }

    func testKeepsQuestionMark() {
        XCTAssertEqual(trimItem("is it ready?"), "Is it ready?")
    }

    func testKeepsExclamation() {
        XCTAssertEqual(trimItem("wow!"), "Wow!")
    }

    func testAlreadyCapitalized() {
        XCTAssertEqual(trimItem("Already capitalized."), "Already capitalized")
    }

    func testEmptyAfterTrim() {
        XCTAssertEqual(trimItem("  "), "")
    }
}

// MARK: - findPreamble Tests

class FindPreambleTests: XCTestCase {

    func testPreambleExists() {
        XCTAssertEqual(
            findPreamble(["We need three things.", "Buy milk.", "Buy eggs."], beforeIndex: 1),
            "We need three things."
        )
    }

    func testNoPreamble() {
        XCTAssertNil(findPreamble(["Buy milk.", "Buy eggs.", "Buy bread."], beforeIndex: 0))
    }

    func testMultiSentencePreamble() {
        XCTAssertEqual(
            findPreamble(["Intro one.", "Intro two.", "First item.", "Second item."], beforeIndex: 2),
            "Intro one. Intro two."
        )
    }
}

// MARK: - Inlined production code (mirrors Formatter/MessageFormatter.swift)

protocol TextFormatter {
    func format(_ text: String) -> String
}

struct MessageFormatter: TextFormatter {
    func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }

        let sentences = splitSentences(trimmed)
        if sentences.count <= 1 { return trimmed }

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

        let titles: Set<String> = ["Mr.", "Mrs.", "Ms.", "Dr.", "Prof."]
        var nameWords: [String] = []
        var temp = remaining

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

                if first.hasSuffix(",") {
                    temp = temp.trimmingCharacters(in: .whitespaces)
                    break
                }
            } else {
                break
            }
        }

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

        if !remaining.isEmpty {
            remaining = remaining.prefix(1).uppercased()
                + remaining.dropFirst()
        }

        return (greetingLine, remaining)
    }

    private func extractSignOff(_ text: String) -> (signOff: String?, body: String) {
        let words = text.components(separatedBy: " ")
        if words.count < 2 { return (nil, text) }

        let signOffPhrases = [
            "best regards", "kind regards", "warm regards",
            "yours sincerely", "yours truly",
            "all the best", "talk soon", "speak soon", "take care",
            "many thanks", "thanks a lot", "thank you",
            "regards", "sincerely", "thanks", "cheers", "best"
        ]

        let searchStart = max(0, words.count - 30)
        let searchArea = words[searchStart...].joined(separator: " ")
        let searchLower = searchArea.lowercased()

        for phrase in signOffPhrases {
            guard let range = searchLower.range(of: phrase) else { continue }

            let afterPhrase = String(searchArea[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)

            let afterWords = afterPhrase
                .trimmingCharacters(in: CharacterSet(charactersIn: ","))
                .components(separatedBy: " ")
                .filter { !$0.isEmpty }

            let allCapitalized = afterWords.allSatisfy { $0.first?.isUppercase == true }
            if afterWords.count > 3 || (!allCapitalized && !afterWords.isEmpty) {
                continue
            }

            let phraseStart = searchArea[range.lowerBound...]
            let originalPhrase = String(phraseStart.prefix(phrase.count))
            var signOffBlock = originalPhrase

            if !afterWords.isEmpty && allCapitalized {
                let name = afterWords.joined(separator: " ")
                if !signOffBlock.hasSuffix(",") {
                    signOffBlock += ","
                }
                signOffBlock += "\n" + name
            }

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

        if paragraphs.count == 1 && sentences.count > 4 {
            paragraphs = []
            for i in stride(from: 0, to: sentences.count, by: 3) {
                let end = min(i + 3, sentences.count)
                paragraphs.append(Array(sentences[i..<end]))
            }
        }

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

// MARK: - MessageFormatter Integration Tests

class MessageFormatterTests: XCTestCase {

    let formatter = MessageFormatter()

    func testFullEmail() {
        let input = "Hi Maria, I wanted to follow up on our meeting yesterday. The project timeline looks good but we need to adjust the budget for Q3. Also, could you send me the updated spreadsheet when you get a chance? I need it for the board presentation on Friday. Thanks, Sebastian"
        let result = formatter.format(input)

        XCTAssertTrue(result.hasPrefix("Hi Maria,\n\n"), "Should start with greeting")
        XCTAssertTrue(result.contains("\n\nAlso,"), "Should split on 'Also'")
        XCTAssertTrue(result.hasSuffix("Thanks,\nSebastian"), "Should end with sign-off and name")
    }

    func testNoGreetingWithSignOff() {
        let input = "Just wanted to let you know the deployment went smoothly. All tests are passing and the client confirmed it's working. Cheers"
        let result = formatter.format(input)

        XCTAssertFalse(result.hasPrefix("Hi"), "Should have no greeting")
        XCTAssertTrue(result.hasSuffix("\n\nCheers"), "Should end with sign-off")
    }

    func testFormalEmail() {
        let input = "Dear Mr. Johnson, thank you for your prompt response regarding the contract terms. We've reviewed the amendments and are in agreement with sections one through four. However, we have concerns about the liability clause in section five. Regarding the timeline, we would prefer to push the signing date to next Friday to give our legal team time to review. Additionally, could you confirm whether the non-compete terms apply to all subsidiaries or only the parent company? We look forward to resolving these final points. Kind regards, Sebastian Strandberg"
        let result = formatter.format(input)

        XCTAssertTrue(result.contains("Dear Mr. Johnson,\n\n"), "Should have formal greeting")
        XCTAssertTrue(result.contains("\n\nHowever,"), "Should split on 'However'")
        XCTAssertTrue(result.contains("\n\nRegarding"), "Should split on 'Regarding'")
        XCTAssertTrue(result.contains("\n\nAdditionally,"), "Should split on 'Additionally'")
        XCTAssertTrue(result.contains("Kind regards,\nSebastian Strandberg"), "Should have sign-off with full name")
    }

    func testQuickQuestion() {
        let input = "Hey, quick question. Do you have the API keys for the staging environment? Or should I ask DevOps? Let me know when you can. Thanks"
        let result = formatter.format(input)

        XCTAssertTrue(result.hasPrefix("Hey,\n\n"), "Should start with greeting")
        // "Or should I ask DevOps?" should stay with the previous question
        XCTAssertTrue(result.contains("environment? Or should I ask DevOps?"), "Should keep question cluster together")
        XCTAssertTrue(result.hasSuffix("\n\nThanks"), "Should end with sign-off")
    }

    func testBareMessage() {
        let input = "The build is broken on main. Can you take a look?"
        let result = formatter.format(input)

        XCTAssertEqual(result, input, "Short message should be unchanged")
    }

    func testEmptyString() {
        XCTAssertEqual(formatter.format(""), "")
    }

    func testSingleSentence() {
        let input = "Just checking in."
        XCTAssertEqual(formatter.format(input), input, "Single sentence should be unchanged")
    }
}

// MARK: - Inlined production code (mirrors Formatter/StructuredTextFormatter.swift)

struct StructuredTextFormatter: TextFormatter {

    enum ContentType {
        case bulletList(items: [String], preamble: String?)
        case numberedList(items: [String], preamble: String?)
        case sections(groups: [(heading: String, body: String)])
        case noChange
    }

    func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        if trimmed.contains("\n- ") || trimmed.contains("\n1.") { return trimmed }
        let sentences = splitSentences(trimmed)
        let contentType = analyze(sentences, fullText: trimmed)
        switch contentType {
        case .bulletList(let items, let preamble):
            return formatBullets(items, preamble: preamble)
        case .numberedList(let items, let preamble):
            return formatNumbered(items, preamble: preamble)
        case .sections(let groups):
            return formatSections(groups)
        case .noChange:
            return trimmed
        }
    }

    private func analyze(_ sentences: [String], fullText: String) -> ContentType {
        let orderedMarkers = [
            "first", "firstly", "first of all",
            "second", "secondly", "third", "thirdly",
            "then", "next", "after that",
            "finally", "lastly", "last",
            "step one", "step two", "step three",
            "number one", "number two", "start by"
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
        if let colonIndex = fullText.firstIndex(of: ":") {
            let afterColon = String(fullText[fullText.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            let beforeColon = String(fullText[..<colonIndex])
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
        let allShort = sentences.allSatisfy { $0.components(separatedBy: " ").count < 15 }
        if allShort && sentences.count >= 3 {
            let nonVerbStarts: Set<String> = [
                "i", "we", "he", "she", "it", "they", "you",
                "my", "our", "his", "her", "its", "their",
                "the", "a", "an", "in", "on", "at", "for", "with", "to",
                "from", "by", "of", "about", "and", "but", "or", "so", "yet",
                "this", "that", "these", "those", "one", "two", "first", "second"
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
            } else {
                return .bulletList(items: sentences, preamble: nil)
            }
        }
        let transitionPhrases = [
            "by the way", "another thing", "on another note",
            "on a different note", "on the other hand",
            "in addition", "one more thing", "besides that",
            "apart from that", "moving on",
            "additionally", "furthermore", "moreover",
            "separately", "regarding", "as for",
            "also", "however", "that said", "anyway"
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
        if groups.count >= 2 && groups.count <= 5
            && groups.allSatisfy({ $0.count >= 2 }) {
            let sectionGroups = groups.map { group -> (heading: String, body: String) in
                let heading = extractHeading(from: group[0])
                let body = group.joined(separator: " ")
                return (heading: heading, body: body)
            }
            return .sections(groups: sectionGroups)
        }
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
        if let p = preamble { result += p + "\n\n" }
        let bullets = items.map { "- " + trimItem(stripMarker($0)) }
        result += bullets.joined(separator: "\n")
        return result
    }

    private func formatNumbered(_ items: [String], preamble: String?) -> String {
        var result = ""
        if let p = preamble { result += p + "\n\n" }
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
}

// MARK: - StructuredTextFormatter Integration Tests

class StructuredTextFormatterTests: XCTestCase {

    let formatter = StructuredTextFormatter()

    func testEnumeratedMajorityOrdered() {
        let input = "There are several issues with the design. First, the navigation is confusing. Second, the color contrast is poor. Third, the loading states are missing. Also, the mobile layout breaks."
        let result = formatter.format(input)

        // 3 ordered (First, Second, Third) + 1 unordered (Also) = majority ordered → numbered
        XCTAssertTrue(result.contains("1."), "Should be numbered (majority ordered markers)")
        XCTAssertFalse(result.contains("First,"), "Should strip sequence markers")
    }

    func testOrderedSteps() {
        let input = "Here's how to deploy. First, build the project. Then push to main. Finally, check the CI pipeline."
        let result = formatter.format(input)

        XCTAssertTrue(result.contains("1."), "Should have numbered steps")
        XCTAssertTrue(result.contains("2."), "Should have step 2")
        XCTAssertTrue(result.contains("3."), "Should have step 3")
    }

    func testColonList() {
        let input = "The tech stack includes: React, Node.js, PostgreSQL, and Redis."
        let result = formatter.format(input)

        XCTAssertTrue(result.contains("The tech stack includes:"), "Should keep preamble with colon")
        XCTAssertTrue(result.contains("- React"), "Should have bullet for React")
        XCTAssertTrue(result.contains("- Redis"), "Should have bullet for Redis")
    }

    func testShortImperativeSentences() {
        let input = "Open the terminal. Navigate to the project folder. Run npm install. Start the server."
        let result = formatter.format(input)

        XCTAssertTrue(result.contains("1."), "Should be numbered")
        XCTAssertTrue(result.contains("2."), "Should have step 2")
    }

    func testAndThenChain() {
        let input = "You click the button and then enter your password and then click submit."
        let result = formatter.format(input)

        XCTAssertTrue(result.contains("1."), "Should be numbered list")
        XCTAssertTrue(result.contains("2."), "Should have step 2")
        XCTAssertTrue(result.contains("3."), "Should have step 3")
    }

    func testRegularProse() {
        let input = "I had a great meeting with the client yesterday. They were really impressed with the demo and want to move forward with the project. I think we should start planning the next sprint."
        XCTAssertEqual(formatter.format(input), input, "Prose should be unchanged")
    }

    func testAlreadyFormatted() {
        let input = "- Item one\n- Item two\n- Item three"
        XCTAssertEqual(formatter.format(input), input, "Already formatted should be unchanged")
    }

    func testSingleSentence() {
        let input = "Update the database."
        XCTAssertEqual(formatter.format(input), input, "Single sentence should be unchanged")
    }

    func testEmpty() {
        XCTAssertEqual(formatter.format(""), "")
    }
}
