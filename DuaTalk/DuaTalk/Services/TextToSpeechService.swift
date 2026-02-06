import Foundation
import AVFoundation
import AppKit

/// Available Kokoro TTS voices
enum KokoroVoice: String, CaseIterable {
    // American
    case af_heart = "af_heart"
    case af_bella = "af_bella"
    case af_nicole = "af_nicole"
    case af_sarah = "af_sarah"
    case af_sky = "af_sky"
    case am_adam = "am_adam"
    case am_michael = "am_michael"
    // British
    case bf_emma = "bf_emma"
    case bf_isabella = "bf_isabella"
    case bm_george = "bm_george"
    case bm_lewis = "bm_lewis"

    var displayName: String {
        switch self {
        case .af_heart: return "Heart (American F)"
        case .af_bella: return "Bella (American F)"
        case .af_nicole: return "Nicole (American F)"
        case .af_sarah: return "Sarah (American F)"
        case .af_sky: return "Sky (American F)"
        case .am_adam: return "Adam (American M)"
        case .am_michael: return "Michael (American M)"
        case .bf_emma: return "Emma (British F)"
        case .bf_isabella: return "Isabella (British F)"
        case .bm_george: return "George (British M)"
        case .bm_lewis: return "Lewis (British M)"
        }
    }
}

/// Service for text-to-speech using Kokoro server (keeps model in memory)
final class TextToSpeechService: NSObject {
    private static let serverBaseURL = "http://127.0.0.1:59123"
    private static let serverPort = 59123
    private static let pingTimeout: TimeInterval = 1.0
    private static let speakTimeout: TimeInterval = 120.0
    private static let serverStartupAttempts = 120
    private static let serverStartupInterval: UInt64 = 500_000_000 // 500ms

    private var audioPlayer: AVAudioPlayer?
    private var isSpeaking = false
    private let serverURL: String
    var voice: KokoroVoice = .af_heart
    private var serverProcess: Process?

    enum TTSError: LocalizedError {
        case serverNotRunning
        case synthesizeFailed(String)
        case playbackFailed
        case alreadySpeaking

        var errorDescription: String? {
            switch self {
            case .serverNotRunning:
                return "TTS not set up. Run: cd DuaTalk && ./setup.sh"
            case .synthesizeFailed(let msg):
                return "TTS failed: \(msg)"
            case .playbackFailed:
                return "Audio playback failed"
            case .alreadySpeaking:
                return "Already speaking"
            }
        }
    }

    override init() {
        self.serverURL = Self.serverBaseURL
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        // Try to start server if not running
        Task {
            await ensureServerRunning()
        }
    }

    @objc private func applicationWillTerminate() {
        terminateServer()
    }

    private func terminateServer() {
        serverProcess?.terminate()
        serverProcess = nil
    }

    /// Kill any stale server process on port 59123
    private func killStaleServer() {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-ti", ":\(Self.serverPort)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                // Kill stale processes
                for pidString in output.components(separatedBy: "\n") {
                    if let pid = Int32(pidString.trimmingCharacters(in: .whitespaces)) {
                        kill(pid, SIGTERM)
                    }
                }
                // Brief wait for processes to exit
                usleep(500_000)
            }
        } catch {
            // lsof not available or no process found — fine
        }
    }

    /// Check if TTS server is available
    func checkAvailable() async -> Bool {
        guard let url = URL(string: "\(serverURL)/ping") else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.pingTimeout

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Ensure the TTS server is running
    private func ensureServerRunning() async {
        if await checkAvailable() {
            return
        }

        // Start the server
        await startServer()

        // Wait for it to be ready (up to 60 seconds for model loading)
        for _ in 0..<Self.serverStartupAttempts {
            try? await Task.sleep(nanoseconds: Self.serverStartupInterval)
            if await checkAvailable() {
                return
            }
        }
    }

    /// Start the Kokoro server
    private func startServer() async {
        // Kill any stale server from a previous crash
        killStaleServer()

        let duatalkDir = NSHomeDirectory() + "/.duatalk"
        let serverScript = duatalkDir + "/kokoro_server.py"
        let pythonPath = duatalkDir + "/venv/bin/python"

        guard FileManager.default.fileExists(atPath: serverScript),
              FileManager.default.fileExists(atPath: pythonPath) else {
            AppLogger.tts.warning("Kokoro not set up. Run: cd DuaTalk && ./setup.sh")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [serverScript]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            serverProcess = process
            AppLogger.tts.info("Started Kokoro server")
        } catch {
            AppLogger.tts.error("Failed to start server: \(error.localizedDescription)")
        }
    }

    /// Check if currently speaking
    var speaking: Bool {
        isSpeaking || (audioPlayer?.isPlaying ?? false)
    }

    /// Speak text using XTTS v2 server
    func speak(_ text: String) async throws {
        guard !speaking else {
            throw TTSError.alreadySpeaking
        }

        // Ensure server is running
        if !(await checkAvailable()) {
            await ensureServerRunning()
            if !(await checkAvailable()) {
                throw TTSError.serverNotRunning
            }
        }

        isSpeaking = true

        // Create temp file for audio output
        let tempDir = FileManager.default.temporaryDirectory
        let audioFile = tempDir.appendingPathComponent("tts_\(UUID().uuidString).wav")

        defer {
            isSpeaking = false
            // Clean up temp file
            try? FileManager.default.removeItem(at: audioFile)
        }

        // Call the server
        guard let url = URL(string: "\(serverURL)/speak") else {
            throw TTSError.synthesizeFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.speakTimeout

        let payload: [String: Any] = [
            "text": text,
            "voice": voice.rawValue,
            "output_path": audioFile.path
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TTSError.synthesizeFailed("Server returned error")
        }

        // Play the audio file
        try await playAudio(url: audioFile)
    }

    /// Stop current speech
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
    }

    private func playAudio(url: URL) async throws {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()

            // Wait for playback to complete
            while audioPlayer?.isPlaying == true {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            audioPlayer = nil
        } catch {
            throw TTSError.playbackFailed
        }
    }

    deinit {
        terminateServer()
    }
}
