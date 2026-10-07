import XCTest
@testable import Dikta

@MainActor
final class TextToSpeechCancellationTests: XCTestCase {
    private final class Player: TTSPlayback {
        var isPlaying = false
        var playCount = 0
        var stopCount = 0
        var succeeds = true
        func play() -> Bool {
            playCount += 1
            isPlaying = succeeds
            return succeeds
        }
        func stop() { stopCount += 1; isPlaying = false }
    }

    /// All suspensions intentionally ignore cancellation until explicitly released.
    @MainActor
    private final class Controls {
        var requests: [URLRequest] = []
        var files: [URL] = []
        var players: [Player] = []
        var transports: [Int: CheckedContinuation<Void, Error>] = [:]
        var waits: [Int: CheckedContinuation<Void, Error>] = [:]
        var waitCount = 0

        func transport(_ request: URLRequest) async throws {
            let index = requests.count
            requests.append(request)
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            let file = URL(fileURLWithPath: payload["output_path"]!)
            files.append(file)
            try Data("synthetic audio marker".utf8).write(to: file)
            try await withCheckedThrowingContinuation { transports[index] = $0 }
        }
        func player(_ url: URL) -> any TTSPlayback {
            let player = Player()
            players.append(player)
            return player
        }
        func wait() async throws {
            let index = waitCount
            waitCount += 1
            try await withCheckedThrowingContinuation { waits[index] = $0 }
        }
        func finishTransport(_ index: Int, error: Error? = nil) {
            let continuation = transports.removeValue(forKey: index)
            if let error { continuation?.resume(throwing: error) }
            else { continuation?.resume() }
        }
        func finishWait(_ index: Int, error: Error? = nil) {
            let continuation = waits.removeValue(forKey: index)
            if let error { continuation?.resume(throwing: error) }
            else { continuation?.resume() }
        }
        func service() -> TextToSpeechService {
            TextToSpeechService(availability: { true }, transport: { try await self.transport($0) },
                                player: { self.player($0) }, playbackWait: { try await self.wait() })
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Controlled lifecycle did not reach its expected gate")
    }

    private func expectCancellation(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await task.value; XCTFail("Expected cancellation", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line) }
    }

    func testStopDuringSynthesisPreventsPlaybackAfterCancellationIgnorantReturn() async {
        let controls = Controls()
        let service = controls.service()
        let task = Task { try await service.speak("Synthetic first request") }
        await waitUntil { controls.transports[0] != nil }
        XCTAssertTrue(service.speaking)
        service.stop()
        service.stop()
        XCTAssertFalse(service.speaking)
        controls.finishTransport(0)
        await expectCancellation(task)
        XCTAssertTrue(controls.players.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controls.files[0].path))
    }

    func testOldSynthesisCannotStartOrClearNewPlayerOrRemoveNewResource() async throws {
        let controls = Controls()
        let service = controls.service()
        let old = Task { try await service.speak("Synthetic old request") }
        await waitUntil { controls.transports[0] != nil }
        service.stop()
        let newer = Task { try await service.speak("Synthetic newer request") }
        await waitUntil { controls.transports[1] != nil }
        controls.finishTransport(1)
        await waitUntil { controls.waits[0] != nil }
        controls.finishTransport(0)
        await expectCancellation(old)
        XCTAssertTrue(service.speaking)
        XCTAssertEqual(controls.players.count, 1)
        XCTAssertTrue(controls.players[0].isPlaying)
        XCTAssertEqual(controls.players[0].stopCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controls.files[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: controls.files[1].path))
        controls.players[0].isPlaying = false
        controls.finishWait(0)
        try await newer.value
        XCTAssertFalse(service.speaking)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controls.files[1].path))
    }

    func testStopDuringPlaybackAndOldWaitCannotStopNewPlayer() async throws {
        let controls = Controls()
        let service = controls.service()
        let old = Task { try await service.speak("Synthetic old playback") }
        await waitUntil { controls.transports[0] != nil }
        controls.finishTransport(0)
        await waitUntil { controls.waits[0] != nil }
        service.stop()
        service.stop()
        XCTAssertEqual(controls.players[0].stopCount, 1)
        let newer = Task { try await service.speak("Synthetic new playback") }
        await waitUntil { controls.transports[1] != nil }
        controls.finishTransport(1)
        await waitUntil { controls.waits[1] != nil }
        controls.finishWait(0)
        await expectCancellation(old)
        XCTAssertTrue(service.speaking)
        XCTAssertTrue(controls.players[1].isPlaying)
        XCTAssertEqual(controls.players[1].stopCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: controls.files[1].path))
        controls.players[1].isPlaying = false
        controls.finishWait(1)
        try await newer.value
        XCTAssertFalse(service.speaking)
    }

    func testParentCancellationDuringTransportCannotStartPlayback() async {
        let controls = Controls()
        let service = controls.service()
        let task = Task { try await service.speak("Synthetic cancelled request") }
        await waitUntil { controls.transports[0] != nil }
        task.cancel()
        controls.finishTransport(0)
        await expectCancellation(task)
        XCTAssertTrue(controls.players.isEmpty)
        XCTAssertFalse(service.speaking)
    }

    func testParentCancellationDuringPlaybackPreservesCancellationErrorAndStopsPlayer() async {
        let controls = Controls()
        let service = controls.service()
        let task = Task { try await service.speak("Synthetic cancelled playback") }
        await waitUntil { controls.transports[0] != nil }
        controls.finishTransport(0)
        await waitUntil { controls.waits[0] != nil }
        task.cancel()
        controls.finishWait(0, error: CancellationError())
        await expectCancellation(task)
        XCTAssertFalse(service.speaking)
        XCTAssertEqual(controls.players[0].stopCount, 1)
    }

    func testActiveRequestRejectsOverlapAndReleasesGuardAfterFailure() async throws {
        let controls = Controls()
        let service = controls.service()
        let first = Task { try await service.speak("Synthetic first request") }
        await waitUntil { controls.transports[0] != nil }
        do { try await service.speak("Rejected overlap"); XCTFail("Expected occupied guard") }
        catch {
            guard case TextToSpeechService.TTSError.alreadySpeaking = error else {
                return XCTFail("Expected alreadySpeaking, got \(error)")
            }
        }
        controls.finishTransport(0, error: TextToSpeechService.TTSError.synthesizeFailed("Synthetic failure"))
        do { try await first.value; XCTFail("Expected synthetic failure") } catch {}
        XCTAssertFalse(service.speaking)
        let next = Task { try await service.speak("Synthetic next request") }
        await waitUntil { controls.transports[1] != nil }
        service.stop()
        controls.finishTransport(1)
        await expectCancellation(next)
    }

    func testStopWhileCheckingAvailabilityDoesNotReachTransport() async {
        var availability: CheckedContinuation<Bool, Never>?
        var transportCount = 0
        let service = TextToSpeechService(
            availability: { await withCheckedContinuation { availability = $0 } },
            transport: { _ in transportCount += 1 },
            player: { _ in XCTFail("No player should be created"); return Player() }
        )
        let task = Task { try await service.speak("Synthetic pending availability") }
        await waitUntil { availability != nil }
        service.stop()
        availability?.resume(returning: true)
        await expectCancellation(task)
        XCTAssertEqual(transportCount, 0)
    }
}
