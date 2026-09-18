/// DebriefSummaryTests — Unit tests for the debrief-summary core: the plain-text
/// renderer, the tolerant JSON parser, the heuristic fallback summarizer, the
/// Ollama HTTP summarizer (via a `URLProtocol` stub), and `ChainedDebriefSummarizer`.
///
/// Run via: cd dikta-macos && xcodebuild test -project Dikta.xcodeproj -scheme Dikta -only-testing:DiktaTests -destination 'platform=macOS' CODE_SIGN_IDENTITY=- 2>&1 | grep 'Executed.*test'

import XCTest
@testable import Dikta

// MARK: - Test helpers

private func fixedDate() -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = 17
    components.hour = 12
    return Calendar(identifier: .gregorian).date(from: components)!
}

// MARK: - renderPlainText (English)

final class DebriefSummaryRenderPlainTextEnglishTests: XCTestCase {
    func test_rendersHeadingWithDate() {
        let summary = DebriefSummary(summary: "We talked about the roadmap.", decisions: [], actionItems: [], openQuestions: [])
        let text = summary.renderPlainText(language: "en", date: fixedDate())
        XCTAssertTrue(text.hasPrefix("MEETING DEBRIEF – 2026-09-17\n"))
    }

    func test_summarySectionAlwaysPresent() {
        let summary = DebriefSummary(summary: "Short recap.", decisions: [], actionItems: [], openQuestions: [])
        let text = summary.renderPlainText(language: "en", date: fixedDate())
        XCTAssertTrue(text.contains("SUMMARY\nShort recap."))
    }

    func test_omitsEmptySections() {
        let summary = DebriefSummary(summary: "Short recap.", decisions: [], actionItems: [], openQuestions: [])
        let text = summary.renderPlainText(language: "en", date: fixedDate())
        XCTAssertFalse(text.contains("DECISIONS"))
        XCTAssertFalse(text.contains("ACTION ITEMS"))
        XCTAssertFalse(text.contains("OPEN QUESTIONS"))
    }

    func test_includesNonEmptySections() {
        let summary = DebriefSummary(
            summary: "Short recap.",
            decisions: ["Go with vendor A"],
            actionItems: [DebriefActionItem(text: "Send contract", owner: nil, due: nil)],
            openQuestions: ["Who owns onboarding?"]
        )
        let text = summary.renderPlainText(language: "en", date: fixedDate())
        XCTAssertTrue(text.contains("DECISIONS\nGo with vendor A"))
        XCTAssertTrue(text.contains("ACTION ITEMS\n[ ] Send contract"))
        XCTAssertTrue(text.contains("OPEN QUESTIONS\nWho owns onboarding?"))
    }

    func test_actionItemWithOwnerAndDue() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: [],
            actionItems: [DebriefActionItem(text: "Send contract", owner: "Anna", due: "Friday")],
            openQuestions: []
        )
        let text = summary.renderPlainText(language: "en", date: fixedDate())
        XCTAssertTrue(text.contains("[ ] Send contract (Anna, due Friday)"))
    }

    func test_actionItemWithOwnerOnly() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: [],
            actionItems: [DebriefActionItem(text: "Send contract", owner: "Anna", due: nil)],
            openQuestions: []
        )
        let text = summary.renderPlainText(language: "en", date: fixedDate())
        XCTAssertTrue(text.contains("[ ] Send contract (Anna)"))
    }

    func test_actionItemWithDueOnly() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: [],
            actionItems: [DebriefActionItem(text: "Send contract", owner: nil, due: "Friday")],
            openQuestions: []
        )
        let text = summary.renderPlainText(language: "en", date: fixedDate())
        XCTAssertTrue(text.contains("[ ] Send contract (due Friday)"))
    }

    func test_actionItemWithNeitherOwnerNorDue() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: [],
            actionItems: [DebriefActionItem(text: "Send contract", owner: nil, due: nil)],
            openQuestions: []
        )
        let text = summary.renderPlainText(language: "en", date: fixedDate())
        XCTAssertTrue(text.contains("[ ] Send contract\n") || text.hasSuffix("[ ] Send contract\n"))
        XCTAssertFalse(text.contains("Send contract ("))
    }

    func test_endsWithSingleTrailingNewline() {
        let summary = DebriefSummary(summary: "Recap.", decisions: [], actionItems: [], openQuestions: [])
        let text = summary.renderPlainText(language: "en", date: fixedDate())
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
    }

    func test_unknownLanguageFallsBackToEnglish() {
        let summary = DebriefSummary(summary: "Recap.", decisions: [], actionItems: [], openQuestions: [])
        let text = summary.renderPlainText(language: "fr", date: fixedDate())
        XCTAssertTrue(text.hasPrefix("MEETING DEBRIEF"))
    }
}

// MARK: - renderPlainText (Swedish)

final class DebriefSummaryRenderPlainTextSwedishTests: XCTestCase {
    func test_rendersSwedishHeading() {
        let summary = DebriefSummary(summary: "Kort sammanfattning.", decisions: [], actionItems: [], openQuestions: [])
        let text = summary.renderPlainText(language: "sv", date: fixedDate())
        XCTAssertTrue(text.hasPrefix("MÖTESSAMMANFATTNING – 2026-09-17\n"))
    }

    func test_rendersSwedishSectionHeadings() {
        let summary = DebriefSummary(
            summary: "Kort sammanfattning.",
            decisions: ["Vi kör på leverantör A"],
            actionItems: [DebriefActionItem(text: "Skicka avtal", owner: "Anna", due: "fredag")],
            openQuestions: ["Vem äger onboarding?"]
        )
        let text = summary.renderPlainText(language: "sv", date: fixedDate())
        XCTAssertTrue(text.contains("SAMMANFATTNING\nKort sammanfattning."))
        XCTAssertTrue(text.contains("BESLUT\nVi kör på leverantör A"))
        XCTAssertTrue(text.contains("ÅTGÄRDER\n[ ] Skicka avtal (Anna, senast fredag)"))
        XCTAssertTrue(text.contains("ÖPPNA FRÅGOR\nVem äger onboarding?"))
    }

    func test_swedishActionItemDueOnlyUsesSenast() {
        let summary = DebriefSummary(
            summary: "Recap.",
            decisions: [],
            actionItems: [DebriefActionItem(text: "Skicka avtal", owner: nil, due: "fredag")],
            openQuestions: []
        )
        let text = summary.renderPlainText(language: "sv", date: fixedDate())
        XCTAssertTrue(text.contains("[ ] Skicka avtal (senast fredag)"))
    }

    func test_swedishOmitsEmptySections() {
        let summary = DebriefSummary(summary: "Recap.", decisions: [], actionItems: [], openQuestions: [])
        let text = summary.renderPlainText(language: "sv", date: fixedDate())
        XCTAssertFalse(text.contains("BESLUT"))
        XCTAssertFalse(text.contains("ÅTGÄRDER"))
        XCTAssertFalse(text.contains("ÖPPNA FRÅGOR"))
    }
}

// MARK: - DebriefSummaryParser

final class DebriefSummaryParserTests: XCTestCase {
    func test_parsesPlainJSON() throws {
        let raw = """
        {"summary": "We discussed the roadmap.", "decisions": ["Ship v2"], "actionItems": [], "openQuestions": []}
        """
        let summary = try DebriefSummaryParser.parse(raw)
        XCTAssertEqual(summary.summary, "We discussed the roadmap.")
        XCTAssertEqual(summary.decisions, ["Ship v2"])
    }

    func test_parsesFencedJSON() throws {
        let raw = """
        ```json
        {"summary": "We discussed the roadmap.", "decisions": [], "actionItems": [], "openQuestions": []}
        ```
        """
        let summary = try DebriefSummaryParser.parse(raw)
        XCTAssertEqual(summary.summary, "We discussed the roadmap.")
    }

    func test_parsesJSONWithLeadingChatter() throws {
        let raw = """
        Sure, here is the summary you asked for:
        {"summary": "We discussed the roadmap.", "decisions": [], "actionItems": [], "openQuestions": []}
        """
        let summary = try DebriefSummaryParser.parse(raw)
        XCTAssertEqual(summary.summary, "We discussed the roadmap.")
    }

    func test_parsesNullOwnerAndDue() throws {
        let raw = """
        {"summary": "Recap.", "decisions": [], "actionItems": [{"text": "Send contract", "owner": null, "due": null}], "openQuestions": []}
        """
        let summary = try DebriefSummaryParser.parse(raw)
        XCTAssertEqual(summary.actionItems, [DebriefActionItem(text: "Send contract", owner: nil, due: nil)])
    }

    func test_missingArraysDefaultToEmpty() throws {
        let raw = """
        {"summary": "Recap only."}
        """
        let summary = try DebriefSummaryParser.parse(raw)
        XCTAssertEqual(summary.summary, "Recap only.")
        XCTAssertEqual(summary.decisions, [])
        XCTAssertEqual(summary.actionItems, [])
        XCTAssertEqual(summary.openQuestions, [])
    }

    func test_garbageInputThrowsBadResponse() {
        let raw = "not json at all, sorry"
        XCTAssertThrowsError(try DebriefSummaryParser.parse(raw)) { error in
            guard case DebriefSummarizerError.badResponse(let excerpt) = error else {
                return XCTFail("Expected .badResponse, got \(error)")
            }
            XCTAssertEqual(excerpt, String(raw.prefix(200)))
        }
    }

    func test_malformedJSONThrowsBadResponseWithExcerpt() {
        let raw = "{\"summary\": \"unterminated string"
        XCTAssertThrowsError(try DebriefSummaryParser.parse(raw)) { error in
            guard case DebriefSummarizerError.badResponse = error else {
                return XCTFail("Expected .badResponse, got \(error)")
            }
        }
    }
}

// MARK: - HeuristicDebriefSummarizer

final class HeuristicDebriefSummarizerTests: XCTestCase {
    private let englishTranscript = """
    Okay so we met with the supplier today. Anna will send the updated quote by Friday. We decided to go with the smaller pallet size. It is still unclear who owns the packaging spec
    """

    private let swedishTranscript = """
    Okej så vi träffade leverantören idag. Anna ska skicka den uppdaterade offerten på fredag. Vi kom överens om att köra på den mindre pallstorleken. Det är fortfarande oklart vem som äger förpackningsspecen
    """

    func test_isAlwaysAvailable() async {
        let summarizer = HeuristicDebriefSummarizer()
        let available = await summarizer.isAvailable()
        XCTAssertTrue(available)
    }

    func test_throwsOnEmptyTranscript() async {
        let summarizer = HeuristicDebriefSummarizer()
        await XCTAssertThrowsErrorAsync(try await summarizer.summarize(transcript: "   ", language: "en")) { error in
            guard case DebriefSummarizerError.emptyTranscript = error else {
                return XCTFail("Expected .emptyTranscript, got \(error)")
            }
        }
    }

    func test_english_summaryIsFirstThreeSentences() async throws {
        let summarizer = HeuristicDebriefSummarizer()
        let summary = try await summarizer.summarize(transcript: englishTranscript, language: "en")
        XCTAssertTrue(summary.summary.contains("Okay so we met with the supplier today."))
        XCTAssertTrue(summary.summary.contains("Anna will send the updated quote by Friday."))
        XCTAssertTrue(summary.summary.contains("We decided to go with the smaller pallet size."))
        XCTAssertFalse(summary.summary.contains("unclear"))
    }

    func test_english_actionItemsFoundByMarker() async throws {
        let summarizer = HeuristicDebriefSummarizer()
        let summary = try await summarizer.summarize(transcript: englishTranscript, language: "en")
        XCTAssertEqual(summary.actionItems.count, 1)
        XCTAssertTrue(summary.actionItems[0].text.contains("Anna will send the updated quote by Friday"))
        XCTAssertNil(summary.actionItems[0].owner)
        XCTAssertNil(summary.actionItems[0].due)
    }

    func test_english_decisionsFoundByMarker() async throws {
        let summarizer = HeuristicDebriefSummarizer()
        let summary = try await summarizer.summarize(transcript: englishTranscript, language: "en")
        XCTAssertEqual(summary.decisions.count, 1)
        XCTAssertTrue(summary.decisions[0].contains("We decided to go with the smaller pallet size"))
    }

    func test_english_openQuestionsFoundByMarker() async throws {
        let summarizer = HeuristicDebriefSummarizer()
        let summary = try await summarizer.summarize(transcript: englishTranscript, language: "en")
        XCTAssertEqual(summary.openQuestions.count, 1)
        XCTAssertTrue(summary.openQuestions[0].contains("unclear who owns the packaging spec"))
    }

    func test_swedish_actionItemsFoundByMarker() async throws {
        let summarizer = HeuristicDebriefSummarizer()
        let summary = try await summarizer.summarize(transcript: swedishTranscript, language: "sv")
        XCTAssertEqual(summary.actionItems.count, 1)
        XCTAssertTrue(summary.actionItems[0].text.contains("Anna ska skicka den uppdaterade offerten"))
    }

    func test_swedish_decisionsFoundByMarker() async throws {
        let summarizer = HeuristicDebriefSummarizer()
        let summary = try await summarizer.summarize(transcript: swedishTranscript, language: "sv")
        XCTAssertEqual(summary.decisions.count, 1)
        XCTAssertTrue(summary.decisions[0].contains("kom överens om att köra på den mindre pallstorleken"))
    }

    func test_swedish_openQuestionsFoundByMarker() async throws {
        let summarizer = HeuristicDebriefSummarizer()
        let summary = try await summarizer.summarize(transcript: swedishTranscript, language: "sv")
        XCTAssertEqual(summary.openQuestions.count, 1)
        XCTAssertTrue(summary.openQuestions[0].contains("oklart vem som äger förpackningsspecen"))
    }

    func test_actionItemsCappedAtTen() async throws {
        let manySentences = (1...15).map { "We will follow up on task \($0)." }.joined(separator: " ")
        let summarizer = HeuristicDebriefSummarizer()
        let summary = try await summarizer.summarize(transcript: manySentences, language: "en")
        XCTAssertEqual(summary.actionItems.count, 10)
    }
}

// MARK: - HeuristicDebriefSummarizer (realistic, unpunctuated, rambling transcripts)

/// These transcripts are written the way WhisperKit actually emits a long,
/// unbroken debrief: no punctuation at all, just discourse fillers ("so",
/// "also", "and then"/"och sen"...) stitching clauses together. They exercise
/// the >30-word discourse-marker re-split in HeuristicDebriefSummarizer,
/// which exists specifically so a rambling run-on doesn't collapse into one
/// segment that gets bucketed as the summary, a decision, an action item,
/// and an open question all at once.
final class HeuristicDebriefSummarizerRamblingTranscriptTests: XCTestCase {
    private let englishTranscript =
        "okay quick debrief from the supplier meeting so we went through the new packaging " +
        "also Anna will send the updated quote by friday so we decided to go with the smaller " +
        "pallet size and then it is still unclear who owns the packaging spec so I need to " +
        "check with Johan tomorrow also we should update the shared folder afterwards"

    private let swedishTranscript =
        "okej snabb genomgång från leverantörsmötet sen vi gick igenom den nya förpackningen " +
        "också Anna ska skicka den uppdaterade offerten på fredag sen vi kom överens om att köra " +
        "på den mindre pallstorleken och sen det är fortfarande oklart vem som äger " +
        "förpackningsspecen sen jag behöver stämma av med Johan imorgon också vi bör uppdatera " +
        "den delade mappen efteråt"

    func test_english_ramblingTranscript_separatesBucketsCleanly() async throws {
        let summarizer = HeuristicDebriefSummarizer()
        let summary = try await summarizer.summarize(transcript: englishTranscript, language: "en")

        let summaryRatio = Double(summary.summary.count) / Double(englishTranscript.count)
        XCTAssertLessThan(summaryRatio, 0.6, "Summary should not be the whole transcript")

        XCTAssertTrue(summary.actionItems.contains { $0.text.localizedCaseInsensitiveContains("quote") })
        XCTAssertTrue(summary.decisions.contains { $0.localizedCaseInsensitiveContains("pallet") })
        XCTAssertTrue(summary.openQuestions.contains { $0.localizedCaseInsensitiveContains("packaging spec") })

        let allBucketed = summary.decisions + summary.actionItems.map(\.text) + summary.openQuestions
        XCTAssertEqual(allBucketed.count, Set(allBucketed).count, "No string should appear in more than one bucket")
    }

    func test_swedish_ramblingTranscript_separatesBucketsCleanly() async throws {
        let summarizer = HeuristicDebriefSummarizer()
        let summary = try await summarizer.summarize(transcript: swedishTranscript, language: "sv")

        let summaryRatio = Double(summary.summary.count) / Double(swedishTranscript.count)
        XCTAssertLessThan(summaryRatio, 0.6, "Summary should not be the whole transcript")

        XCTAssertTrue(summary.actionItems.contains { $0.text.localizedCaseInsensitiveContains("offerten") })
        XCTAssertTrue(summary.decisions.contains { $0.localizedCaseInsensitiveContains("pallstorleken") })
        XCTAssertTrue(summary.openQuestions.contains { $0.localizedCaseInsensitiveContains("förpackningsspecen") })

        let allBucketed = summary.decisions + summary.actionItems.map(\.text) + summary.openQuestions
        XCTAssertEqual(allBucketed.count, Set(allBucketed).count, "No string should appear in more than one bucket")
    }

    func test_longSegmentWithoutFurtherDiscourseMarkers_fallsBackToFixedWordChunks() async throws {
        // 61 words, no discourse markers at all: after the initial (single,
        // unpunctuated) "sentence" is found to be >30 words, discourse-marker
        // splitting finds nothing to split on, so it falls back to fixed
        // 20-word chunks (20, 20, 20, 1). Only the first three chunks feed
        // the summary, so the lone word in the last chunk should be excluded.
        let fillerWords = (1...61).map { "filler\($0)" }
        let transcript = fillerWords.joined(separator: " ")
        let summarizer = HeuristicDebriefSummarizer()
        let summary = try await summarizer.summarize(transcript: transcript, language: "en")

        XCTAssertTrue(summary.summary.contains("filler1 "))
        XCTAssertFalse(summary.summary.contains("filler61"))
    }
}

// MARK: - OllamaDebriefSummarizer

/// Stubs all requests through `URLProtocol` so the Ollama tests never touch
/// the network. Configure `URLProtocolStub.handler` before each request.
final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = URLProtocolStub.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        // URLSession moves a POST body into `httpBodyStream` by the time it
        // reaches the protocol, so `httpBody` alone is nil here. Resolve it
        // back into `httpBody` so handlers can inspect the request they sent.
        var resolvedRequest = request
        if resolvedRequest.httpBody == nil, let stream = request.httpBodyStream {
            resolvedRequest.httpBody = Self.readAllData(from: stream)
        }

        do {
            let (response, data) = try handler(resolvedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readAllData(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}

final class OllamaDebriefSummarizerTests: XCTestCase {
    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func test_isAvailable_trueWhenModelListed() async {
        URLProtocolStub.handler = { request in
            let body = #"{"models": [{"name": "llama3:8b"}]}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let summarizer = OllamaDebriefSummarizer(model: "llama3", session: stubbedSession())
        let available = await summarizer.isAvailable()
        XCTAssertTrue(available)
    }

    func test_isAvailable_falseWhenModelNotListed() async {
        URLProtocolStub.handler = { request in
            let body = #"{"models": [{"name": "mistral:7b"}]}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let summarizer = OllamaDebriefSummarizer(model: "llama3", session: stubbedSession())
        let available = await summarizer.isAvailable()
        XCTAssertFalse(available)
    }

    func test_isAvailable_falseOnNon200() async {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let summarizer = OllamaDebriefSummarizer(model: "llama3", session: stubbedSession())
        let available = await summarizer.isAvailable()
        XCTAssertFalse(available)
    }

    func test_summarize_parsesCannedChatResponse() async throws {
        URLProtocolStub.handler = { request in
            let content = #"{"summary": "We discussed the roadmap.", "decisions": ["Ship v2"], "actionItems": [], "openQuestions": []}"#
            let body = try! JSONEncoder().encode(["message": ["role": "assistant", "content": content]])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let summarizer = OllamaDebriefSummarizer(model: "llama3", session: stubbedSession())
        let summary = try await summarizer.summarize(transcript: "some transcript", language: "en")
        XCTAssertEqual(summary.summary, "We discussed the roadmap.")
        XCTAssertEqual(summary.decisions, ["Ship v2"])
    }

    func test_summarize_throwsHttpOnNon200() async {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let summarizer = OllamaDebriefSummarizer(model: "llama3", session: stubbedSession())
        await XCTAssertThrowsErrorAsync(try await summarizer.summarize(transcript: "transcript", language: "en")) { error in
            guard case DebriefSummarizerError.http(503) = error else {
                return XCTFail("Expected .http(503), got \(error)")
            }
        }
    }

    func test_summarize_throwsEmptyTranscript() async {
        let summarizer = OllamaDebriefSummarizer(model: "llama3", session: stubbedSession())
        await XCTAssertThrowsErrorAsync(try await summarizer.summarize(transcript: "  \n ", language: "en")) { error in
            guard case DebriefSummarizerError.emptyTranscript = error else {
                return XCTFail("Expected .emptyTranscript, got \(error)")
            }
        }
    }

    func test_summarize_malformedJSONBodyThrowsBadResponse() async {
        URLProtocolStub.handler = { request in
            let body = "not valid json at all".data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let summarizer = OllamaDebriefSummarizer(model: "llama3", session: stubbedSession())
        await XCTAssertThrowsErrorAsync(try await summarizer.summarize(transcript: "transcript", language: "en")) { error in
            guard case DebriefSummarizerError.badResponse = error else {
                return XCTFail("Expected .badResponse, got \(error)")
            }
        }
    }

    func test_summarize_otherURLErrorMapsToUnavailable() async {
        URLProtocolStub.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let summarizer = OllamaDebriefSummarizer(model: "llama3", session: stubbedSession())
        await XCTAssertThrowsErrorAsync(try await summarizer.summarize(transcript: "transcript", language: "en")) { error in
            guard case DebriefSummarizerError.unavailable = error else {
                return XCTFail("Expected .unavailable, got \(error)")
            }
        }
    }

    func test_summarize_timedOutURLErrorMapsToTimeout() async {
        URLProtocolStub.handler = { _ in
            throw URLError(.timedOut)
        }
        let summarizer = OllamaDebriefSummarizer(model: "llama3", session: stubbedSession())
        await XCTAssertThrowsErrorAsync(try await summarizer.summarize(transcript: "transcript", language: "en")) { error in
            guard case DebriefSummarizerError.timeout = error else {
                return XCTFail("Expected .timeout, got \(error)")
            }
        }
    }

    func test_summarize_requestBodyMatchesExpectedShape() async throws {
        var capturedRequest: OllamaChatRequest?
        URLProtocolStub.handler = { request in
            if let body = request.httpBody {
                capturedRequest = try? JSONDecoder().decode(OllamaChatRequest.self, from: body)
            }
            let content = #"{"summary": "Recap.", "decisions": [], "actionItems": [], "openQuestions": []}"#
            let body = try! JSONEncoder().encode(["message": ["role": "assistant", "content": content]])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let summarizer = OllamaDebriefSummarizer(model: "llama3", session: stubbedSession())
        _ = try await summarizer.summarize(transcript: "some transcript", language: "en")

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.model, "llama3")
        XCTAssertEqual(request.stream, false)
        XCTAssertEqual(request.format, "json")
        XCTAssertEqual(request.options.temperature, 0, "default temperature must be deterministic/greedy")
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.messages[0].role, "system")
        XCTAssertEqual(request.messages[1].role, "user")
    }
}

// MARK: - OllamaDebriefSummarizer.modelMatches

final class OllamaDebriefSummarizerModelMatchesTests: XCTestCase {
    func test_taggedConfiguredModel_doesNotMatchDifferentTag() {
        XCTAssertFalse(OllamaDebriefSummarizer.modelMatches(serverName: "llama3:70b", configuredModel: "llama3:8b"))
    }

    func test_untaggedConfiguredModel_matchesAnyTagOfSameName() {
        XCTAssertTrue(OllamaDebriefSummarizer.modelMatches(serverName: "llama3:8b", configuredModel: "llama3"))
    }

    func test_taggedConfiguredModel_matchesExactTag() {
        XCTAssertTrue(OllamaDebriefSummarizer.modelMatches(serverName: "llama3:8b", configuredModel: "llama3:8b"))
    }

    func test_untaggedConfiguredModel_doesNotMatchDifferentName() {
        XCTAssertFalse(OllamaDebriefSummarizer.modelMatches(serverName: "mistral:7b", configuredModel: "llama3"))
    }
}

// MARK: - ChainedDebriefSummarizer

// `FakeDebriefSummarizer` lives in its own file so the pipeline and ViewModel
// tests can use it too.

final class ChainedDebriefSummarizerTests: XCTestCase {
    private func summary(_ text: String) -> DebriefSummary {
        DebriefSummary(summary: text, decisions: [], actionItems: [], openQuestions: [])
    }

    func test_picksFirstAvailableEngine() async throws {
        let unavailable = FakeDebriefSummarizer(name: "Unavailable", available: false, result: .success(summary("should not be used")))
        let available = FakeDebriefSummarizer(name: "Available", available: true, result: .success(summary("used")))
        let chained = ChainedDebriefSummarizer(engines: [unavailable, available])

        let result = try await chained.summarize(transcript: "transcript", language: "en")
        XCTAssertEqual(result.summary, "used")
        XCTAssertEqual(chained.lastUsedEngineName, "Available")
    }

    func test_fallsThroughOnThrowingEngine() async throws {
        let failing = FakeDebriefSummarizer(name: "Failing", available: true, result: .failure(DebriefSummarizerError.timeout))
        let fallback = FakeDebriefSummarizer(name: "Fallback", available: true, result: .success(summary("fallback result")))
        let chained = ChainedDebriefSummarizer(engines: [failing, fallback])

        let result = try await chained.summarize(transcript: "transcript", language: "en")
        XCTAssertEqual(result.summary, "fallback result")
        XCTAssertEqual(chained.lastUsedEngineName, "Fallback")
    }

    func test_throwsWhenNoEngineAvailable() async {
        let unavailable = FakeDebriefSummarizer(name: "Unavailable", available: false, result: .success(summary("unused")))
        let chained = ChainedDebriefSummarizer(engines: [unavailable])

        await XCTAssertThrowsErrorAsync(try await chained.summarize(transcript: "transcript", language: "en"))
    }

    func test_isAvailable_trueIfAnyEngineAvailable() async {
        let unavailable = FakeDebriefSummarizer(name: "Unavailable", available: false, result: .success(summary("unused")))
        let available = FakeDebriefSummarizer(name: "Available", available: true, result: .success(summary("unused")))
        let chained = ChainedDebriefSummarizer(engines: [unavailable, available])

        let isAvailable = await chained.isAvailable()
        XCTAssertTrue(isAvailable)
    }

    func test_emptyTranscript_shortCircuitsBeforeTouchingAnyEngine() async {
        let heuristicLike = FakeDebriefSummarizer(name: "Heuristic", available: true, result: .success(summary("used")))
        let chained = ChainedDebriefSummarizer(engines: [heuristicLike])

        await XCTAssertThrowsErrorAsync(try await chained.summarize(transcript: "   \n ", language: "en")) { error in
            guard case DebriefSummarizerError.emptyTranscript = error else {
                return XCTFail("Expected .emptyTranscript, got \(error)")
            }
        }
        XCTAssertEqual(heuristicLike.isAvailableCallCount, 0, "No engine should be touched for an empty transcript")
        XCTAssertEqual(heuristicLike.summarizeCallCount, 0)
        XCTAssertNil(chained.lastUsedEngineName)
    }

    func test_cancellationError_propagatesImmediatelyWithoutFallingThrough() async {
        let cancelling = FakeDebriefSummarizer(name: "Cancelling", available: true, result: .failure(CancellationError()))
        let heuristicLike = FakeDebriefSummarizer(name: "Heuristic", available: true, result: .success(summary("should never be used")))
        let chained = ChainedDebriefSummarizer(engines: [cancelling, heuristicLike])

        await XCTAssertThrowsErrorAsync(try await chained.summarize(transcript: "transcript", language: "en")) { error in
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(heuristicLike.isAvailableCallCount, 0, "Heuristic should never be consulted after a cancellation")
        XCTAssertEqual(heuristicLike.summarizeCallCount, 0)
        XCTAssertNil(chained.lastUsedEngineName)
    }
}

// MARK: - DebriefSummarizerFactory

final class DebriefSummarizerFactoryTests: XCTestCase {
    func test_heuristicKind_returnsHeuristicSummarizer() {
        let summarizer = DebriefSummarizerFactory.make(kind: .heuristic, ollamaModel: "llama3")
        XCTAssertTrue(summarizer is HeuristicDebriefSummarizer)
    }

    func test_ollamaKind_returnsOllamaSummarizer() {
        let summarizer = DebriefSummarizerFactory.make(kind: .ollama, ollamaModel: "llama3")
        XCTAssertTrue(summarizer is OllamaDebriefSummarizer)
    }

    func test_autoKind_returnsChainEndingInHeuristic() {
        let summarizer = DebriefSummarizerFactory.make(kind: .auto, ollamaModel: "llama3")
        guard let chained = summarizer as? ChainedDebriefSummarizer else {
            return XCTFail("Expected a ChainedDebriefSummarizer for .auto")
        }
        XCTAssertEqual(chained.engineNames.last, "Heuristic")
        XCTAssertTrue(chained.engineNames.contains("Ollama"))
    }

    func test_autoKind_startsWithFoundationModelsWhenAvailableOnThisOS() {
        let summarizer = DebriefSummarizerFactory.make(kind: .auto, ollamaModel: "llama3")
        guard let chained = summarizer as? ChainedDebriefSummarizer else {
            return XCTFail("Expected a ChainedDebriefSummarizer for .auto")
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            XCTAssertEqual(chained.engineNames.first, "FoundationModels")
        }
        #endif
    }
}

// MARK: - DebriefSummary Codable round-trip

final class DebriefSummaryCodableTests: XCTestCase {
    func test_roundTripsThroughJSON() throws {
        let original = DebriefSummary(
            summary: "We discussed the roadmap.",
            decisions: ["Ship v2"],
            actionItems: [DebriefActionItem(text: "Send contract", owner: "Anna", due: "Friday"), DebriefActionItem(text: "Follow up", owner: nil, due: nil)],
            openQuestions: ["Who owns onboarding?"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DebriefSummary.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}

// MARK: - DebriefPromptBuilder.systemPrompt(isLabeledTranscript:)

/// Covers the Me/Them labeled-transcript rule block added to
/// `DebriefPromptBuilder.systemPrompt` for call debriefs (see
/// `TwoTrackMerger` and decision 4 in `tasks/decisions-call-debrief.md`).
/// `test_unlabeled_isByteIdenticalToThePreviousPrompt` snapshots the prompt
/// as it existed before this parameter was added, so a future edit can't
/// silently change unlabeled behavior.
final class DebriefPromptBuilderLabeledTranscriptTests: XCTestCase {
    func test_labeled_english_containsRuleBlock() {
        let prompt = DebriefPromptBuilder.systemPrompt(language: "en", isLabeledTranscript: true)
        XCTAssertTrue(prompt.contains("This transcript is labeled"))
        XCTAssertTrue(prompt.contains("\"Me:\""))
        XCTAssertTrue(prompt.contains("\"Them:\""))
    }

    func test_labeled_swedish_containsRuleBlock() {
        let prompt = DebriefPromptBuilder.systemPrompt(language: "sv", isLabeledTranscript: true)
        XCTAssertTrue(prompt.contains("Denna transkription är märkt"))
        // The labels themselves stay in English/verbatim form even in the
        // Swedish prompt - only the explanatory rule text is translated.
        XCTAssertTrue(prompt.contains("\"Me:\""))
        XCTAssertTrue(prompt.contains("\"Them:\""))
    }

    func test_unlabeled_doesNotContainRuleBlock() {
        let prompt = DebriefPromptBuilder.systemPrompt(language: "en", isLabeledTranscript: false)
        XCTAssertFalse(prompt.contains("This transcript is labeled"))
    }

    /// Snapshot of `DebriefPromptBuilder.systemPrompt(language: "en")` as it
    /// existed immediately before `isLabeledTranscript` was added — the
    /// default-argument call must keep producing exactly this text.
    func test_unlabeled_isByteIdenticalToThePreviousPrompt() {
        let expected = """
        You are an assistant that summarizes spoken post-meeting debriefs. The \
        transcript is the USER's own first-person account of a meeting they just \
        left — not a description of someone else. The transcript may be Swedish or \
        English, and punctuation may be missing or inconsistent because it comes \
        from speech-to-text.

        Write your output in the SAME language as the transcript, and in FIRST \
        PERSON ("I", "we") the way the speaker talks — never call them "the \
        speaker" or refer to them in the third person. If the speaker states their \
        own name (often as an aside, e.g. "it was me, Sebastian, and Erik"), that name \
        refers to THEM, the speaker — it is not a separate third person they met \
        with. Never write something like "we met with Sebastian" when Sebastian is \
        the speaker's own name; write "I met with..." instead. Use that name as the \
        owner for actions the speaker themselves will do. Write every field, \
        including owner and due, in the transcript's language only.

        Speech-to-text often spells the same name or company two different ways in \
        one transcript (e.g. "Acme" vs "Akme" for the same company). These are \
        the SAME entity, not two different ones. Before you write anything, decide \
        on ONE spelling for every name that appears more than once with different \
        spellings, and re-check your finished summary, decisions, action items, and \
        open questions to make sure the spelling you rejected does not appear \
        ANYWHERE in them — not even once, not even in the summary while a decision \
        uses the other spelling.

        Return ONLY a JSON object with this shape, no prose before or after it:
        \(DebriefPromptBuilder.jsonSchemaDescription)

        Rules:
        - Spell every name/company only ONE way everywhere, even if the transcript \
        spells it more than one way.
        - summary: 2-5 sentences, first person, what happened IN the meeting. Something \
        already done or true before the meeting is context here only, never a decision \
        or action.
        - decisions: ONLY things explicitly agreed or concluded, using committal \
        language actually spoken (e.g. "we decided", "we'll go with"). A conditional or \
        either/or still being weighed ("if he should X or Y") is an openQuestion, \
        not a decision. A future task — scheduling, booking, sending, following up — \
        is always an actionItem, never a decision, even phrased as "we decided to...". \
        Empty array if none.
        - actionItems: things still to do after the meeting. owner is the GRAMMATICAL \
        SUBJECT of the task as spoken: "I" means the speaker — \
        use their own stated name, else "me"; \
        "X will" means X. Never give the speaker's own task to someone \
        else nearby. An already-arranged event ("we will have a meeting tomorrow") is NOT an \
        action item — summary only. due is copied VERBATIM as spoken (e.g. \
        "one week from now", "tomorrow") — NEVER converted to a calendar date, NEVER given a year or \
        weekday the speaker didn't say, and never an unrelated date borrowed from \
        elsewhere in the transcript. owner is only a person actually named, never a \
        generic group like "Team"/"Everyone"; owner and due are null when not spoken.
        - Every item is EITHER a decision OR an actionItem, never both or worded twice \
        in each place (e.g. "booked the meeting" as a decision and \
        "book the meeting" as an action item is still one item).
        - openQuestions: unresolved points or either/or options actually voiced, \
        including a conditional the speaker is still weighing (see decisions). Never \
        invent one. Empty array if none.
        - Never invent facts, owners, dates, or years absent from the transcript. Use \
        empty arrays for empty sections. owner/due must be null, never a placeholder \
        such as "Not specified", "TBD", "N/A", "None" or "Unknown".
        """

        XCTAssertEqual(DebriefPromptBuilder.systemPrompt(language: "en"), expected)
        XCTAssertEqual(DebriefPromptBuilder.systemPrompt(language: "en", isLabeledTranscript: false), expected)
    }
}

// MARK: - XCTest async helpers

/// `XCTAssertThrowsError` has no async overload; this bridges it.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (_ error: Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
