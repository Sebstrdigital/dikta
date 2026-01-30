import Foundation

/// Service for formatting text using Ollama LLM
final class LLMService {
    private let baseURL = "http://localhost:11434"
    private let model: String

    init(model: String = "gemma3") {
        self.model = model
    }

    /// Check if Ollama is available
    func checkAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    /// Format text using the specified output mode
    /// - Parameters:
    ///   - text: Raw transcribed text
    ///   - mode: Output mode with prompt
    ///   - language: Language for the prompt
    /// - Returns: Formatted text
    func format(text: String, mode: OutputMode, language: Language = .english) async throws -> String {
        guard let prompt = mode.prompt(for: language) else {
            // Raw mode, return as-is
            return text
        }

        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw LLMServiceError.invalidURL
        }

        let fullPrompt = "\(prompt)\n\n\(text)"

        let requestBody: [String: Any] = [
            "model": model,
            "prompt": fullPrompt,
            "stream": false
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 30.0

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMServiceError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw LLMServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw LLMServiceError.parsingError
        }

        return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LLMServiceError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case parsingError
    case ollamaNotAvailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Ollama URL"
        case .invalidResponse:
            return "Invalid response from Ollama"
        case .httpError(let statusCode):
            return "Ollama HTTP error: \(statusCode)"
        case .parsingError:
            return "Failed to parse Ollama response"
        case .ollamaNotAvailable:
            return "Ollama is not running. Install from ollama.com and run: ollama pull gemma3"
        }
    }
}
