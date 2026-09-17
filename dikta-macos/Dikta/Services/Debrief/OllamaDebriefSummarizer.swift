import Foundation

/// Summarizes a debrief transcript via a local Ollama server's `/api/chat`
/// endpoint, asking the model to respond with JSON.
final class OllamaDebriefSummarizer: DebriefSummarizer {
    let name = "Ollama"

    private let baseURL: URL
    private let model: String
    private let session: URLSession
    private let timeout: TimeInterval

    /// 0 (deterministic/greedy) by default so the same transcript produces the
    /// same structured output every run, matching
    /// `FoundationModelsDebriefSummarizer`'s default sampling mode (see
    /// "Tuning round 2" in docs/review-2026-09/debrief-probe-2026-09-17.md).
    /// Exposed as an init parameter so tests/probes can opt back into
    /// sampling if ever needed.
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

    /// True when the Ollama server responds to `/api/tags` within 2 seconds
    /// and lists a model matching `model` (see `Self.modelMatches`).
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
            return tags.models.contains { Self.modelMatches(serverName: $0.name, configuredModel: model) }
        } catch {
            return false
        }
    }

    /// Whether a model listed by the server (`serverName`, e.g. "llama3:8b")
    /// satisfies the configured `configuredModel`. Matching is
    /// one-directional: an exact match always counts, and an untagged
    /// configured model (no ":tag" suffix, e.g. "llama3") also matches any
    /// server model with that name as its tag prefix. A *tagged* configured
    /// model ("llama3:8b") only matches that exact string — it does NOT
    /// match a differently tagged server model like "llama3:70b".
    static func modelMatches(serverName: String, configuredModel: String) -> Bool {
        if serverName == configuredModel {
            return true
        }
        guard !configuredModel.contains(":") else {
            return false
        }
        return serverName.hasPrefix(configuredModel + ":")
    }

    func summarize(transcript: String, language: String) async throws -> DebriefSummary {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw DebriefSummarizerError.emptyTranscript
        }

        let chatRequest = OllamaChatRequest(
            model: model,
            stream: false,
            format: "json",
            options: OllamaChatRequest.Options(temperature: temperature),
            messages: [
                OllamaChatRequest.Message(role: "system", content: DebriefPromptBuilder.systemPrompt(language: language)),
                OllamaChatRequest.Message(role: "user", content: DebriefPromptBuilder.userPrompt(transcript: trimmedTranscript, language: language)),
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
            throw DebriefSummarizerError.http(httpResponse.statusCode)
        }

        let chatResponse: OllamaChatResponse
        do {
            chatResponse = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        } catch {
            throw DebriefSummarizerError.badResponse(String(describing: error))
        }

        return try DebriefSummaryParser.parse(chatResponse.message.content)
    }
}

// MARK: - DTOs

struct OllamaTagsResponse: Codable {
    struct Tag: Codable {
        var name: String
    }
    var models: [Tag]
}

struct OllamaChatRequest: Codable {
    struct Options: Codable {
        var temperature: Double
    }
    struct Message: Codable {
        var role: String
        var content: String
    }

    var model: String
    var stream: Bool
    var format: String
    var options: Options
    var messages: [Message]
}

struct OllamaChatResponse: Codable {
    struct Message: Codable {
        var role: String
        var content: String
    }
    var message: Message
}
