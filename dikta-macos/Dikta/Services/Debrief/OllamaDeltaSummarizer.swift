import Foundation

/// Tolerant parser for the delta JSON an LLM is asked to return.
///
/// Same shape of tolerance as `DebriefSummaryParser`: model output is often
/// wrapped in ``` fences or preceded by chatty text, and fields are frequently
/// omitted entirely rather than sent as empty arrays. Anything unrecognized is
/// ignored; only a response with no decodable JSON object, or one missing the
/// required `summary`, is an error.
enum DebriefDeltaParser {
    static func parseDelta(_ raw: String) throws -> DebriefDelta {
        let data = try jsonData(from: raw)
        do {
            return try JSONDecoder().decode(DeltaDTO.self, from: data).toDebriefDelta()
        } catch {
            throw DebriefSummarizerError.badResponse(String(raw.prefix(200)))
        }
    }

    static func parseConsolidation(_ raw: String) throws -> ConsolidationDelta {
        let data = try jsonData(from: raw)
        do {
            return try JSONDecoder().decode(ConsolidationDTO.self, from: data).toConsolidationDelta()
        } catch {
            throw DebriefSummarizerError.badResponse(String(raw.prefix(200)))
        }
    }

    /// The first plausible JSON object in `raw`, fences and surrounding prose
    /// stripped.
    private static func jsonData(from raw: String) throws -> Data {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            text = text
                .split(separator: "\n")
                .filter { !$0.hasPrefix("```") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let firstBrace = text.firstIndex(of: "{"),
              let lastBrace = text.lastIndex(of: "}"),
              firstBrace <= lastBrace,
              let data = text[firstBrace...lastBrace].data(using: .utf8) else {
            throw DebriefSummarizerError.badResponse(String(raw.prefix(200)))
        }
        return data
    }

    // MARK: - DTOs

    /// An id that an LLM may write either as a JSON number (`3`) or as a
    /// string (`"3"`) — both are common, and rejecting the string form throws
    /// away an otherwise perfectly good delta. A non-numeric string decodes to
    /// nil and the entry is dropped rather than failing the whole response.
    struct FlexibleID: Decodable, Equatable {
        let value: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intValue = try? container.decode(Int.self) {
                value = intValue
            } else if let stringValue = try? container.decode(String.self) {
                value = Int(stringValue.trimmingCharacters(in: .whitespaces))
            } else {
                value = nil
            }
        }
    }

    /// Decoding-only mirror of `DebriefDelta`. Every field is optional so a
    /// response that omits `resolvedIds`, or sends `summary: null`, still
    /// decodes. A missing/blank summary means "keep the previous paragraph":
    /// `DebriefAccumulator.apply` never overwrites with an empty string.
    private struct DeltaDTO: Decodable {
        struct ActionItemDTO: Decodable {
            var text: String
            var owner: String?
            var due: String?
        }

        struct CorrectionDTO: Decodable {
            var id: FlexibleID
            var text: String
            var owner: String?
            var due: String?
        }

        var summary: String?
        var newDecisions: [String]?
        var newActionItems: [ActionItemDTO]?
        var newOpenQuestions: [String]?
        var resolvedIds: [FlexibleID]?
        var corrections: [CorrectionDTO]?

        func toDebriefDelta() -> DebriefDelta {
            var newItems: [DebriefDelta.NewItem] = []
            newItems += (newDecisions ?? []).map { DebriefDelta.NewItem(kind: .decision, text: $0) }
            newItems += (newActionItems ?? []).map {
                DebriefDelta.NewItem(kind: .action, text: $0.text, owner: $0.owner, due: $0.due)
            }
            newItems += (newOpenQuestions ?? []).map { DebriefDelta.NewItem(kind: .openQuestion, text: $0) }

            return DebriefDelta(
                summary: summary ?? "",
                newItems: newItems,
                resolvedIds: (resolvedIds ?? []).compactMap(\.value),
                corrections: (corrections ?? []).compactMap { correction in
                    guard let id = correction.id.value else { return nil }
                    return DebriefDelta.Correction(
                        id: id,
                        text: correction.text,
                        owner: correction.owner,
                        due: correction.due
                    )
                }
            )
        }
    }

    private struct ConsolidationDTO: Decodable {
        struct DropDTO: Decodable {
            var id: FlexibleID
            var reason: String?
        }

        var summary: String?
        var dropIds: [DropDTO]?

        func toConsolidationDelta() -> ConsolidationDelta {
            ConsolidationDelta(
                summary: summary ?? "",
                dropIds: (dropIds ?? []).compactMap { drop in
                    guard let id = drop.id.value else { return nil }
                    return ConsolidationDelta.Drop(id: id, reason: drop.reason ?? "")
                }
            )
        }
    }
}

/// Delta engine backed by a local Ollama server's `/api/chat` endpoint, asking
/// the model for delta JSON.
///
/// The request/response plumbing mirrors `OllamaDebriefSummarizer` (same DTOs,
/// same availability probe semantics, same greedy default temperature). That
/// file is owned by another story and is not edited here, so the small amount
/// of request code is repeated rather than extracted.
final class OllamaDeltaSummarizer: DeltaSummarizing {
    let name = "Ollama"

    private let baseURL: URL
    private let model: String
    private let session: URLSession
    private let timeout: TimeInterval
    /// 0 (deterministic/greedy) by default, matching `OllamaDebriefSummarizer`
    /// and `FoundationModelsDeltaSummarizer`'s greedy sampling: the same chunk
    /// against the same state should produce the same delta.
    private let temperature: Double

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        model: String,
        session: URLSession = .shared,
        timeout: TimeInterval = 180,
        temperature: Double = 0
    ) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.timeout = timeout
        self.temperature = temperature
    }

    func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }
            let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return tags.models.contains {
                OllamaDebriefSummarizer.modelMatches(serverName: $0.name, configuredModel: model)
            }
        } catch {
            return false
        }
    }

    func extractDelta(
        state: DebriefState,
        chunk: String,
        chunkIndex: Int,
        language: String
    ) async throws -> DebriefDelta {
        let trimmedChunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChunk.isEmpty else {
            throw DebriefSummarizerError.emptyTranscript
        }

        let system = """
        \(DeltaPromptBuilder.deltaSystemPrompt(language: language))

        Return ONLY a JSON object with this shape, no prose before or after it:
        \(DeltaPromptBuilder.deltaJSONSchemaDescription)
        """
        let user = DeltaPromptBuilder.deltaUserPrompt(
            state: state,
            chunk: trimmedChunk,
            chunkIndex: chunkIndex,
            language: language
        )

        let content = try await chat(system: system, user: user)
        return try DebriefDeltaParser.parseDelta(content)
    }

    func consolidate(state: DebriefState, language: String) async throws -> ConsolidationDelta {
        let system = """
        \(DeltaPromptBuilder.consolidationSystemPrompt(language: language))

        Return ONLY a JSON object with this shape, no prose before or after it:
        \(DeltaPromptBuilder.consolidationJSONSchemaDescription)
        """
        let user = DeltaPromptBuilder.consolidationUserPrompt(state: state, language: language)

        let content = try await chat(system: system, user: user)
        return try DebriefDeltaParser.parseConsolidation(content)
    }

    /// One `/api/chat` round trip, returning the assistant message's raw text.
    private func chat(system: String, user: String) async throws -> String {
        let chatRequest = OllamaChatRequest(
            model: model,
            stream: false,
            format: "json",
            options: OllamaChatRequest.Options(temperature: temperature),
            messages: [
                OllamaChatRequest.Message(role: "system", content: system),
                OllamaChatRequest.Message(role: "user", content: user),
            ]
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(chatRequest)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw DebriefSummarizerError.timeout
        } catch let error as URLError {
            throw DebriefSummarizerError.unavailable(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DebriefSummarizerError.badResponse("No HTTP response")
        }
        guard httpResponse.statusCode == 200 else {
            // Ollama reports an over-long prompt as a 4xx/5xx whose body names
            // the context, e.g. "input length exceeds context length". Mapping
            // it to the typed error lets `RollingDebriefSummarizer.ingest`
            // retry smaller instead of losing the chunk.
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.range(of: "context", options: .caseInsensitive) != nil {
                throw DeltaSummarizerError.contextWindowExceeded("HTTP \(httpResponse.statusCode): \(body.prefix(200))")
            }
            throw DebriefSummarizerError.http(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(OllamaChatResponse.self, from: data).message.content
        } catch {
            throw DebriefSummarizerError.badResponse(String(describing: error))
        }
    }
}
