import Foundation
import WhisperKit
import Speech
import AVFoundation

/// DiktaBench — standalone STT benchmark CLI for Dikta's WhisperKit and Apple
/// Dictation engines.
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
///   swift run DiktaBench --engine apple --language sv|en \
///       --audio-dir <dir> --out <results.jsonl>
///
/// `--engine` defaults to `whisper` (the original behaviour, `--repo`/`--variant`
/// required). `--engine apple` drives Apple's on-device `DictationTranscriber`
/// (Speech framework, macOS 26+) instead — `--repo`/`--variant` are ignored, and the
/// tool exits non-zero with a clear message on older macOS. See
/// `Dikta/Services/AppleDictationEngine.swift` and
/// `docs/review-2026-09/apple-dictation-engine-spec.md` for the call pattern this
/// mirrors.
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
    var engine: String
    var repo: String?
    var variant: String?
    var language: String
    var audioDir: String
    var out: String
}

func parseArgs() -> BenchArgs {
    var engine = "whisper"
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
        case "--engine": engine = value
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

    guard engine == "whisper" || engine == "apple" else {
        fail("Unknown --engine \(engine): expected whisper|apple")
    }

    guard let language, let audioDir, let out else {
        fail("""
        Usage: DiktaBench --repo <hf-repo> --variant <name> --language sv|en \
        --audio-dir <dir> --out <results.jsonl>
               DiktaBench --engine apple --language sv|en \
        --audio-dir <dir> --out <results.jsonl>
        """)
    }

    if engine == "whisper" {
        guard let repo, let variant else {
            fail("""
            --engine whisper (the default) requires --repo <hf-repo> --variant <name>.
            Usage: DiktaBench --repo <hf-repo> --variant <name> --language sv|en \
            --audio-dir <dir> --out <results.jsonl>
            """)
        }
        return BenchArgs(engine: engine, repo: repo, variant: variant, language: language, audioDir: audioDir, out: out)
    }

    // engine == "apple": --repo/--variant are ignored if passed.
    return BenchArgs(engine: engine, repo: nil, variant: nil, language: language, audioDir: audioDir, out: out)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Apple Dictation engine

/// Maps the harness's `--language sv|en` to the BCP-47 identifier
/// `DictationTranscriber` expects. Mirrors `AppleDictationEngine.bcp47(for:)`
/// (Dikta/Services/AppleDictationEngine.swift) but only for the two languages
/// this harness's FLEURS clip sets cover.
func appleBCP47(for language: String) -> String? {
    switch language {
    case "sv": return "sv-SE"
    case "en": return "en-US"
    default: return nil
    }
}

enum AppleBenchError: Error {
    case audioFormatUnavailable
    case conversionFailed
}

/// [Float] 16kHz mono -> AVAudioPCMBuffer in `format`, converting via
/// AVAudioConverter when `format` differs from the source (DictationTranscriber
/// wants Int16, not Float32 — spec §2). Deliberately diverges from the app's
/// former `AppleDictationEngine.convert(_:to:)`: the input block signals
/// `.endOfStream` after one supply and the guard also checks channel count.
func appleConvert(_ samples: [Float], to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
          let sourceBuffer = appleMakeFloatBuffer(samples: samples, format: sourceFormat) else {
        throw AppleBenchError.conversionFailed
    }

    guard format.commonFormat != sourceFormat.commonFormat
            || format.sampleRate != sourceFormat.sampleRate
            || format.channelCount != sourceFormat.channelCount else {
        return sourceBuffer
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
        throw AppleBenchError.conversionFailed
    }

    // Capacity is sized from the sample-rate ratio with a small rounding
    // margin — it no longer matters if this over-allocates, because the
    // input block below supplies `sourceBuffer` exactly once and then
    // signals .endOfStream, so the converter can't read past the end of the
    // real input and pad the tail with a second, wrapped-around read of it.
    let ratio = format.sampleRate / sourceFormat.sampleRate
    guard let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount((Double(sourceBuffer.frameLength) * ratio).rounded(.up)) + 16
    ) else {
        throw AppleBenchError.conversionFailed
    }

    var conversionError: NSError?
    var didSupply = false
    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
        if didSupply {
            outStatus.pointee = .endOfStream
            return nil
        }
        didSupply = true
        outStatus.pointee = .haveData
        return sourceBuffer
    }
    converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
    if let conversionError {
        throw conversionError
    }
    // AVAudioConverter.convert(to:...) sets outputBuffer.frameLength itself to
    // whatever it actually produced — never assume it filled frameCapacity.
    return outputBuffer
}

func appleMakeFloatBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
        return nil
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    guard let channelData = buffer.floatChannelData else { return nil }
    samples.withUnsafeBufferPointer { source in
        channelData[0].update(from: source.baseAddress!, count: samples.count)
    }
    return buffer
}

/// One Apple Dictation transcription. Mirrors `AppleDictationEngine.transcribe`
/// (locale already resolved by the caller): builds a **fresh**
/// `DictationTranscriber` + `SpeechAnalyzer` for this call (reuse across calls
/// has been observed to silently return "" — spec §6), converts `samples` to
/// whatever format the analyzer wants, feeds it through as a single-shot
/// `AsyncStream`, and collects the result text.
///
/// Deviation from `AppleDictationEngine.transcribe`: an empty result is
/// returned as an empty string rather than thrown as `.noSpeechDetected` — one
/// blank clip should be scored (as all-deletions), not abort the whole
/// benchmark run.
@available(macOS 26.0, *)
func appleTranscribeOnce(samples: [Float], locale: Locale) async throws -> String {
    let dictationTranscriber = DictationTranscriber(locale: locale, preset: .shortDictation)

    guard let wantFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [dictationTranscriber]) else {
        throw AppleBenchError.audioFormatUnavailable
    }

    let inputBuffer = try appleConvert(samples, to: wantFormat)

    let analyzer = SpeechAnalyzer(modules: [dictationTranscriber])
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    continuation.yield(AnalyzerInput(buffer: inputBuffer))
    continuation.finish()

    try await analyzer.start(inputSequence: stream)
    try await analyzer.finalizeAndFinishThroughEndOfInput()

    var text = ""
    for try await result in dictationTranscriber.results {
        text += String(result.text.characters)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Apple engine run loop, parallel to the WhisperKit loop in `DiktaBench.main()`
/// but with model load replaced by a one-time asset check/install (per spec §3,
/// `AssetInventory.assetInstallationRequest` is the reliable signal — not
/// `status(forModules:)`), and a fresh transcriber/analyzer built per clip
/// instead of one model reused for all of them.
@available(macOS 26.0, *)
func runAppleEngine(_ args: BenchArgs, audioFiles: [String], fm: FileManager) async {
    guard let bcp47 = appleBCP47(for: args.language) else {
        fail("--engine apple only supports --language sv|en in this harness, got \(args.language)")
    }
    let candidate = Locale(identifier: bcp47)
    guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: candidate) else {
        fail("Apple Dictation does not support locale \(bcp47)")
    }

    print("DiktaBench: engine=apple locale=\(locale.identifier) language=\(args.language) files=\(audioFiles.count)")

    // "Model load" for this engine = asset check/install, timed once up front.
    // downloadAndInstall() is cheap/near-instant when assets are already
    // installed (spec §3), so this also captures the "already installed" case.
    let loadStart = Date()
    let probe = DictationTranscriber(locale: locale, preset: .shortDictation)
    do {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    } catch {
        fail("Apple Dictation asset install failed for \(locale.identifier): \(error)")
    }
    let modelLoadSeconds = Date().timeIntervalSince(loadStart)
    print("Apple Dictation assets ready in \(String(format: "%.2f", modelLoadSeconds))s")

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
            text = try await appleTranscribeOnce(samples: audioSamples, locale: locale)
        } catch {
            fail("Apple transcription failed for \(audioPath): \(error)")
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

        if args.engine == "apple" {
            guard #available(macOS 26.0, *) else {
                fail("--engine apple requires macOS 26.0 or later (DictationTranscriber is unavailable on this OS).")
            }
            await runAppleEngine(args, audioFiles: audioFiles, fm: fm)
            return
        }

        guard let repo = args.repo, let variant = args.variant else {
            fail("--engine whisper requires --repo and --variant")
        }

        print("DiktaBench: repo=\(repo) variant=\(variant) language=\(args.language) files=\(audioFiles.count)")

        // Load model, timing the load.
        let loadStart = Date()
        let whisperKit: WhisperKit
        do {
            let wk = try await WhisperKit(
                model: variant,
                modelRepo: repo,
                verbose: false,
                prewarm: false,
                load: false,
                download: true
            )
            try await wk.loadModels()
            whisperKit = wk
        } catch {
            fail("Failed to load model \(variant) from \(repo): \(error)")
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
