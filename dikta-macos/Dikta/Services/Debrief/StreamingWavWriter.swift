import Foundation

enum StreamingWavWriterError: Error, LocalizedError {
    case cannotCreateFile(URL)
    case writerClosed
    /// A prior `append`/`flush` failed (e.g. ENOSPC, a partial write). The
    /// writer latches this and rejects every further `append`/`flush`
    /// immediately, rather than risk writing byte-shifted PCM data on top
    /// of a file whose write position may no longer match `framesWritten`.
    case failed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .cannotCreateFile(let url):
            return "Failed to create file for streaming audio write: \(url.lastPathComponent)"
        case .writerClosed:
            return "StreamingWavWriter has already been closed"
        case .failed(let underlying):
            return "StreamingWavWriter failed and can no longer accept writes: \(underlying.localizedDescription)"
        }
    }
}

/// Narrow seam over the subset of `FileHandle`'s throwing API this writer
/// uses. `FileHandle` conforms for free (see the extension below); tests
/// inject a fake conformer to force a deterministic write failure without
/// relying on flaky OS-level conditions like a full disk.
protocol StreamingWavFileHandle: AnyObject {
    func write(contentsOf data: Data) throws
    func seek(toOffset offset: UInt64) throws
    func synchronize() throws
    @discardableResult func seekToEnd() throws -> UInt64
    func close() throws
}

extension FileHandle: StreamingWavFileHandle {}

/// Incrementally writes 16-bit mono PCM WAV audio to disk as samples
/// arrive, instead of buffering an entire session in RAM until recording
/// stops (`DebriefStore.writeAudio` still does the RAM-buffered write, used
/// for imported/converted audio rather than live capture).
///
/// A 44-byte RIFF/WAVE header is written up front with zeroed chunk sizes,
/// then `append` streams sample data straight to disk. `flush` rewrites
/// just the two size fields in that header in place, so the file on disk
/// is always a valid, loadable WAV as of the last flush — even if the
/// process is killed before `close` ever runs. `append` also flushes
/// automatically once `flushInterval` seconds of audio has accumulated
/// since the last flush, so a crash loses at most that much audio.
///
/// Not thread-safe: `append`, `flush`, and `close` all mutate file-handle
/// position and internal counters with no locking. Callers must serialize
/// access to a single writer instance (e.g. from one recording queue),
/// same as the tap callback already does for the RAM-buffered path.
final class StreamingWavWriter {
    private static let bitsPerSample: UInt16 = 16
    private static let channels: UInt16 = 1

    private let fileHandle: StreamingWavFileHandle
    private let sampleRate: Double
    private let flushInterval: TimeInterval
    private var isClosed = false

    /// Set the moment any write to `fileHandle` throws. Once set, every
    /// later `append`/`flush` throws `.failed` immediately without
    /// touching the file — see the type doc comment.
    private var failure: Error?

    /// Total frames (samples) whose bytes have been *successfully* written
    /// to disk since `init` — i.e. "last known-good" frame count. A frame
    /// whose write throws is never counted here.
    private(set) var framesWritten: Int64 = 0

    /// Frames appended since the last flush; reset to 0 on every flush.
    private var framesSinceFlush: Int64 = 0

    /// Creates `url` (overwriting anything already there), writes the
    /// 44-byte placeholder header, and leaves the file ready to receive
    /// samples via `append`.
    convenience init(url: URL, sampleRate: Double = AudioFileLoader.targetSampleRate, flushInterval: TimeInterval = 5) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw StreamingWavWriterError.cannotCreateFile(url)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw StreamingWavWriterError.cannotCreateFile(url)
        }
        try self.init(fileHandle: handle, sampleRate: sampleRate, flushInterval: flushInterval)
    }

    /// Test seam: writes the header through an already-open handle instead
    /// of creating `url` itself, so failure-injection tests can supply a
    /// fake `StreamingWavFileHandle` whose writes throw deterministically.
    init(fileHandle: StreamingWavFileHandle, sampleRate: Double = AudioFileLoader.targetSampleRate, flushInterval: TimeInterval = 5) throws {
        self.fileHandle = fileHandle
        self.sampleRate = sampleRate
        self.flushInterval = flushInterval

        try fileHandle.write(contentsOf: Self.makeHeader(dataSize: 0, sampleRate: sampleRate))
    }

    /// Maps non-finite samples (NaN, +/-infinity) to silence, clamps the
    /// rest to [-1, 1], converts to little-endian Int16, and appends the
    /// bytes to the file. Auto-flushes once at least `flushInterval`
    /// seconds of audio has accumulated since the last flush (auto or
    /// explicit).
    ///
    /// If the writer has already failed (see `failure`), this throws
    /// `.failed` immediately and writes nothing — appending after a
    /// partial write would land at the wrong file offset and corrupt the
    /// stream instead of merely truncating it.
    func append(_ samples: [Float]) throws {
        guard !isClosed else { throw StreamingWavWriterError.writerClosed }
        if let failure {
            throw StreamingWavWriterError.failed(underlying: failure)
        }
        guard !samples.isEmpty else { return }

        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 2)
        for sample in samples {
            let sanitized = sample.isFinite ? sample : 0
            let clamped = max(-1.0, min(1.0, sanitized))
            let intValue = Int16((clamped * Float(Int16.max)).rounded())
            bytes.append(UInt8(truncatingIfNeeded: intValue))
            bytes.append(UInt8(truncatingIfNeeded: intValue >> 8))
        }

        do {
            try fileHandle.write(contentsOf: Data(bytes))
        } catch {
            failure = error
            throw StreamingWavWriterError.failed(underlying: error)
        }

        framesWritten += Int64(samples.count)
        framesSinceFlush += Int64(samples.count)

        if Double(framesSinceFlush) / sampleRate >= flushInterval {
            try flush()
        }
    }

    /// Rewrites the RIFF chunk size and `data` subchunk size in the header
    /// in place (seek + write, no full rewrite), then syncs to disk. Safe
    /// to call repeatedly. After this returns, the file is a valid WAV
    /// containing every frame appended so far, regardless of what happens
    /// next — this is what makes the writer crash-safe.
    ///
    /// Throws `.failed` immediately (without attempting a write) if the
    /// writer already failed — use `close()` to force a best-effort
    /// rewrite despite a prior failure.
    func flush() throws {
        guard !isClosed else { throw StreamingWavWriterError.writerClosed }
        if let failure {
            throw StreamingWavWriterError.failed(underlying: failure)
        }

        do {
            try rewriteHeaderSizes()
        } catch {
            failure = error
            throw StreamingWavWriterError.failed(underlying: error)
        }
        framesSinceFlush = 0
    }

    /// Best-effort final rewrite, then closes the file handle. Unlike
    /// `append`/`flush`, this does not refuse to run just because the
    /// writer already failed: it still attempts the header rewrite (using
    /// the last known-good `framesWritten`) so the file on disk reflects
    /// as much data as was actually written, then closes the handle
    /// regardless of whether that rewrite succeeds. Safe to call even if
    /// nothing was ever appended (produces a valid zero-frame WAV).
    func close() throws {
        guard !isClosed else { return }
        try? rewriteHeaderSizes()
        try fileHandle.close()
        isClosed = true
    }

    deinit {
        // Best-effort only, and deliberately does NOT flush: on a real
        // crash, `deinit` never runs at all, so any behavior that depends
        // on it (like flushing the tail here) would be a lie about what
        // "crash-safe" means. The file on disk is valid up to whatever was
        // last flushed (explicit or auto) — this just releases the fd.
        if !isClosed {
            try? fileHandle.close()
        }
    }

    // MARK: - Header

    /// Raw seek+write of the two size fields; no failure latching here —
    /// callers (`flush`, `close`) decide how to react to a throw.
    private func rewriteHeaderSizes() throws {
        let dataSize = UInt32(clamping: framesWritten * 2)
        let riffSize = UInt32(clamping: 36 + Int64(dataSize))

        try fileHandle.seek(toOffset: 4)
        try fileHandle.write(contentsOf: Self.littleEndianBytes(riffSize))

        try fileHandle.seek(toOffset: 40)
        try fileHandle.write(contentsOf: Self.littleEndianBytes(dataSize))

        try fileHandle.synchronize()
        try fileHandle.seekToEnd()
    }

    private static func makeHeader(dataSize: UInt32, sampleRate: Double) -> Data {
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let riffSize = UInt32(36) + dataSize

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndianBytes(riffSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndianBytes(UInt32(16))) // Subchunk1Size for PCM
        data.append(littleEndianBytes(UInt16(1))) // AudioFormat: 1 = PCM
        data.append(littleEndianBytes(channels))
        data.append(littleEndianBytes(UInt32(sampleRate)))
        data.append(littleEndianBytes(byteRate))
        data.append(littleEndianBytes(blockAlign))
        data.append(littleEndianBytes(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndianBytes(dataSize))
        return data
    }

    private static func littleEndianBytes(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 4)
    }

    private static func littleEndianBytes(_ value: UInt16) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 2)
    }
}
