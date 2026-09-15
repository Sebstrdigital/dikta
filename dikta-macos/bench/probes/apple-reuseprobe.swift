import Foundation
import Speech
import AVFoundation

@available(macOS 26.0, *)
func loadSamples(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = file.processingFormat
    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "probe", code: 1)
    }
    try file.read(into: buf)
    guard let ch = buf.floatChannelData else { throw NSError(domain: "probe", code: 2) }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
}

@available(macOS 26.0, *)
func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
        buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
    }
    return buf
}

@available(macOS 26.0, *)
func feed(_ analyzer: SpeechAnalyzer, _ transcriber: DictationTranscriber, samples: [Float], label: String) async {
    do {
        guard let wantFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        var inBuf = makeBuffer(samples, format: src)
        if wantFormat.commonFormat != src.commonFormat || wantFormat.sampleRate != src.sampleRate {
            let conv = AVAudioConverter(from: src, to: wantFormat)!
            let outBuf = AVAudioPCMBuffer(pcmFormat: wantFormat, frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * (wantFormat.sampleRate/src.sampleRate)) + 1024)!
            var err: NSError?
            conv.convert(to: outBuf, error: &err) { _, status in status.pointee = .haveData; return inBuf }
            if let err { print("\(label) convert error: \(err)"); return }
            inBuf = outBuf
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        cont.yield(AnalyzerInput(buffer: inBuf))
        cont.finish()
        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        var text = ""
        for try await r in transcriber.results { text += String(r.text.characters) }
        print("\(label) OK: \"\(text)\"")
    } catch {
        print("\(label) THREW: \(error)")
    }
}

@main
struct ReuseProbe {
    static func main() async {
        guard #available(macOS 26.0, *) else { return }
        do {
            let svSamples = try loadSamples("/tmp/sv.wav")
            let transcriber = DictationTranscriber(locale: Locale(identifier: "sv-SE"), preset: .shortDictation)
            if let req = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try? await req.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            await feed(analyzer, transcriber, samples: svSamples, label: "utterance1 (same analyzer+transcriber)")
            await feed(analyzer, transcriber, samples: svSamples, label: "utterance2 (same analyzer+transcriber, reused)")
        } catch {
            print("SETUP ERROR: \(error)")
        }
    }
}
