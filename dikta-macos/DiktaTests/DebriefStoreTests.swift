import XCTest
import AVFoundation
@testable import Dikta

final class DebriefStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: DebriefStore!
    private let loader = AudioFileLoader()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DebriefStore(rootDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        store = nil
    }

    // MARK: - createSession

    func testCreateSessionUsesExpectedFolderNamePattern() throws {
        let date = makeDate(2026, 9, 17, 14, 30, 5)
        let paths = try store.createSession(date: date)

        XCTAssertEqual(paths.folder.lastPathComponent, "2026-09-17_14-30-05")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.folder.path))
    }

    func testCreateSessionAppendsSuffixOnCollision() throws {
        let date = makeDate(2026, 9, 17, 14, 30, 5)

        let first = try store.createSession(date: date)
        let second = try store.createSession(date: date)
        let third = try store.createSession(date: date)

        XCTAssertEqual(first.folder.lastPathComponent, "2026-09-17_14-30-05")
        XCTAssertEqual(second.folder.lastPathComponent, "2026-09-17_14-30-05-2")
        XCTAssertEqual(third.folder.lastPathComponent, "2026-09-17_14-30-05-3")
    }

    // MARK: - writeAudio

    func testWriteAudioProducesWavWithMatchingSampleCount() throws {
        let paths = try store.createSession(date: Date())
        let samples = makeSineSamples(count: 16000, amplitude: 0.5)

        try store.writeAudio(samples, to: paths)
        let loaded = try loader.load(url: paths.audio)

        XCTAssertEqual(loaded.count, samples.count)
    }

    func testWriteAudioRoundTripsSamplesWithinInt16Tolerance() throws {
        let paths = try store.createSession(date: Date())
        let samples = makeSineSamples(count: 16000, amplitude: 0.5)

        try store.writeAudio(samples, to: paths)
        let loaded = try loader.load(url: paths.audio)

        let tolerance: Float = 1.0 / 32768 * 2
        XCTAssertEqual(loaded.count, samples.count)
        for (original, roundTripped) in zip(samples, loaded) {
            XCTAssertEqual(roundTripped, original, accuracy: tolerance)
        }
    }

    // MARK: - DebriefTrack / streaming writer

    func testAudioURLForTrackUsesMeAndThemFilenames() throws {
        let paths = try store.createSession(date: Date())

        XCTAssertEqual(paths.audioURL(for: .me), paths.folder.appendingPathComponent("me.wav"))
        XCTAssertEqual(paths.audioURL(for: .them), paths.folder.appendingPathComponent("them.wav"))
    }

    func testHasTrackIsFalseBeforeTheTrackFileExists() throws {
        let paths = try store.createSession(date: Date())

        XCTAssertFalse(store.hasTrack(.me, in: paths))
        XCTAssertFalse(store.hasTrack(.them, in: paths))
    }

    func testMakeStreamingWriterCreatesFileImmediatelyButHasTrackStaysFalseUntilFramesAreFlushed() throws {
        let paths = try store.createSession(date: Date())

        let writer = try store.makeStreamingWriter(for: .me, in: paths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.audioURL(for: .me).path))
        XCTAssertFalse(store.hasTrack(.me, in: paths), "hasTrack should be false for a file that exists but has no flushed frames yet")

        try writer.append(makeSineSamples(count: 4000, amplitude: 0.5))
        try writer.flush()
        XCTAssertTrue(store.hasTrack(.me, in: paths), "hasTrack should be true once frames have been flushed")

        try writer.close()
        XCTAssertFalse(store.hasTrack(.them, in: paths))
    }

    func testMakeStreamingWriterForBothTracksRoundTripsIndependently() throws {
        let paths = try store.createSession(date: Date())

        let meWriter = try store.makeStreamingWriter(for: .me, in: paths)
        let themWriter = try store.makeStreamingWriter(for: .them, in: paths)

        let meSamples = makeSineSamples(count: 8000, amplitude: 0.5)
        let themSamples = makeSineSamples(count: 5000, amplitude: 0.2)

        try meWriter.append(meSamples)
        try themWriter.append(themSamples)
        try meWriter.close()
        try themWriter.close()

        let loadedMe = try loader.load(url: paths.audioURL(for: .me))
        let loadedThem = try loader.load(url: paths.audioURL(for: .them))

        XCTAssertEqual(loadedMe.count, meSamples.count)
        XCTAssertEqual(loadedThem.count, themSamples.count)
        XCTAssertTrue(store.hasTrack(.me, in: paths))
        XCTAssertTrue(store.hasTrack(.them, in: paths))
    }

    // MARK: - copyOriginalAudio

    func testCopyOriginalAudioPreservesExtension() throws {
        let paths = try store.createSession(date: Date())
        let source = tempDir.appendingPathComponent("import.m4a")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: source)

        try store.copyOriginalAudio(from: source, to: paths)

        let expected = paths.folder.appendingPathComponent("original.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertEqual(try Data(contentsOf: expected), try Data(contentsOf: source))
    }

    // MARK: - writeTranscript / writeSummary

    func testWriteTranscriptRoundTripsUTF8IncludingSwedish() throws {
        let paths = try store.createSession(date: Date())
        let text = "Mötet handlade om åäö och budgeten för kvartalet."

        try store.writeTranscript(text, to: paths)

        let readBack = try String(contentsOf: paths.transcript, encoding: .utf8)
        XCTAssertEqual(readBack, text)
    }

    func testWriteSummaryRoundTripsUTF8IncludingSwedish() throws {
        let paths = try store.createSession(date: Date())
        let text = "Sammanfattning: vi enades om att fördubbla resurserna i höst."

        try store.writeSummary(text, to: paths)

        let readBack = try String(contentsOf: paths.summary, encoding: .utf8)
        XCTAssertEqual(readBack, text)
    }

    // MARK: - Helpers

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: components)!
    }

    private func makeSineSamples(count: Int, amplitude: Float, frequency: Float = 440, sampleRate: Float = 16000) -> [Float] {
        (0..<count).map { index in
            amplitude * sinf(2.0 * Float.pi * frequency * Float(index) / sampleRate)
        }
    }
}
