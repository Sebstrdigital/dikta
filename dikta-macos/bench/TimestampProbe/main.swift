import Foundation
import WhisperKit

// MARK: - TimestampProbe
//
// THROWAWAY SPIKE — branch spike/call-debrief, tasks/decisions-call-debrief.md
// "Chunk boundary rule" + Spike item 2 (WhisperKit segment timestamps accuracy
// + prompt continuation across chunks).
//
// Verifies, on one real recording, using WhisperKit 1.1.0
// (argmax-oss-swift, product "WhisperKit"):
//   1. Full-file segment/word timestamps: monotonic? cover the file?
//   2. Hard-cut chunking at the file midpoint (deliberately NOT at silence),
//      2-5s overlap each side, dedup by segment timestamps vs. the cut point.
//   3. Same hard cut with NO overlap (plain concat) - the baseline the
//      overlap dedupe has to beat.
//   4. Prompt continuation: chunk B decoded with `promptTokens` set from the
//      tail of chunk A's text, vs. without.
//   5. A silence-aligned cut near the midpoint (RMS-based), zero overlap.
//
// PRIVACY: the input recording and everything it produces (segment text,
// merged transcripts) are never printed to stdout and never written outside
// `--out-dir` (default dikta-macos/bench/results/whisper-chunks/, which is
// gitignored via bench/results/* in dikta-macos/.gitignore). Only counts,
// timings and boolean checks go to stdout / the caller's report.
//
// Standalone SPM executable target, like DiktaBench: cannot depend on the
// `Dikta` executable target (SPM disallows executable-on-executable deps),
// so model identity is passed as raw --repo/--variant/--model-folder strings.
//
// Usage:
//   swift run TimestampProbe --repo <hf-repo> --variant <name> \
//       --language sv|en --audio <path-to-wav> [--out-dir <dir>]
//   swift run TimestampProbe --model-folder <path> --language sv|en \
//       --audio <path-to-wav> [--out-dir <dir>]

// MARK: - CLI args

struct Args {
    var repo: String?
    var variant: String?
    var modelFolder: String?
    var language: String
    var audioPath: String
    var outDir: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("ERROR: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func parseArgs() -> Args {
    var repo: String?
    var variant: String?
    var modelFolder: String?
    var language = "en"
    var audioPath: String?
    var outDir = "bench/results/whisper-chunks"

    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--repo": repo = iterator.next()
        case "--variant": variant = iterator.next()
        case "--model-folder": modelFolder = iterator.next()
        case "--language": language = iterator.next() ?? language
        case "--audio": audioPath = iterator.next()
        case "--out-dir": outDir = iterator.next() ?? outDir
        default: fail("Unknown argument: \(arg)")
        }
    }
    guard let audioPath else { fail("--audio is required") }
    if modelFolder == nil && (repo == nil || variant == nil) {
        fail("Provide --model-folder OR both --repo and --variant")
    }
    return Args(repo: repo, variant: variant, modelFolder: modelFolder, language: language, audioPath: audioPath, outDir: outDir)
}

// MARK: - Model loading (mirrors DiktaBench/main.swift's --repo/--variant and
// --model-folder handling, see bench/DiktaBench/main.swift)

func loadModel(_ args: Args) async throws -> (WhisperKit, Double) {
    let loadStart = Date()
    let whisperKit: WhisperKit
    if let modelFolder = args.modelFolder {
        whisperKit = try await WhisperKit(
            modelFolder: modelFolder,
            verbose: false,
            prewarm: false,
            load: false,
            download: false
        )
    } else {
        whisperKit = try await WhisperKit(
            model: args.variant,
            modelRepo: args.repo,
            verbose: false,
            prewarm: false,
            load: false,
            download: true
        )
    }
    try await whisperKit.loadModels()
    let loadSeconds = Date().timeIntervalSince(loadStart)
    return (whisperKit, loadSeconds)
}

// MARK: - Decoding options
//
// DecodingOptions.wordTimestamps and .promptTokens: WhisperKit source
// Sources/WhisperKit/Core/Configurations.swift:175, :180
// (checked out at dikta-macos/.build/checkouts/argmax-oss-swift, tag v1.1.0).

func decodingOptions(language: String, promptTokens: [Int]? = nil) -> DecodingOptions {
    DecodingOptions(
        task: .transcribe,
        language: language,
        temperatureFallbackCount: 3,
        wordTimestamps: true,
        promptTokens: promptTokens,
        compressionRatioThreshold: 3.0,
        logProbThreshold: -1.5
    )
}

// MARK: - Transcription

struct TranscribeOutcome {
    let segments: [TranscriptionSegment]
    let text: String
    let wallSeconds: Double
}

/// Transcribes a slice of `audioPath` (or the whole file when start/end are
/// nil). Segment times returned are LOCAL to the slice (start at 0), not
/// offset to the source file - callers doing chunk merging must offset
/// themselves (see `offsetSegments`).
///
/// `TranscriptionSegment.start`/`.end`: Configurations... no, Models.swift:577-578.
/// `whisperKit.transcribe(audioArray:decodeOptions:)`: WhisperKit.swift:987-1000.
func transcribeSlice(
    whisperKit: WhisperKit,
    audioPath: String,
    startTime: Double?,
    endTime: Double?,
    language: String,
    promptTokens: [Int]? = nil
) async throws -> TranscribeOutcome {
    // AudioProcessor.loadAudioAsFloatArray(fromPath:channelMode:startTime:endTime:)
    // Sources/WhisperKit/Core/Audio/AudioProcessor.swift:340.
    let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath, startTime: startTime, endTime: endTime)
    let options = decodingOptions(language: language, promptTokens: promptTokens)
    let wallStart = Date()
    let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
    let wallSeconds = Date().timeIntervalSince(wallStart)
    let segments = results.flatMap { $0.segments }
    let text = segments
        .map { $0.text.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    return TranscribeOutcome(segments: segments, text: text, wallSeconds: wallSeconds)
}

/// Shifts segment (and word) timestamps by `offset` seconds - used to convert
/// a chunk-local `TranscriptionSegment` into source-file-global time before
/// merging across chunks.
func offsetSegments(_ segments: [TranscriptionSegment], by offset: Double) -> [TranscriptionSegment] {
    segments.map { segment in
        var shifted = segment
        shifted.start = segment.start + Float(offset)
        shifted.end = segment.end + Float(offset)
        if var words = segment.words {
            for i in words.indices {
                words[i].start += Float(offset)
                words[i].end += Float(offset)
            }
            shifted.words = words
        }
        return shifted
    }
}

// MARK: - Chunk boundary rule merge (tasks/decisions-call-debrief.md
// "Chunk boundary rule"): keep A segments that end at/before the cut, keep B
// segments that start at/after the cut; for a segment straddling the cut in
// BOTH chunks, keep whichever chunk's copy sits further from that chunk's own
// edge (less likely to have been clipped by the hard cut).

func mergeWithOverlapDedupe(
    aSegments: [TranscriptionSegment],
    bSegmentsGlobal: [TranscriptionSegment],
    cutT: Double,
    aEdge: Double,
    bEdge: Double
) -> [TranscriptionSegment] {
    let aKeep = aSegments.filter { Double($0.end) <= cutT }
    let bKeep = bSegmentsGlobal.filter { Double($0.start) >= cutT }

    let aTail = aSegments.filter { Double($0.end) > cutT }.sorted { $0.start < $1.start }
    let bHead = bSegmentsGlobal.filter { Double($0.start) < cutT }.sorted { $0.start < $1.start }

    var straddlers: [TranscriptionSegment] = []
    var ai = 0
    var bi = 0
    while ai < aTail.count && bi < bHead.count {
        let a = aTail[ai]
        let b = bHead[bi]
        let overlaps = Double(a.start) < Double(b.end) && Double(b.start) < Double(a.end)
        if overlaps {
            let marginFromAEdge = aEdge - Double(a.end)
            let marginFromBEdge = Double(b.start) - bEdge
            straddlers.append(marginFromAEdge >= marginFromBEdge ? a : b)
            ai += 1
            bi += 1
        } else if a.start <= b.start {
            straddlers.append(a)
            ai += 1
        } else {
            straddlers.append(b)
            bi += 1
        }
    }
    while ai < aTail.count { straddlers.append(aTail[ai]); ai += 1 }
    while bi < bHead.count { straddlers.append(bHead[bi]); bi += 1 }

    return (aKeep + straddlers + bKeep).sorted { $0.start < $1.start }
}

// MARK: - Silence detection (decisions doc: "RMS window <= 0.01 over >= 400ms")

/// Scans `samples` (16kHz float, -1..1 range from AudioProcessor) in a window
/// of +/-`searchRadiusSeconds` around `centerSeconds` for the longest
/// contiguous run where a sliding `minSilenceMs`-wide RMS window stays at or
/// below `rmsThreshold`. Returns the midpoint of that run in seconds, or nil
/// if no silence is found in range.
func findLongestSilence(
    samples: [Float],
    sampleRate: Int,
    centerSeconds: Double,
    searchRadiusSeconds: Double,
    minSilenceMs: Double,
    rmsThreshold: Float
) -> Double? {
    let totalSeconds = Double(samples.count) / Double(sampleRate)
    let searchStart = max(0, centerSeconds - searchRadiusSeconds)
    let searchEnd = min(totalSeconds, centerSeconds + searchRadiusSeconds)
    let winSamples = max(1, Int((minSilenceMs / 1000.0) * Double(sampleRate)))
    let startIdx = Int(searchStart * Double(sampleRate))
    let endIdx = Int(searchEnd * Double(sampleRate))
    guard endIdx - startIdx > winSamples else { return nil }

    let step = max(1, winSamples / 4)
    var bestStart = -1
    var bestLen = 0
    var curStart = -1
    var i = startIdx
    while i + winSamples <= endIdx {
        var sumSquares: Float = 0
        for s in i..<(i + winSamples) {
            sumSquares += samples[s] * samples[s]
        }
        let rms = (sumSquares / Float(winSamples)).squareRoot()
        if rms <= rmsThreshold {
            if curStart == -1 { curStart = i }
        } else if curStart != -1 {
            let len = i - curStart
            if len > bestLen { bestLen = len; bestStart = curStart }
            curStart = -1
        }
        i += step
    }
    if curStart != -1 {
        let len = endIdx - curStart
        if len > bestLen { bestLen = len; bestStart = curStart }
    }
    guard bestStart >= 0 else { return nil }
    let midSample = bestStart + bestLen / 2
    return Double(midSample) / Double(sampleRate)
}

// MARK: - Character-level edit distance (Levenshtein) for step 4's
// with-prompt vs without-prompt comparison. Reported as a count only, never
// the text itself (privacy rule).

func editDistance(_ a: String, _ b: String) -> Int {
    let aChars = Array(a)
    let bChars = Array(b)
    if aChars.isEmpty { return bChars.count }
    if bChars.isEmpty { return aChars.count }
    var prev = Array(0...bChars.count)
    var curr = [Int](repeating: 0, count: bChars.count + 1)
    for i in 1...aChars.count {
        curr[0] = i
        for j in 1...bChars.count {
            if aChars[i - 1] == bChars[j - 1] {
                curr[j] = prev[j - 1]
            } else {
                curr[j] = 1 + min(prev[j - 1], prev[j], curr[j - 1])
            }
        }
        swap(&prev, &curr)
    }
    return prev[bChars.count]
}

// MARK: - Monotonic / coverage checks

func checkMonotonic(_ segments: [TranscriptionSegment]) -> [String] {
    var issues: [String] = []
    for i in 1..<max(segments.count, 1) where i < segments.count {
        if segments[i].start < segments[i - 1].start {
            issues.append("segment \(i) start (\(segments[i].start)) < segment \(i - 1) start (\(segments[i - 1].start))")
        }
        if segments[i - 1].end > segments[i].start + 0.05 {
            issues.append("segment \(i - 1) end (\(segments[i - 1].end)) overlaps segment \(i) start (\(segments[i].start)) by > 50ms")
        }
    }
    return issues
}

func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).count
}

func write(_ text: String, to path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - Main

@main
struct TimestampProbe {
    static func main() async {
        let args = parseArgs()
        let fm = FileManager.default
        guard fm.fileExists(atPath: args.audioPath) else {
            fail("Audio file not found: \(args.audioPath)")
        }
        try? fm.createDirectory(atPath: args.outDir, withIntermediateDirectories: true)

        print("TimestampProbe: language=\(args.language) audio=\(args.audioPath)")

        let (whisperKit, modelLoadSeconds) = await { () async -> (WhisperKit, Double) in
            do {
                return try await loadModel(args)
            } catch {
                fail("Model load failed: \(error)")
            }
        }()
        print("Model loaded in \(String(format: "%.2f", modelLoadSeconds))s")

        // Full-file samples, reused for duration, full-pass transcription and
        // the silence scan (avoids re-decoding the WAV three times).
        let fullSamples: [Float]
        do {
            fullSamples = try AudioProcessor.loadAudioAsFloatArray(fromPath: args.audioPath)
        } catch {
            fail("Failed to load audio: \(error)")
        }
        let sampleRate = WhisperKit.sampleRate // WhisperKit.swift:44
        let durationSeconds = Double(fullSamples.count) / Double(sampleRate)
        print("Audio duration: \(String(format: "%.2f", durationSeconds))s, \(fullSamples.count) samples @ \(sampleRate)Hz")

        // MARK: 1. Full pass

        let full: TranscribeOutcome
        do {
            full = try await transcribeSlice(
                whisperKit: whisperKit,
                audioPath: args.audioPath,
                startTime: nil,
                endTime: nil,
                language: args.language
            )
        } catch {
            fail("Full-pass transcription failed: \(error)")
        }
        let fullIssues = checkMonotonic(full.segments)
        let firstSeg = full.segments.first
        let lastSeg = full.segments.last
        let coverageGap = lastSeg.map { durationSeconds - Double($0.end) } ?? durationSeconds
        write(full.text, to: "\(args.outDir)/full.txt")

        print("""

        === 1. Full pass ===
        segments: \(full.segments.count)
        first segment: start=\(firstSeg.map { String($0.start) } ?? "n/a") end=\(firstSeg.map { String($0.end) } ?? "n/a")
        last segment:  start=\(lastSeg.map { String($0.start) } ?? "n/a") end=\(lastSeg.map { String($0.end) } ?? "n/a")
        monotonic: \(fullIssues.isEmpty) \(fullIssues.isEmpty ? "" : "(\(fullIssues.count) issue(s), first: \(fullIssues[0]))")
        coverage gap (duration - last segment end): \(String(format: "%.2f", coverageGap))s
        word count: \(wordCount(full.text))
        wall: \(String(format: "%.2f", full.wallSeconds))s
        """)

        // MARK: 2 & 3. Hard cut at midpoint, with and without overlap

        let T = durationSeconds / 2.0
        let overlapSeconds = 3.0
        let aEdgeOverlap = min(durationSeconds, T + overlapSeconds)
        let bEdgeOverlap = max(0, T - overlapSeconds)

        let chunkAOverlap: TranscribeOutcome
        let chunkBOverlap: TranscribeOutcome
        do {
            chunkAOverlap = try await transcribeSlice(
                whisperKit: whisperKit, audioPath: args.audioPath,
                startTime: 0, endTime: aEdgeOverlap, language: args.language
            )
            chunkBOverlap = try await transcribeSlice(
                whisperKit: whisperKit, audioPath: args.audioPath,
                startTime: bEdgeOverlap, endTime: nil, language: args.language
            )
        } catch {
            fail("Hard-cut (overlap) transcription failed: \(error)")
        }
        let chunkBOverlapGlobalSegments = offsetSegments(chunkBOverlap.segments, by: bEdgeOverlap)
        let mergedOverlapSegments = mergeWithOverlapDedupe(
            aSegments: chunkAOverlap.segments,
            bSegmentsGlobal: chunkBOverlapGlobalSegments,
            cutT: T, aEdge: aEdgeOverlap, bEdge: bEdgeOverlap
        )
        let mergedOverlapText = mergedOverlapSegments
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        write(mergedOverlapText, to: "\(args.outDir)/hardcut_overlap.txt")

        let chunkANoOverlap: TranscribeOutcome
        let chunkBNoOverlap: TranscribeOutcome
        do {
            chunkANoOverlap = try await transcribeSlice(
                whisperKit: whisperKit, audioPath: args.audioPath,
                startTime: 0, endTime: T, language: args.language
            )
            chunkBNoOverlap = try await transcribeSlice(
                whisperKit: whisperKit, audioPath: args.audioPath,
                startTime: T, endTime: nil, language: args.language
            )
        } catch {
            fail("Hard-cut (no overlap) transcription failed: \(error)")
        }
        let concatNoOverlapText = [chunkANoOverlap.text, chunkBNoOverlap.text]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        write(concatNoOverlapText, to: "\(args.outDir)/hardcut_nooverlap.txt")

        print("""

        === 2/3. Hard cut at midpoint T=\(String(format: "%.2f", T))s ===
        overlap: chunk A=[0, \(String(format: "%.2f", aEdgeOverlap))]s (\(chunkAOverlap.segments.count) segs, \(String(format: "%.2f", chunkAOverlap.wallSeconds))s wall), \
        chunk B=[\(String(format: "%.2f", bEdgeOverlap)), end]s (\(chunkBOverlap.segments.count) segs, \(String(format: "%.2f", chunkBOverlap.wallSeconds))s wall)
        merged (overlap dedupe): \(mergedOverlapSegments.count) segments, \(wordCount(mergedOverlapText)) words
        no-overlap: chunk A=[0, \(String(format: "%.2f", T))]s (\(chunkANoOverlap.segments.count) segs, \(String(format: "%.2f", chunkANoOverlap.wallSeconds))s wall), \
        chunk B=[\(String(format: "%.2f", T)), end]s (\(chunkBNoOverlap.segments.count) segs, \(String(format: "%.2f", chunkBNoOverlap.wallSeconds))s wall)
        concat (no dedupe): \(wordCount(concatNoOverlapText)) words
        full-pass word count for reference: \(wordCount(full.text))
        """)

        // MARK: 4. Prompt continuation

        let chunkAWords = chunkAOverlap.text.split(whereSeparator: { $0.isWhitespace })
        let last30 = chunkAWords.suffix(30).joined(separator: " ")
        guard let tokenizer = whisperKit.tokenizer else {
            fail("whisperKit.tokenizer is nil after loadModels() - cannot build prompt tokens")
        }
        // WhisperTokenizer.encode(text:): Models.swift:1153/1171-1173 ("swift-transformers
        // pass through", no special tokens added). WhisperKit prepends
        // <|startofprev|> itself and trims to specialTokenBegin - see
        // TextDecoder.swift:198-206.
        let promptTokens = tokenizer.encode(text: last30)

        let chunkBWithPrompt: TranscribeOutcome
        do {
            chunkBWithPrompt = try await transcribeSlice(
                whisperKit: whisperKit, audioPath: args.audioPath,
                startTime: bEdgeOverlap, endTime: nil, language: args.language,
                promptTokens: promptTokens
            )
        } catch {
            fail("Prompt-continuation transcription failed: \(error)")
        }

        func firstTwoSegmentsText(_ outcome: TranscribeOutcome) -> String {
            outcome.segments.prefix(2)
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
        }
        let withoutPromptHead = firstTwoSegmentsText(chunkBOverlap)
        let withPromptHead = firstTwoSegmentsText(chunkBWithPrompt)
        let promptEditDistance = editDistance(withoutPromptHead, withPromptHead)

        // Full chunk-B text with/without prompt, written to disk so a caller
        // can run a difflib word-diff - "first two segments" alone is
        // confounded by prompting changing segment GROUPING (fewer, longer
        // segments), not just wording, so its edit distance overstates how
        // much the actual transcribed content changed.
        write(chunkBOverlap.text, to: "\(args.outDir)/chunkB_noprompt.txt")
        write(chunkBWithPrompt.text, to: "\(args.outDir)/chunkB_withprompt.txt")

        print("""

        === 4. Prompt continuation on chunk B ===
        prompt: last \(chunkAWords.suffix(30).count) words of chunk A -> \(promptTokens.count) tokens
        chunk B without prompt: \(chunkBOverlap.segments.count) segments, \(wordCount(chunkBOverlap.text)) words, \(String(format: "%.2f", chunkBOverlap.wallSeconds))s wall
        chunk B with prompt:    \(chunkBWithPrompt.segments.count) segments, \(wordCount(chunkBWithPrompt.text)) words, \(String(format: "%.2f", chunkBWithPrompt.wallSeconds))s wall
        edit distance between first-two-segments text (without vs with prompt): \(promptEditDistance) chars \
        (without-prompt head length \(withoutPromptHead.count) chars, with-prompt head length \(withPromptHead.count) chars) \
        - NOTE: segment grouping differs (6 vs 2 segments), so this overstates content drift; \
        see chunkB_noprompt.txt / chunkB_withprompt.txt word counts above and run difflib for the real diff.
        """)

        // MARK: 5. Silence-aligned cut

        let silenceCutMaybe = findLongestSilence(
            samples: fullSamples, sampleRate: sampleRate,
            centerSeconds: T, searchRadiusSeconds: 30.0,
            minSilenceMs: 400.0, rmsThreshold: 0.01
        )

        if let silenceCut = silenceCutMaybe {
            let chunkASilence: TranscribeOutcome
            let chunkBSilence: TranscribeOutcome
            do {
                chunkASilence = try await transcribeSlice(
                    whisperKit: whisperKit, audioPath: args.audioPath,
                    startTime: 0, endTime: silenceCut, language: args.language
                )
                chunkBSilence = try await transcribeSlice(
                    whisperKit: whisperKit, audioPath: args.audioPath,
                    startTime: silenceCut, endTime: nil, language: args.language
                )
            } catch {
                fail("Silence-cut transcription failed: \(error)")
            }
            let concatSilenceText = [chunkASilence.text, chunkBSilence.text]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            write(concatSilenceText, to: "\(args.outDir)/silence_cut.txt")

            print("""

            === 5. Silence-aligned cut ===
            cut point: \(String(format: "%.2f", silenceCut))s (T was \(String(format: "%.2f", T))s, offset \(String(format: "%.2f", silenceCut - T))s)
            chunk A=[0, \(String(format: "%.2f", silenceCut))]s (\(chunkASilence.segments.count) segs, \(String(format: "%.2f", chunkASilence.wallSeconds))s wall), \
            chunk B=[\(String(format: "%.2f", silenceCut)), end]s (\(chunkBSilence.segments.count) segs, \(String(format: "%.2f", chunkBSilence.wallSeconds))s wall)
            concat word count: \(wordCount(concatSilenceText))
            """)
        } else {
            print("""

            === 5. Silence-aligned cut ===
            NO SILENCE FOUND within +/-30s of T=\(String(format: "%.2f", T))s at RMS<=0.01 for >=400ms.
            Skipped - see report for what this implies about the RMS threshold on this recording.
            """)
        }

        print("""

        === Files written to \(args.outDir) (gitignored, not quoted in report) ===
        full.txt, hardcut_overlap.txt, hardcut_nooverlap.txt\(silenceCutMaybe != nil ? ", silence_cut.txt" : " (silence_cut.txt skipped)")
        Run a difflib word-diff against full.txt to get diff counts.
        """)
    }
}
