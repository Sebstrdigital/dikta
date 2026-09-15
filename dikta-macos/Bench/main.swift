import Foundation
import WhisperKit

/// DiktaBench — standalone STT benchmark CLI for Dikta's WhisperKit engine.
///
/// Deliberately independent of the `Dikta` executable target (Swift Package Manager
/// does not allow one executable target to depend on another). Model identity is
/// passed as raw strings (`--repo` / `--variant`) rather than `WhisperModel`, so this
/// tool has zero dependency on the app's model enum and won't collide with concurrent
/// changes to it.
///
/// Usage:
///   swift run DiktaBench --repo <hf-repo> --variant <name> --language sv|en \
///       --audio-dir <dir> --out <results.jsonl>
///
/// For every .wav/.flac file in `--audio-dir`, transcribes it and appends one JSON
/// line to `--out`: {file, text, seconds_audio, seconds_wall, model_load_seconds}.
/// Transcript text is emitted raw (segments trimmed and joined) — normalisation
/// (lowercasing, punctuation stripping, NFC) happens on the Python scoring side so
/// both the reference and hypothesis go through the exact same normaliser.

struct BenchResult: Encodable {
    let file: String
    let text: String
    let seconds_audio: Double
    let seconds_wall: Double
    let model_load_seconds: Double
}

struct BenchArgs {
    var repo: String
    var variant: String
    var language: String
    var audioDir: String
    var out: String
}

func parseArgs() -> BenchArgs {
    var repo: String?
    var variant: String?
    var language: String?
    var audioDir: String?
    var out: String?

    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        let flag = args[i]
        guard i + 1 < args.count else {
            fail("Missing value for \(flag)")
        }
        let value = args[i + 1]
        switch flag {
        case "--repo": repo = value
        case "--variant": variant = value
        case "--language": language = value
        case "--audio-dir": audioDir = value
        case "--out": out = value
        default:
            fail("Unknown argument: \(flag)")
        }
        i += 2
    }

    guard let repo, let variant, let language, let audioDir, let out else {
        fail("""
        Usage: DiktaBench --repo <hf-repo> --variant <name> --language sv|en \
        --audio-dir <dir> --out <results.jsonl>
        """)
    }

    return BenchArgs(repo: repo, variant: variant, language: language, audioDir: audioDir, out: out)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

@main
struct DiktaBench {
    static func main() async {
        let args = parseArgs()

        let audioExtensions: Set<String> = ["wav", "flac"]
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: args.audioDir) else {
            fail("Could not read audio dir: \(args.audioDir)")
        }
        let audioFiles = entries
            .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { (args.audioDir as NSString).appendingPathComponent($0) }

        guard !audioFiles.isEmpty else {
            fail("No .wav/.flac files found in \(args.audioDir)")
        }

        print("DiktaBench: repo=\(args.repo) variant=\(args.variant) language=\(args.language) files=\(audioFiles.count)")

        // Load model, timing the load.
        let loadStart = Date()
        let whisperKit: WhisperKit
        do {
            let wk = try await WhisperKit(
                model: args.variant,
                modelRepo: args.repo,
                verbose: false,
                prewarm: false,
                load: false,
                download: true
            )
            try await wk.loadModels()
            whisperKit = wk
        } catch {
            fail("Failed to load model \(args.variant) from \(args.repo): \(error)")
        }
        let modelLoadSeconds = Date().timeIntervalSince(loadStart)
        print("Model loaded in \(String(format: "%.2f", modelLoadSeconds))s")

        // Decoding options mirror Transcriber.swift's `.normal` MicSensitivity
        // configuration (Dikta/Services/Transcriber.swift ~79-85), so bench results
        // reflect what the app actually does at default sensitivity.
        let decodingOptions = DecodingOptions(
            language: args.language,
            temperatureFallbackCount: 3,
            compressionRatioThreshold: 3.0,
            logProbThreshold: -1.5,
            noSpeechThreshold: 0.3
        )

        if fm.fileExists(atPath: args.out) {
            try? fm.removeItem(atPath: args.out)
        }
        fm.createFile(atPath: args.out, contents: nil)
        guard let outHandle = FileHandle(forWritingAtPath: args.out) else {
            fail("Could not open \(args.out) for writing")
        }

        let encoder = JSONEncoder()
        var totalAudioSeconds = 0.0
        var totalWallSeconds = 0.0

        for audioPath in audioFiles {
            let fileName = (audioPath as NSString).lastPathComponent

            let audioSamples: [Float]
            do {
                audioSamples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
            } catch {
                fail("Failed to load audio \(audioPath): \(error)")
            }
            let secondsAudio = Double(audioSamples.count) / Double(WhisperKit.sampleRate)

            let wallStart = Date()
            let text: String
            do {
                let results = try await whisperKit.transcribe(audioArray: audioSamples, decodeOptions: decodingOptions)
                let segments = results.flatMap { $0.segments }
                text = segments
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            } catch {
                fail("Transcription failed for \(audioPath): \(error)")
            }
            let secondsWall = Date().timeIntervalSince(wallStart)

            totalAudioSeconds += secondsAudio
            totalWallSeconds += secondsWall

            let result = BenchResult(
                file: fileName,
                text: text,
                seconds_audio: secondsAudio,
                seconds_wall: secondsWall,
                model_load_seconds: modelLoadSeconds
            )
            if let line = try? encoder.encode(result) {
                outHandle.write(line)
                outHandle.write("\n".data(using: .utf8)!)
            }

            print("  \(fileName): \(String(format: "%.2f", secondsWall))s wall / \(String(format: "%.2f", secondsAudio))s audio")
        }

        outHandle.closeFile()

        let rtf = totalAudioSeconds > 0 ? totalWallSeconds / totalAudioSeconds : 0
        print("""
        Summary: \(audioFiles.count) files, \
        total audio \(String(format: "%.1f", totalAudioSeconds))s, \
        total wall \(String(format: "%.1f", totalWallSeconds))s, \
        overall RTF \(String(format: "%.3f", rtf)), \
        model load \(String(format: "%.2f", modelLoadSeconds))s
        """)
    }
}
