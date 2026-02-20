import Foundation
import Combine

/// Status of LLM model download
enum LLMSetupStatus: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(String)
}

/// Manages downloading and setup of the local LLM model
@MainActor
final class LLMSetupManager: ObservableObject {
    static let shared = LLMSetupManager()

    @Published var status: LLMSetupStatus = .notDownloaded

    static let modelURL = URL(string: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf")!
    private static let modelsDir = AppPaths.modelsDir

    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    private init() {
        checkExisting()
    }

    func checkExisting() {
        if FileManager.default.fileExists(atPath: AppPaths.llmModelPath) {
            status = .downloaded
        }
    }

    func download() {
        switch status {
        case .notDownloaded, .failed:
            break
        default:
            return
        }

        status = .downloading(progress: 0)
        AppLogger.llm.info("Starting LLM model download")

        let task = URLSession.shared.downloadTask(with: Self.modelURL) { [weak self] tempURL, response, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.observation = nil

                if let error = error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        self.status = .notDownloaded
                    } else {
                        AppLogger.llm.error("Download failed: \(error.localizedDescription)")
                        self.status = .failed(error.localizedDescription)
                    }
                    return
                }

                guard let tempURL = tempURL else {
                    self.status = .failed("No file received")
                    return
                }

                do {
                    try self.moveToFinalLocation(tempURL: tempURL)
                    AppLogger.llm.info("LLM model downloaded successfully")
                    self.status = .downloaded
                } catch {
                    AppLogger.llm.error("Failed to move model: \(error.localizedDescription)")
                    self.status = .failed(error.localizedDescription)
                }
            }
        }

        // Track progress
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.status = .downloading(progress: progress.fractionCompleted)
            }
        }

        downloadTask = task
        task.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        observation = nil
        status = .notDownloaded
    }

    /// Delete the downloaded model file
    func deleteModel() {
        let fm = FileManager.default
        let path = AppPaths.llmModelPath
        guard fm.fileExists(atPath: path) else { return }

        do {
            try fm.removeItem(atPath: path)
            AppLogger.llm.info("LLM model deleted")
            status = .notDownloaded
        } catch {
            AppLogger.llm.error("Failed to delete model: \(error.localizedDescription)")
        }
    }

    private func moveToFinalLocation(tempURL: URL) throws {
        let fm = FileManager.default
        let dir = Self.modelsDir

        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let dest = URL(fileURLWithPath: AppPaths.llmModelPath)

        // Remove existing file if present
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }

        try fm.moveItem(at: tempURL, to: dest)
    }
}
