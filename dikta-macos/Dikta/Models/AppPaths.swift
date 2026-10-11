import Foundation

/// Centralized app file paths — everything under ~/Library/Application Support/Dikta/
enum AppPaths {
    /// ~/Library/Application Support/Dikta/
    static let appSupport: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Dikta").path
    }()

    // MARK: - LLM

    /// ~/Library/Application Support/Dikta/models/
    static let modelsDir = appSupport + "/models"

    /// Full path to the GGUF model file
    static let llmModelPath = modelsDir + "/gemma-3-4b-it-Q4_K_M.gguf"

    // Legacy Python TTS paths intentionally have no production accessors.
    // Old files remain on disk for downgrade compatibility; the native-only
    // candidate neither reads, rewrites, launches nor deletes them.

    // MARK: - Migration

    /// Migrate from old "Dua Talk" directory if it exists
    static func migrateIfNeeded() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldPath = base.appendingPathComponent("Dua Talk").path
        let newPath = base.appendingPathComponent("Dikta").path

        if fm.fileExists(atPath: oldPath) && !fm.fileExists(atPath: newPath) {
            try? fm.moveItem(atPath: oldPath, toPath: newPath)
        }
    }
}
