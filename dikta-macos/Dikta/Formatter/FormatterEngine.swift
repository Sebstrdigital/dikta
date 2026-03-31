import Foundation

struct FormatterEngine {
    // MARK: - Lazy embedding splitter cache

    /// Cached embedding splitter, created on first use for a supported language.
    /// Using a static nonisolated(unsafe) var is safe here: worst case two threads
    /// both create an instance on first call; the second write is harmless because
    /// EmbeddingParagraphSplitter is a value type wrapping a shared singleton service.
    private static var _cachedEmbeddingSplitter: EmbeddingParagraphSplitter? = nil
    private static let cacheLock = NSLock()

    /// Returns a cached EmbeddingParagraphSplitter, creating it on first call.
    /// Returns nil if model loading fails (graceful fallback).
    private static func embeddingSplitter() -> EmbeddingParagraphSplitter? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = _cachedEmbeddingSplitter { return cached }
        do {
            // Force model load now (first format hotkey press).
            _ = try SentenceEmbeddingService.shared.loadModel()
            let splitter = EmbeddingParagraphSplitter()
            _cachedEmbeddingSplitter = splitter
            return splitter
        } catch {
            // Model missing or CoreML failure — heuristic-only fallback, no user-visible error.
            return nil
        }
    }

    // MARK: - Public API

    func format(_ text: String, style: FormatterStyle, language: Language = .english) -> String {
        switch style {
        case .message:
            return MessageFormatter().format(text)
        case .structure:
            var formatter = StructuredTextFormatter()
            if language.supportsEmbeddings {
                formatter.embeddingSplitter = FormatterEngine.embeddingSplitter()
            }
            return formatter.format(text)
        }
    }
}
