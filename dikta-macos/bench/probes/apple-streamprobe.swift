import Foundation
import Speech
import AVFoundation

// Simulates Dikta's actual input shape: a [Float] 16kHz mono PCM array already
// captured by AVAudioEngine (see AudioRecorder.swift), NOT an AVAudioFile.
// Tests: bestAvailableAudioFormat, [Float] -> AVAudioPCMBuffer conversion,
// AsyncStream<AnalyzerInput> feed via start(inputSequence:), finalizeAndFinish.

@available(macOS 26.0, *)
func makeBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
    buf.frameLength = AVAudioFrameCount(samples.count)
    guard let ch = buf.floatChannelData else { return nil }
    samples.withUnsafeBufferPointer { src in
        ch[0].update(from: src.baseAddress!, count: samples.count)
    }
    return buf
}

@available(macOS 26.0, *)
func transcribeFloatArray(_ samples: [Float], locale: Locale) async throws -> String {
    let transcriber = DictationTranscriber(locale: locale, preset: .shortDictation)

    if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await req.downloadAndInstall()
    }

    // Dikta's AudioRecorder already produces 16kHz mono Float32 (its own
    // target format for Whisper). Ask the analyzer what IT wants and convert
    // if they differ, rather than assuming 16kHz mono is accepted as-is.
    guard let wantFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        throw NSError(domain: "probe", code: 1)
    }
    print("wantFormat:", wantFormat)

    let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    guard var inputBuffer = makeBuffer(samples: samples, format: sourceFormat) else {
        throw NSError(domain: "probe", code: 2)
    }

    if wantFormat.sampleRate != sourceFormat.sampleRate || wantFormat.commonFormat != sourceFormat.commonFormat {
        guard let converter = AVAudioConverter(from: sourceFormat, to: wantFormat) else {
            throw NSError(domain: "probe", code: 3)
        }
        let ratio = wantFormat.sampleRate / sourceFormat.sampleRate
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: wantFormat, frameCapacity: AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024) else {
            throw NSError(domain: "probe", code: 4)
        }
        var err: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        converter.convert(to: outBuf, error: &err, withInputFrom: inputBlock)
        if let err { throw err }
        inputBuffer = outBuf
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    continuation.yield(AnalyzerInput(buffer: inputBuffer))
    continuation.finish()

    try await analyzer.start(inputSequence: stream)
    try await analyzer.finalizeAndFinishThroughEndOfInput()

    var text = ""
    for try await result in transcriber.results {
        text += String(result.text.characters)
    }
    return text
}

@main
struct StreamProbe {
    static func main() async {
        guard #available(macOS 26.0, *) else { print("macOS < 26"); return }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: "/tmp/sv.wav"))
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            try file.read(into: buf)
            guard let ch = buf.floatChannelData else { print("not float32/planar"); return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
            print("loaded \(samples.count) samples at \(format.sampleRate)Hz from sv.wav")

            let text = try await transcribeFloatArray(samples, locale: Locale(identifier: "sv-SE"))
            print("STREAM_RESULT:", text)
        } catch {
            print("ERROR:", error)
        }
    }
}
