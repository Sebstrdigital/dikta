import Foundation
import AVFoundation

enum AudioFileLoaderError: Error, LocalizedError {
    case unreadable(URL)
    case unsupportedFormat(URL)
    case conversionFailed(String)
    case empty(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not read audio file: \(url.lastPathComponent)"
        case .unsupportedFormat(let url):
            return "Unsupported audio format: \(url.lastPathComponent)"
        case .conversionFailed(let reason):
            return "Audio conversion failed: \(reason)"
        case .empty(let url):
            return "Audio file contains no samples: \(url.lastPathComponent)"
        }
    }
}

/// Loads an audio file from disk and converts it to 16 kHz mono Float32
/// samples, the format Whisper expects. Mirrors the live-recording
/// conversion in `AudioRecorder.processBuffer`, but reads from a file in
/// chunks via `AVAudioFile` instead of a live microphone tap.
///
/// Multi-channel input is downmixed to mono by averaging all channels,
/// sample-by-sample, before the result is resampled to 16 kHz — an
/// `AVAudioConverter` given a stereo (or wider) source and a mono
/// destination does *not* do this on its own with no explicit channel map;
/// left unhandled it silently drops every channel but the first.
struct AudioFileLoader {
    /// File extensions this loader accepts. Enforced by `load(url:)` and
    /// `duration(url:)` — a file with any other extension is rejected as
    /// `.unsupportedFormat` before it is opened.
    static let supportedExtensions: [String] = ["m4a", "mp3", "wav", "caf", "aiff", "aif", "mp4", "m4b", "flac"]

    /// Target sample rate for Whisper (16kHz), matching `AudioRecorder.sampleRate`.
    static let targetSampleRate: Double = 16000

    /// Number of frames requested from the source file per read.
    private static let chunkFrameCount: AVAudioFrameCount = 32768

    /// Loads `url` and returns its audio as 16 kHz mono Float32 samples.
    /// Any input sample rate, channel count (downmixed to mono), and sample
    /// format (integer or float) is accepted — the conversion is handled by
    /// `AVAudioConverter`.
    func load(url: URL) throws -> [Float] {
        try validateExtension(url)
        let file = try openFile(at: url)
        let inputFormat = file.processingFormat

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioFileLoaderError.unsupportedFormat(url)
        }

        // `AVAudioFile.processingFormat` is always non-interleaved Float32
        // regardless of the file's on-disk format (integer or float,
        // interleaved or not) — verified against an Int16 interleaved WAV.
        // The mono format the converter reads from stays at the *source*
        // sample rate; only the final converter step changes the rate.
        let converterSourceFormat: AVAudioFormat
        if inputFormat.channelCount > 1 {
            guard let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw AudioFileLoaderError.conversionFailed("Failed to create mono downmix format")
            }
            converterSourceFormat = monoFormat
        } else {
            converterSourceFormat = inputFormat
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioFileLoaderError.conversionFailed("Failed to create target 16kHz mono format")
        }

        guard let converter = AVAudioConverter(from: converterSourceFormat, to: outputFormat) else {
            throw AudioFileLoaderError.conversionFailed("Could not create converter for \(url.lastPathComponent)")
        }

        let samples = try convertAll(
            file: file,
            readFormat: inputFormat,
            converterSourceFormat: converterSourceFormat,
            outputFormat: outputFormat,
            converter: converter
        )

        guard !samples.isEmpty else {
            throw AudioFileLoaderError.empty(url)
        }

        return samples
    }

    /// Duration of the audio at `url`, in seconds.
    func duration(url: URL) throws -> TimeInterval {
        try validateExtension(url)
        let file = try openFile(at: url)
        guard file.processingFormat.sampleRate > 0 else {
            throw AudioFileLoaderError.unsupportedFormat(url)
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - Private

    private func validateExtension(_ url: URL) throws {
        guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw AudioFileLoaderError.unsupportedFormat(url)
        }
    }

    private func openFile(at url: URL) throws -> AVAudioFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioFileLoaderError.unreadable(url)
        }
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw AudioFileLoaderError.unreadable(url)
        }
    }

    /// Reads `file` to the end in chunks of `readFormat` (the file's own,
    /// possibly multi-channel, processing format), downmixes each chunk to
    /// mono if needed, and feeds the result through `converter` (mono at
    /// the source sample rate → mono at `outputFormat`'s sample rate).
    ///
    /// The input block tracks how many frames remain
    /// (`file.length - file.framePosition`) and signals `.endOfStream` as
    /// soon as none remain, *without* issuing a further read. Calling
    /// `AVAudioFile.read(into:frameCount:)` again once the file is already
    /// fully consumed throws a spurious generic error rather than
    /// returning zero frames, so this avoids that call entirely — which
    /// also ensures the converter never replays the final buffer.
    private func convertAll(
        file: AVAudioFile,
        readFormat: AVAudioFormat,
        converterSourceFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) throws -> [Float] {
        var result: [Float] = []
        var readError: Error?
        let needsDownmix = readFormat.channelCount > 1

        let inputBlock: AVAudioConverterInputBlock = { requestedFrameCount, outStatus in
            let remainingFrames = file.length - file.framePosition
            guard remainingFrames > 0 else {
                outStatus.pointee = .endOfStream
                return nil
            }

            let framesToRead = AVAudioFrameCount(min(remainingFrames, Int64(requestedFrameCount)))
            guard let rawBuffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: framesToRead) else {
                outStatus.pointee = .endOfStream
                return nil
            }

            do {
                try file.read(into: rawBuffer, frameCount: framesToRead)
            } catch {
                readError = error
                outStatus.pointee = .endOfStream
                return nil
            }

            guard rawBuffer.frameLength > 0 else {
                outStatus.pointee = .endOfStream
                return nil
            }

            guard needsDownmix else {
                outStatus.pointee = .haveData
                return rawBuffer
            }

            guard let monoBuffer = Self.downmix(rawBuffer, to: converterSourceFormat) else {
                readError = AudioFileLoaderError.conversionFailed("Failed to downmix \(readFormat.channelCount) channels to mono")
                outStatus.pointee = .endOfStream
                return nil
            }

            outStatus.pointee = .haveData
            return monoBuffer
        }

        // Allocated once and reused: `AVAudioConverter.convert(to:)`
        // overwrites `frameLength` (and the samples up to it) on every
        // call, so there is nothing to reset between iterations.
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: Self.chunkFrameCount) else {
            throw AudioFileLoaderError.conversionFailed("Failed to allocate output buffer")
        }

        convertLoop: while true {
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)

            if let readError {
                if let loaderError = readError as? AudioFileLoaderError {
                    throw loaderError
                }
                throw AudioFileLoaderError.conversionFailed(readError.localizedDescription)
            }
            if let conversionError {
                throw AudioFileLoaderError.conversionFailed(conversionError.localizedDescription)
            }

            if outputBuffer.frameLength > 0, let channelData = outputBuffer.floatChannelData {
                result.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
            }

            switch status {
            case .haveData, .inputRanDry:
                if outputBuffer.frameLength == 0 {
                    break convertLoop
                }
                continue convertLoop
            case .endOfStream:
                break convertLoop
            case .error:
                throw AudioFileLoaderError.conversionFailed("AVAudioConverter reported an error with no NSError detail")
            @unknown default:
                break convertLoop
            }
        }

        return result
    }

    /// Averages every channel of `buffer` (format `buffer.format`, which
    /// may be interleaved or deinterleaved) down to a single mono channel
    /// in `monoFormat`. Returns `nil` if `buffer` isn't Float32 or if
    /// allocation fails.
    private static func downmix(_ buffer: AVAudioPCMBuffer, to monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = buffer.frameLength

        guard channelCount > 0,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let sourceChannelData = buffer.floatChannelData,
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount),
              let monoChannelData = monoBuffer.floatChannelData
        else {
            return nil
        }

        monoBuffer.frameLength = frameCount
        let monoSamples = monoChannelData[0]
        let scale = Float(1.0 / Double(channelCount))

        if buffer.format.isInterleaved {
            // A single pointer holds all channels, laid out as
            // [frame0ch0, frame0ch1, ..., frame1ch0, frame1ch1, ...].
            let interleaved = sourceChannelData[0]
            for frame in 0..<Int(frameCount) {
                var sum: Float = 0
                let base = frame * channelCount
                for channel in 0..<channelCount {
                    sum += interleaved[base + channel]
                }
                monoSamples[frame] = sum * scale
            }
        } else {
            for frame in 0..<Int(frameCount) {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += sourceChannelData[channel][frame]
                }
                monoSamples[frame] = sum * scale
            }
        }

        return monoBuffer
    }
}
