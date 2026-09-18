import Foundation
import AVFoundation

/// The two audio tracks a debrief session captures: the local mic (the
/// user) and the call's system/remote audio (everyone else). See decision
/// 4 in `tasks/decisions-call-debrief.md` — multi-party on the Them track
/// is a single mixed stream until diarization lands.
enum DebriefTrack: String {
    case me
    case them
}

/// Paths to the files that make up a single debrief session, all living
/// under one per-session folder.
struct DebriefSessionPaths {
    let folder: URL

    var audio: URL { folder.appendingPathComponent("audio.wav") }
    var transcript: URL { folder.appendingPathComponent("transcript.txt") }
    var summary: URL { folder.appendingPathComponent("summary.txt") }

    /// Per-track streaming WAV file (`me.wav` / `them.wav`) written
    /// continuously to disk during capture — see decision 7 (continuous
    /// stream to disk, crash-safe, constant RAM).
    func audioURL(for track: DebriefTrack) -> URL {
        folder.appendingPathComponent("\(track.rawValue).wav")
    }
}

enum DebriefStoreError: Error, LocalizedError {
    case formatCreationFailed
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Failed to create the PCM format used to write debrief audio"
        case .bufferAllocationFailed:
            return "Failed to allocate the PCM buffer used to write debrief audio"
        }
    }
}

/// Writes each debrief session (audio, transcript, summary) to its own
/// timestamped folder under `~/Documents/Dikta`.
final class DebriefStore {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let clock: () -> Date
    private let audioFileLoader = AudioFileLoader()

    /// Default root folder for debrief sessions: `~/Documents/Dikta`.
    static var defaultRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Dikta", isDirectory: true)
    }

    private static let sessionFolderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    init(
        rootDirectory: URL = DebriefStore.defaultRoot,
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.clock = clock
    }

    /// Creates a new session folder named after `date` (or now, if nil), in
    /// the form `yyyy-MM-dd_HH-mm-ss`. If a folder with that name already
    /// exists, `-2`, `-3`, etc. is appended until a free name is found.
    func createSession(date: Date? = nil) throws -> DebriefSessionPaths {
        let baseName = Self.sessionFolderFormatter.string(from: date ?? clock())

        var candidateName = baseName
        var suffix = 2
        while fileManager.fileExists(atPath: rootDirectory.appendingPathComponent(candidateName).path) {
            candidateName = "\(baseName)-\(suffix)"
            suffix += 1
        }

        let folder = rootDirectory.appendingPathComponent(candidateName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return DebriefSessionPaths(folder: folder)
    }

    /// Writes `samples` (16 kHz mono Float32) to `paths.audio` as a 16-bit
    /// mono PCM WAV file, clamping each sample to [-1, 1] before conversion.
    func writeAudio(_ samples: [Float], to paths: DebriefSessionPaths) throws {
        guard let bufferFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioFileLoader.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw DebriefStoreError.formatCreationFailed
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFileLoader.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let file = try AVAudioFile(
            forWriting: paths.audio,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        guard let buffer = AVAudioPCMBuffer(pcmFormat: bufferFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw DebriefStoreError.bufferAllocationFailed
        }
        buffer.frameLength = buffer.frameCapacity

        guard let channelData = buffer.int16ChannelData else {
            throw DebriefStoreError.bufferAllocationFailed
        }

        for (index, sample) in samples.enumerated() {
            let clamped = max(-1.0, min(1.0, sample))
            channelData[0][index] = Int16((clamped * Float(Int16.max)).rounded())
        }

        try file.write(from: buffer)
    }

    /// Creates a `StreamingWavWriter` at `paths.audioURL(for: track)`,
    /// ready for the caller to `append` live samples to as they're
    /// captured, rather than accumulating them in RAM for `writeAudio` to
    /// write out in one shot at the end of the session.
    func makeStreamingWriter(for track: DebriefTrack, in paths: DebriefSessionPaths) throws -> StreamingWavWriter {
        try StreamingWavWriter(url: paths.audioURL(for: track))
    }

    /// Whether `track` has actually been captured: the file exists AND its
    /// WAV data chunk is non-empty. `makeStreamingWriter` creates the file
    /// with a valid but zero-frame header immediately, so checking mere
    /// existence would report a track as present before any audio has
    /// been flushed to it.
    func hasTrack(_ track: DebriefTrack, in paths: DebriefSessionPaths) -> Bool {
        let url = paths.audioURL(for: track)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard let duration = try? audioFileLoader.duration(url: url) else { return false }
        return duration > 0
    }

    /// Copies the originally imported audio file next to `audio.wav`, as
    /// `original.<ext>`, preserving the source file's extension.
    func copyOriginalAudio(from source: URL, to paths: DebriefSessionPaths) throws {
        let ext = source.pathExtension.lowercased()
        let destinationName = ext.isEmpty ? "original" : "original.\(ext)"
        let destination = paths.folder.appendingPathComponent(destinationName)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    /// Writes `text` as UTF-8 to `paths.transcript`.
    func writeTranscript(_ text: String, to paths: DebriefSessionPaths) throws {
        try text.write(to: paths.transcript, atomically: true, encoding: .utf8)
    }

    /// Writes `text` as UTF-8 to `paths.summary`.
    func writeSummary(_ text: String, to paths: DebriefSessionPaths) throws {
        try text.write(to: paths.summary, atomically: true, encoding: .utf8)
    }
}
