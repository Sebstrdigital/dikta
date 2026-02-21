import Foundation
import LlamaSwift

/// Service for formatting text using local llama.cpp inference
final class LocalLLMService: @unchecked Sendable {
    private static let modelPath = AppPaths.llmModelPath

    private static let contextSize: Int32 = 2048
    private static let temperature: Float = 0.3

    private var model: OpaquePointer? // llama_model*
    private let lock = NSLock()

    /// Whether the model file exists on disk
    var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: Self.modelPath)
    }

    /// Format text using the specified output mode
    func format(text: String, mode: OutputMode, language: Language = .english, customPrompt: String? = nil) async throws -> String {
        // For custom mode, use the provided custom prompt; for others, use the mode's built-in prompt
        let prompt: String
        if mode == .custom {
            guard let custom = customPrompt, !custom.isEmpty else { return text }
            prompt = custom
        } else {
            guard let modePrompt = mode.prompt(for: language) else { return text }
            prompt = modePrompt
        }

        return try await Task.detached { [self] in
            try self.runInference(prompt: prompt, text: text)
        }.value
    }

    private func ensureModelLoaded() throws {
        lock.lock()
        defer { lock.unlock() }

        if model != nil { return }

        guard isModelDownloaded else {
            throw LocalLLMError.modelNotDownloaded
        }

        AppLogger.llm.info("Loading LLM model...")

        var params = llama_model_default_params()
        params.n_gpu_layers = 99

        guard let loadedModel = llama_model_load_from_file(Self.modelPath, params) else {
            throw LocalLLMError.modelLoadFailed
        }

        model = loadedModel
        AppLogger.llm.info("LLM model loaded successfully")
    }

    private func runInference(prompt: String, text: String) throws -> String {
        try ensureModelLoaded()

        guard let model = model else {
            throw LocalLLMError.modelLoadFailed
        }

        // Build Gemma 3 chat prompt with delimiters to separate instruction from dictation
        let fullPrompt = "<start_of_turn>user\n\(prompt)\n\n---\n\(text)\n---<end_of_turn>\n<start_of_turn>model\n"

        // Create context for this inference
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(Self.contextSize)
        ctxParams.n_batch = 512

        guard let ctx = llama_init_from_model(model, ctxParams) else {
            throw LocalLLMError.contextCreationFailed
        }
        defer { llama_free(ctx) }

        // Tokenize input
        let promptTokens = tokenize(model: model, text: fullPrompt, addBos: true)
        guard !promptTokens.isEmpty else {
            throw LocalLLMError.tokenizationFailed
        }

        AppLogger.llm.debug("Prompt tokens: \(promptTokens.count)")

        // Process prompt using llama_batch_get_one
        var tokens = promptTokens
        var batch = tokens.withUnsafeMutableBufferPointer { buf in
            llama_batch_get_one(buf.baseAddress, Int32(buf.count))
        }

        guard llama_decode(ctx, batch) == 0 else {
            throw LocalLLMError.decodeFailed
        }

        // Create sampler
        let sampler = createSampler()
        defer { llama_sampler_free(sampler) }

        // Generate tokens
        var outputTokens: [llama_token] = []
        let maxNewTokens = Int(Self.contextSize) - promptTokens.count
        let vocab = llama_model_get_vocab(model)
        let eotToken = llama_vocab_eot(vocab)
        let eosToken = llama_vocab_eos(vocab)

        for _ in 0..<maxNewTokens {
            let newToken = llama_sampler_sample(sampler, ctx, -1)

            if newToken == eotToken || newToken == eosToken {
                break
            }

            outputTokens.append(newToken)

            // Prepare next batch with single token
            var singleToken = [newToken]
            batch = singleToken.withUnsafeMutableBufferPointer { buf in
                llama_batch_get_one(buf.baseAddress, 1)
            }

            guard llama_decode(ctx, batch) == 0 else {
                break
            }
        }

        // Detokenize
        let result = detokenize(model: model, tokens: outputTokens)
        AppLogger.llm.debug("Generated \(outputTokens.count) tokens")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenize(model: OpaquePointer, text: String, addBos: Bool) -> [llama_token] {
        let nTokensMax = Int32(text.utf8.count) + (addBos ? 1 : 0) + 1
        var tokens = [llama_token](repeating: 0, count: Int(nTokensMax))
        let vocab = llama_model_get_vocab(model)
        let nTokens = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, nTokensMax, addBos, true)
        guard nTokens >= 0 else { return [] }
        tokens.removeLast(Int(nTokensMax - nTokens))
        return tokens
    }

    private func detokenize(model: OpaquePointer, tokens: [llama_token]) -> String {
        let vocab = llama_model_get_vocab(model)
        var result = ""
        var buf = [CChar](repeating: 0, count: 256)
        for token in tokens {
            let nChars = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
            if nChars > 0 {
                result += String(cString: buf.prefix(Int(nChars)) + [0])
            }
        }
        return result
    }

    private func createSampler() -> UnsafeMutablePointer<llama_sampler> {
        let sparams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sparams)!
        llama_sampler_chain_add(chain, llama_sampler_init_temp(Self.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        return chain
    }

    deinit {
        if let model = model {
            llama_model_free(model)
        }
    }
}

enum LocalLLMError: Error, LocalizedError {
    case modelNotDownloaded
    case modelLoadFailed
    case contextCreationFailed
    case tokenizationFailed
    case decodeFailed
    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "LLM model not downloaded. Download it from Settings."
        case .modelLoadFailed:
            return "Failed to load LLM model"
        case .contextCreationFailed:
            return "Failed to create LLM context"
        case .tokenizationFailed:
            return "Failed to tokenize input"
        case .decodeFailed:
            return "LLM decode failed"
        }
    }
}
