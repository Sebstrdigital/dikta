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
