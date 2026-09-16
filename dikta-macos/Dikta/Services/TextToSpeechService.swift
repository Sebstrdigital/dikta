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
                return "TTS not set up. Open Dikta to set up Text-to-Speech."
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTTSInstalled),
            name: .ttsInstallCompleted,
            object: nil
        )

        // Try to start server if not running
        Task {
            await ensureServerRunning()
        }
    }

    @objc private func handleTTSInstalled() {
        Task {
            await ensureServerRunning()
        }
    }

    /// Whether TTS files are installed (venv + server script exist)
    var isSetUp: Bool {
        FileManager.default.fileExists(atPath: AppPaths.venvPython)
            && FileManager.default.fileExists(atPath: AppPaths.kokoroServerScript)
    }

    @objc private func applicationWillTerminate() {
        terminateServer()
    }

    private func terminateServer() {
        if let process = serverProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        serverProcess = nil
    }

    /// Runs `executable` with `args` and returns its stdout.
    ///
    /// Blocking: it waits for the child to exit, so it must not run on a Swift
    /// concurrency cooperative-pool thread. Call it through `offCooperativePool`.
    private static func captureOutput(of executable: String, _ args: [String]) -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            // Tool missing or not executable — treat as "no information".
            return ""
        }
        // Read before waiting: the child blocks once the pipe buffer fills, and
        // waiting first would then deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Runs blocking work on a background dispatch queue instead of a Swift
    /// concurrency cooperative-pool thread, which is a fixed, small resource
    /// (roughly one thread per core) that must never be parked in a
    /// `waitUntilExit()`.
    private static func offCooperativePool<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// PIDs of processes *listening* on `port`, never merely connected to it,
    /// and never this process.
    ///
    /// `lsof -i :<port>` matches a port in either the local *or* the remote
    /// endpoint, so it also reports every client with an open connection to
    /// `port`. Dikta pings `127.0.0.1:59123` itself (`checkAvailable`), so the
    /// unfiltered form reported Dikta's own PID whenever one of those sockets
    /// was still open — and `killStaleServer` then SIGTERMed Dikta, a silent
    /// exit with no crash report.
    ///
    /// `-sTCP:LISTEN` restricts the match to listening sockets, which only a
    /// server has; the explicit `getpid()` check is a second line of defence so
    /// no future change to the command can make Dikta kill itself.
    ///
    /// This answers "who is listening", not "who may be killed" — 59123 is an
    /// ordinary port that any program may legitimately occupy, so callers must
    /// still confirm identity via `staleKokoroServerPIDs(onPort:commandMarker:)`
    /// before signalling anything.
    static func listeningServerPIDs(onPort port: Int) -> [Int32] {
        let ownPID = getpid()
        return captureOutput(of: "/usr/sbin/lsof", ["-ti", "tcp:\(port)", "-sTCP:LISTEN"])
            .components(separatedBy: .newlines)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != ownPID }
    }

    /// PIDs listening on `port` whose command line identifies them as one of
    /// *our* Kokoro servers — a leftover from a previous crash.
    ///
    /// Port 59123 sits in macOS's ephemeral range (49152–65535), so it is not
    /// reserved for Dikta: another program can hold it either deliberately or
    /// because the kernel handed it out as a local port. Killing whatever
    /// answers there would terminate an unrelated process, so the command line
    /// must contain `commandMarker` (in production, the full path of the
    /// Kokoro server script this app launches) before we signal it.
    static func staleKokoroServerPIDs(
        onPort port: Int,
        commandMarker: String = AppPaths.kokoroServerScript
    ) -> [Int32] {
        listeningServerPIDs(onPort: port).filter { pid in
            captureOutput(of: "/bin/ps", ["-o", "command=", "-p", "\(pid)"])
                .contains(commandMarker)
        }
    }

    /// SIGTERMs every stale Kokoro server listening on `port` and returns the
    /// PIDs actually signalled (empty when the port is free, or held by
    /// something that is not ours).
    @discardableResult
    static func terminateStaleKokoroServers(
        onPort port: Int,
        commandMarker: String = AppPaths.kokoroServerScript
    ) -> [Int32] {
        let pids = staleKokoroServerPIDs(onPort: port, commandMarker: commandMarker)
        for pid in pids {
            kill(pid, SIGTERM)
        }
        return pids
    }

    /// Kill a Kokoro server left listening on port 59123 by a previous crash.
    private func killStaleServer() async {
        let signalled = await Self.offCooperativePool {
            Self.terminateStaleKokoroServers(onPort: Self.serverPort)
        }
        guard !signalled.isEmpty else { return }
        // Brief wait for the signalled processes to exit, without blocking a
        // cooperative-pool thread the way `usleep` did.
        try? await Task.sleep(nanoseconds: 500_000_000)
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
        let serverScript = AppPaths.kokoroServerScript
        let pythonPath = AppPaths.venvPython

        guard FileManager.default.fileExists(atPath: serverScript),
              FileManager.default.fileExists(atPath: pythonPath) else {
            AppLogger.tts.warning("Kokoro not set up — use onboarding to install")
            return
        }

        // Only now that TTS is known to be installed: clear a server left
        // behind by a previous crash. A user who never installed TTS has no
        // Kokoro server to clean up, so this must not run `lsof`/`ps` or go
        // anywhere near port 59123 on their machine.
        await killStaleServer()

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

    /// Speak text using Kokoro TTS server
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
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: .ttsInstallCompleted,
            object: nil
        )
        terminateServer()
    }
}
