import XCTest
@testable import Dikta

final class StreamingWavWriterTests: XCTestCase {
    private var tempDir: URL!
    private let loader = AudioFileLoader()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Append in pieces, then close

    func testAppendInSeveralPiecesThenCloseRoundTripsSampleCount() throws {
        let url = tempDir.appendingPathComponent("piecewise.wav")
        let writer = try StreamingWavWriter(url: url)

        let pieces = [
            makeSineSamples(count: 4000, amplitude: 0.5),
            makeSineSamples(count: 3000, amplitude: 0.3, phaseOffset: 4000),
            makeSineSamples(count: 5000, amplitude: 0.8, phaseOffset: 7000),
        ]
        for piece in pieces {
            try writer.append(piece)
        }
        try writer.close()

        let expected = pieces.flatMap { $0 }
        let loaded = try loader.load(url: url)

        XCTAssertEqual(writer.framesWritten, Int64(expected.count))
        XCTAssertEqual(loaded.count, expected.count)
    }

    func testAppendInSeveralPiecesThenCloseRoundTripsValuesWithinInt16Tolerance() throws {
        let url = tempDir.appendingPathComponent("piecewise-values.wav")
        let writer = try StreamingWavWriter(url: url)

        let pieces = [
            makeSineSamples(count: 4000, amplitude: 0.5),
            makeSineSamples(count: 3000, amplitude: 0.3, phaseOffset: 4000),
        ]
        for piece in pieces {
            try writer.append(piece)
        }
        try writer.close()

        let expected = pieces.flatMap { $0 }
        let loaded = try loader.load(url: url)

        let tolerance: Float = 1.0 / 32768 * 2
        XCTAssertEqual(loaded.count, expected.count)
        for (original, roundTripped) in zip(expected, loaded) {
            XCTAssertEqual(roundTripped, original, accuracy: tolerance)
        }
    }

    // MARK: - Crash safety: flush without close

    /// Simulates a crash: append N frames, flush (finalizing the header
    /// for N), append M *more* frames past that flush, then drop the
    /// writer without ever calling `close`. `deinit` must NOT flush the
    /// tail — a real crash never runs `deinit` at all, so if this writer's
    /// `deinit` quietly flushed on the way out, the test would pass for
    /// the wrong reason and hide a data-loss window that doesn't actually
    /// exist on a real crash. The header on disk must still report
    /// exactly N frames, not N + M.
    func testFlushWithoutCloseLeavesAValidFileWithFlushedFrameCountAndDeinitDoesNotFlushTheTail() throws {
        let url = tempDir.appendingPathComponent("crash-after-flush.wav")
        let flushedFrameCount = 4800
        let unflushedFrameCount = 1600

        try {
            let writer = try StreamingWavWriter(url: url)
            try writer.append(makeSineSamples(count: flushedFrameCount, amplitude: 0.5))
            try writer.flush()
            try writer.append(makeSineSamples(count: unflushedFrameCount, amplitude: 0.5, phaseOffset: flushedFrameCount))
            // `writer` goes out of scope here without `close()` — only
            // deinit's best-effort fd close runs, which must not flush.
        }()

        let loaded = try loader.load(url: url)
        XCTAssertEqual(loaded.count, flushedFrameCount, "Expected the header to still report only the flushed frame count, not the frames appended after the last flush")
    }

    /// The auto-flush interval (default 5s of audio) must also leave the
    /// file valid if the process dies right after, with no explicit flush
    /// or close call from the test.
    func testAutoFlushLeavesAValidFileAfterFlushIntervalIsExceeded() throws {
        let url = tempDir.appendingPathComponent("auto-flush.wav")
        let sampleRate: Double = 16000
        let writer = try StreamingWavWriter(url: url, sampleRate: sampleRate, flushInterval: 1)

        // 1.5s of audio at 16kHz, comfortably past the 1s auto-flush
        // interval, appended as one call so auto-flush fires inside it.
        let samples = makeSineSamples(count: Int(sampleRate * 1.5), amplitude: 0.4)
        try writer.append(samples)

        // No explicit flush() or close() — only the auto-flush inside
        // append() should have made the header valid.
        let loaded = try loader.load(url: url)
        XCTAssertEqual(loaded.count, samples.count)

        try writer.close()
    }

    // MARK: - Empty writer

    func testEmptyWriterClosesToAValidZeroFrameWav() throws {
        let url = tempDir.appendingPathComponent("empty.wav")
        let writer = try StreamingWavWriter(url: url)

        try writer.close()

        XCTAssertEqual(writer.framesWritten, 0)
        XCTAssertThrowsError(try loader.load(url: url)) { error in
            guard case AudioFileLoaderError.empty = error else {
                XCTFail("Expected .empty for a zero-frame WAV, got \(error)")
                return
            }
        }
    }

    // MARK: - Clamping

    func testAppendClampsOutOfRangeSamplesToInt16Extremes() throws {
        let url = tempDir.appendingPathComponent("clamped.wav")
        let writer = try StreamingWavWriter(url: url)

        try writer.append([2.0, -2.0, 1.5, -1.5, 0.0])
        try writer.close()

        let loaded = try loader.load(url: url)
        XCTAssertEqual(loaded.count, 5)

        let tolerance: Float = 1.0 / 32768 * 2
        XCTAssertEqual(loaded[0], 1.0, accuracy: tolerance)
        XCTAssertEqual(loaded[1], -1.0, accuracy: tolerance)
        XCTAssertEqual(loaded[2], 1.0, accuracy: tolerance)
        XCTAssertEqual(loaded[3], -1.0, accuracy: tolerance)
        XCTAssertEqual(loaded[4], 0.0, accuracy: tolerance)
    }

    // MARK: - Non-finite samples

    func testAppendMapsNonFiniteSamplesToZeroBeforeClamping() throws {
        let url = tempDir.appendingPathComponent("nan.wav")
        let writer = try StreamingWavWriter(url: url)

        try writer.append([.nan, .infinity, -.infinity, 0.25])
        try writer.close()

        let loaded = try loader.load(url: url)
        XCTAssertEqual(loaded.count, 4)

        let tolerance: Float = 1.0 / 32768 * 2
        XCTAssertEqual(loaded[0], 0.0, accuracy: tolerance, "NaN should map to silence")
        XCTAssertEqual(loaded[1], 0.0, accuracy: tolerance, "+infinity should map to silence, not clamp to +1")
        XCTAssertEqual(loaded[2], 0.0, accuracy: tolerance, "-infinity should map to silence, not clamp to -1")
        XCTAssertEqual(loaded[3], 0.25, accuracy: tolerance)
    }

    // MARK: - Post-close errors

    func testAppendAfterCloseThrows() throws {
        let url = tempDir.appendingPathComponent("closed.wav")
        let writer = try StreamingWavWriter(url: url)
        try writer.close()

        XCTAssertThrowsError(try writer.append([0.1, 0.2]))
    }

    // MARK: - Write-failure latching

    /// Once a write fails, every later `append` must throw `.failed`
    /// immediately, without attempting another write — appending past a
    /// failed write would land at the wrong file offset (byte-shifted
    /// data) instead of just truncating the stream.
    func testAppendLatchesFailureAndSubsequentAppendsThrowFailedWithoutWriting() throws {
        let handle = FailingFileHandle()
        let writer = try StreamingWavWriter(fileHandle: handle, sampleRate: 16000)

        handle.isArmed = true
        XCTAssertThrowsError(try writer.append([0.1, 0.2])) { error in
            guard case StreamingWavWriterError.failed = error else {
                XCTFail("Expected .failed, got \(error)")
                return
            }
        }

        let writeCountAfterFirstFailure = handle.writeCount
        XCTAssertThrowsError(try writer.append([0.3])) { error in
            guard case StreamingWavWriterError.failed = error else {
                XCTFail("Expected .failed on the second append too, got \(error)")
                return
            }
        }
        XCTAssertEqual(handle.writeCount, writeCountAfterFirstFailure, "A latched failure must short-circuit before touching the handle again")
    }

    /// `close()` on an already-failed writer must still attempt the
    /// header rewrite using the last known-good `framesWritten`, and must
    /// close the handle regardless of whether that rewrite succeeds.
    func testCloseAfterFailureStillRewritesHeaderWithLastKnownGoodFrameCountAndCloses() throws {
        let handle = FailingFileHandle()
        let writer = try StreamingWavWriter(fileHandle: handle, sampleRate: 16000)

        try writer.append(makeSineSamples(count: 100, amplitude: 0.5)) // succeeds: framesWritten == 100
        handle.isArmed = true
        XCTAssertThrowsError(try writer.append(makeSineSamples(count: 50, amplitude: 0.5)))
        XCTAssertEqual(writer.framesWritten, 100, "A failed append must not bump framesWritten")

        // Header-rewrite writes would also throw while armed; disarm right
        // before close() so we can observe close() actually attempting
        // (and this time succeeding at) the rewrite, proving it isn't
        // short-circuited just because the writer previously failed.
        handle.isArmed = false
        XCTAssertNoThrow(try writer.close())
        XCTAssertTrue(handle.isClosed)
        XCTAssertEqual(handle.dataChunkSize, 200, "Expected the header's data size to reflect the 100 last-known-good frames (200 bytes), not the 150 appended")
    }

    // MARK: - Helpers

    private func makeSineSamples(count: Int, amplitude: Float, frequency: Float = 440, sampleRate: Float = 16000, phaseOffset: Int = 0) -> [Float] {
        (0..<count).map { index in
            let sampleIndex = index + phaseOffset
            return amplitude * sinf(2.0 * Float.pi * frequency * Float(sampleIndex) / sampleRate)
        }
    }
}

/// Deterministic write-failure injection for `StreamingWavWriter` tests.
/// Backs a real in-memory byte buffer (so header bytes written after
/// re-arming can still be inspected), but throws on every `write` while
/// `isArmed` is true — simpler and more reliable than trying to provoke a
/// real `FileHandle` failure via a read-only path or a full disk.
private final class FailingFileHandle: StreamingWavFileHandle {
    private(set) var buffer = Data()
    private(set) var isClosed = false
    private(set) var writeCount = 0
    var isArmed = false

    private var offset = 0

    /// The 4-byte little-endian `data` subchunk size at header offset 40,
    /// decoded for assertions.
    var dataChunkSize: UInt32? {
        guard buffer.count >= 44 else { return nil }
        let bytes = Array(buffer[40..<44])
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    func write(contentsOf data: Data) throws {
        writeCount += 1
        if isArmed {
            throw NSError(domain: "FailingFileHandleTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulated write failure"])
        }
        let end = offset + data.count
        if buffer.count < end {
            buffer.append(Data(repeating: 0, count: end - buffer.count))
        }
        buffer.replaceSubrange(offset..<end, with: data)
        offset = end
    }

    func seek(toOffset newOffset: UInt64) throws {
        offset = Int(newOffset)
    }

    func synchronize() throws {}

    @discardableResult
    func seekToEnd() throws -> UInt64 {
        offset = buffer.count
        return UInt64(offset)
    }

    func close() throws {
        isClosed = true
    }
}
