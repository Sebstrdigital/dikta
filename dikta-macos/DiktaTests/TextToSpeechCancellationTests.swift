import XCTest
import AppKit
import CoreAudio
@testable import Dikta

@MainActor
private final class FakeNativeKokoroRuntime: NativeKokoroRuntimeServing {
    var prepareHandler: ((String) async throws -> NativeKokoroAssetSnapshot)?
    var synthesizeHandler: ((String, NativeKokoroAssetSnapshot) async throws -> Data)?
    private(set) var preparedVoices: [String] = []
    private(set) var syntheses: [(String, NativeKokoroAssetSnapshot)] = []
    private(set) var drainedCount = 0
    private(set) var stopCount = 0

    func snapshot(_ voice: String) -> NativeKokoroAssetSnapshot {
        .init(revision: "public-fixture-v1", voiceID: voice, voiceDigest: "digest-\(voice)")
    }
    func prepare(voiceID: String, speed: Float) async throws -> NativeKokoroAssetSnapshot {
        preparedVoices.append(voiceID)
        if let prepareHandler { return try await prepareHandler(voiceID) }
        return .init(revision: "public-fixture-v1", voiceID: voiceID, voiceDigest: "digest-\(voiceID)", speed: speed)
    }
    func synthesize(text: String, snapshot: NativeKokoroAssetSnapshot) async throws -> Data {
        syntheses.append((text, snapshot))
        if let synthesizeHandler { return try await synthesizeHandler(text, snapshot) }
        return Data("public synthetic wav".utf8)
    }
    func playbackDrained() { drainedCount += 1 }
    func stop() { stopCount += 1 }
}

@MainActor
private final class FakeNativeTTSPlayer: NativeTTSPlayback {
    var eventHandler: ((NativeTTSPlaybackEvent) -> Void)?
    var refusal = false
    private(set) var plays: [(Data, UUID)] = []
    private(set) var stopCount = 0

    func play(wav: Data, tag: UUID) throws {
        if refusal { throw AVNativeTTSPlayer.PlayerError.refused }
        plays.append((wav, tag))
        eventHandler?(.started(tag))
    }
    func stop() { stopCount += 1 }
    func finish(_ index: Int) { eventHandler?(.finished(plays[index].1)) }
    func fail(_ index: Int) { eventHandler?(.failed(plays[index].1)) }
    func interrupt(_ index: Int) { eventHandler?(.interrupted(plays[index].1)) }
    func emit(_ event: NativeTTSPlaybackEvent) { eventHandler?(event) }
}

@MainActor
final class TextToSpeechCancellationTests: XCTestCase {
    private func makeService() -> (TextToSpeechService, FakeNativeKokoroRuntime, FakeNativeTTSPlayer) {
        let runtime = FakeNativeKokoroRuntime()
        let player = FakeNativeTTSPlayer()
        return (TextToSpeechService(runtime: runtime, player: player), runtime, player)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Controlled lifecycle did not reach its expected gate", file: file, line: line)
    }

    private func expectCancellation(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await task.value; XCTFail("Expected cancellation", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line) }
    }

    func testFirstRequestWaitsForStartupThenCompletesOnlyAfterAudioDrain() async throws {
        let (service, runtime, player) = makeService()
        var startup: CheckedContinuation<NativeKokoroAssetSnapshot, Error>?
        runtime.prepareHandler = { voice in
            try await withCheckedThrowingContinuation { startup = $0 }
        }
        let task = Task { try await service.speak("Public short fixture.") }
        await waitUntil { startup != nil }
        XCTAssertTrue(service.speaking)
        XCTAssertTrue(player.plays.isEmpty)
        XCTAssertEqual(runtime.drainedCount, 0)
        startup?.resume(returning: runtime.snapshot("af_heart"))
        await waitUntil { player.plays.count == 1 }
        XCTAssertTrue(service.speaking)
        XCTAssertEqual(runtime.drainedCount, 0, "generation completion must not start idle")
        player.finish(0)
        try await task.value
        XCTAssertFalse(service.speaking)
        XCTAssertEqual(runtime.drainedCount, 1, "idle starts after final playback drain")
        XCTAssertEqual(runtime.syntheses.map(\.0), ["Public short fixture."])
    }

    func testVoiceIsFrozenAcrossStartupAndChangeAppliesToNextRequest() async throws {
        let (service, runtime, player) = makeService()
        var startup: CheckedContinuation<NativeKokoroAssetSnapshot, Error>?
        runtime.prepareHandler = { voice in
            if startup == nil { return try await withCheckedThrowingContinuation { startup = $0 } }
            return runtime.snapshot(voice)
        }
        let first = Task { try await service.speak("First public fixture.") }
        await waitUntil { startup != nil }
        service.voice = .af_bella
        startup?.resume(returning: runtime.snapshot("af_heart"))
        await waitUntil { player.plays.count == 1 }
        XCTAssertEqual(runtime.syntheses[0].1.voiceID, "af_heart")
        player.finish(0)
        try await first.value

        let second = Task { try await service.speak("Second public fixture.") }
        await waitUntil { player.plays.count == 2 }
        XCTAssertEqual(runtime.syntheses[1].1.voiceID, "af_bella")
        player.finish(1)
        try await second.value
    }

    func testOverlapRejectedWhileStartupWaits() async {
        let (service, runtime, _) = makeService()
        var startup: CheckedContinuation<NativeKokoroAssetSnapshot, Error>?
        runtime.prepareHandler = { _ in try await withCheckedThrowingContinuation { startup = $0 } }
        let first = Task { try await service.speak("First public fixture.") }
        await waitUntil { startup != nil }
        do { try await service.speak("Overlap fixture."); XCTFail("Expected overlap rejection") }
        catch { XCTAssertEqual(error as? TextToSpeechService.TTSError, .alreadySpeaking) }
        service.stop()
        startup?.resume(returning: runtime.snapshot("af_heart"))
        await expectCancellation(first)
    }

    func testStopDuringStartupInvalidatesBeforeLateReadinessAndNextRequestIsHealthy() async throws {
        let (service, runtime, player) = makeService()
        var startup: CheckedContinuation<NativeKokoroAssetSnapshot, Error>?
        runtime.prepareHandler = { _ in try await withCheckedThrowingContinuation { startup = $0 } }
        let stopped = Task { try await service.speak("Stopped startup fixture.") }
        await waitUntil { startup != nil }
        service.stop()
        XCTAssertFalse(service.speaking)
        XCTAssertEqual(runtime.stopCount, 1)
        startup?.resume(returning: runtime.snapshot("af_heart"))
        await expectCancellation(stopped)
        XCTAssertTrue(player.plays.isEmpty)

        runtime.prepareHandler = nil
        let next = Task { try await service.speak("Healthy next fixture.") }
        await waitUntil { player.plays.count == 1 }
        player.finish(0)
        try await next.value
    }

    func testStopDuringGenerationRejectsLateAudioAndCompletion() async {
        let (service, runtime, player) = makeService()
        var generation: CheckedContinuation<Data, Error>?
        runtime.synthesizeHandler = { _, _ in try await withCheckedThrowingContinuation { generation = $0 } }
        let task = Task { try await service.speak("Stopped generation fixture.") }
        await waitUntil { generation != nil }
        service.stop()
        generation?.resume(returning: Data("late wav".utf8))
        await expectCancellation(task)
        XCTAssertTrue(player.plays.isEmpty)
        XCTAssertEqual(runtime.drainedCount, 0)
    }

    func testStopDuringPlaybackIgnoresLateDelegateAndHealthyNextRead() async throws {
        let (service, runtime, player) = makeService()
        let old = Task { try await service.speak("Old playback fixture.") }
        await waitUntil { player.plays.count == 1 }
        let oldTag = player.plays[0].1
        service.stop()
        await expectCancellation(old)
        XCTAssertEqual(player.stopCount, 1)
        XCTAssertEqual(runtime.drainedCount, 0)

        let next = Task { try await service.speak("New playback fixture.") }
        await waitUntil { player.plays.count == 2 }
        player.emit(.finished(oldTag))
        XCTAssertTrue(service.speaking)
        XCTAssertEqual(runtime.drainedCount, 0)
        player.finish(1)
        try await next.value
        XCTAssertEqual(runtime.drainedCount, 1)
    }

    func testPlayerRefusalAndInterruptionRetireRuntimeAndReleaseGuard() async throws {
        let (service, runtime, player) = makeService()
        player.refusal = true
        do { try await service.speak("Refused playback fixture."); XCTFail("Expected refusal") }
        catch { XCTAssertEqual(error as? TextToSpeechService.TTSError, .playbackFailed) }
        XCTAssertFalse(service.speaking)
        XCTAssertEqual(runtime.stopCount, 1)

        player.refusal = false
        let interrupted = Task { try await service.speak("Interrupted fixture.") }
        await waitUntil { player.plays.count == 1 }
        player.interrupt(0)
        do { try await interrupted.value; XCTFail("Expected interruption") }
        catch { XCTAssertEqual(error as? TextToSpeechService.TTSError, .playbackInterrupted) }
        XCTAssertEqual(runtime.stopCount, 2)

        let healthy = Task { try await service.speak("Healthy after interruption.") }
        await waitUntil { player.plays.count == 2 }
        player.finish(1)
        try await healthy.value
    }

    func testHelperFailureIsSafeAndNextReadIsHealthy() async throws {
        let (service, runtime, player) = makeService()
        runtime.synthesizeHandler = { _, _ in throw NativeKokoroReadError.helperFailed(.synthesis) }
        do { try await service.speak("Failure fixture."); XCTFail("Expected helper failure") }
        catch {
            guard case .notAvailable(let message) = error as? TextToSpeechService.TTSError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(message.contains("Failure fixture"), "errors must not disclose selected text")
        }
        XCTAssertEqual(runtime.stopCount, 1)
        runtime.synthesizeHandler = nil
        let next = Task { try await service.speak("Public recovery fixture.") }
        await waitUntil { player.plays.count == 1 }
        player.finish(0)
        try await next.value
    }

    func testOversizeSelectionIsExplicitlyRejectedWithoutClippingOrNativeWork() async {
        let (service, runtime, player) = makeService()
        let text = String(repeating: "ordinary ", count: 40_000)
        do { try await service.speak(text); XCTFail("Expected bounded-work guard") }
        catch { XCTAssertEqual(error as? TextToSpeechService.TTSError, .unsupportedText) }
        XCTAssertTrue(runtime.preparedVoices.isEmpty)
        XCTAssertTrue(runtime.syntheses.isEmpty)
        XCTAssertTrue(player.plays.isEmpty)
    }

    func testChunkerPreservesExactRangesOrderWhitespaceUnicodeAndPunctuation() throws {
        let sentence = "  Dr. Ångström asked, ‘Ready?’  Yes!\nNumbers: 12,345.67; names: Kokoro.  "
        let source = String(repeating: sentence, count: 20)
        let chunks = try ProgressiveTextChunker().chunks(in: source)
        XCTAssertGreaterThan(chunks.count, 2)
        var cursor = source.startIndex
        var rebuilt = ""
        for (sequence, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.sequence, sequence)
            XCTAssertEqual(chunk.range.lowerBound, cursor)
            let piece = source[chunk.range]
            XCTAssertLessThanOrEqual(piece.utf8.count, ProgressiveTextChunker.maximumChunkUTF8Bytes)
            XCTAssertLessThanOrEqual(piece.split(whereSeparator: { $0.isWhitespace }).count,
                                     ProgressiveTextChunker.maximumChunkWords)
            rebuilt.append(contentsOf: piece)
            cursor = chunk.range.upperBound
        }
        XCTAssertEqual(cursor, source.endIndex)
        XCTAssertEqual(rebuilt, source, "chunk ranges may not normalize, drop, repeat, or reorder source")
    }

    func testChunkerNeverSplitsDecimalAbbreviationOrUnicodeLexicalTokens() throws {
        let prefix = String(repeating: "alpha ", count: 47)
        for token in ["3.14159", "Dr.Smith", "e.g.word", "naïve👩🏽‍💻word"] {
            let source = prefix + token + " beta gamma."
            let chunks = try ProgressiveTextChunker().chunks(in: source)
            XCTAssertGreaterThan(chunks.count, 1)
            XCTAssertTrue(String(source[chunks[0].range]).hasSuffix(token + " "), token)
            XCTAssertEqual(chunks.map { String(source[$0.range]) }.joined(), source)
            for boundary in chunks.dropLast().map(\.range.upperBound) {
                let before = source.index(before: boundary)
                XCTAssertTrue(source[before].isWhitespace || source[boundary].isWhitespace,
                              "a bounded split must not bisect \(token)")
            }
        }

        let punctuationSource = String(repeating: "alpha ", count: 40)
            + "Ends here. " + String(repeating: "omega ", count: 20)
        let punctuationChunks = try ProgressiveTextChunker().chunks(in: punctuationSource)
        XCTAssertTrue(String(punctuationSource[punctuationChunks[0].range]).hasSuffix("Ends here."))
        XCTAssertEqual(punctuationChunks.map { String(punctuationSource[$0.range]) }.joined(), punctuationSource)
    }

    func testLongReadKeepsOnlyOnePlayingAndOneLookaheadAndCompletesAfterFinalDrain() async throws {
        let (service, runtime, player) = makeService()
        let paragraph = String(repeating: "alpha beta gamma delta ", count: 55) + ". "
        let source = paragraph + paragraph + paragraph
        let expectedChunks = try ProgressiveTextChunker().chunks(in: source)
        XCTAssertGreaterThan(expectedChunks.count, 2)

        var secondGeneration: CheckedContinuation<Data, Error>?
        runtime.synthesizeHandler = { _, _ in
            if runtime.syntheses.count == 2 {
                return try await withCheckedThrowingContinuation { secondGeneration = $0 }
            }
            return Data("bounded wav \(runtime.syntheses.count)".utf8)
        }
        let request = TextToSpeechRequest(voice: .af_heart, speed: .slow)
        let task = Task { try await service.speak(source, request: request) }
        await waitUntil { player.plays.count == 1 && secondGeneration != nil }
        service.speed = .speedy
        XCTAssertEqual(runtime.syntheses.count, 2, "only the playing chunk and one SDK lookahead are admitted")
        XCTAssertEqual(runtime.drainedCount, 0, "generation receipt cannot release playback credit")

        secondGeneration?.resume(returning: Data("bounded wav 2".utf8))
        await Task.yield()
        XCTAssertEqual(player.plays.count, 1, "lookahead completion cannot replace playing audio")
        player.finish(0)

        for index in 1..<expectedChunks.count {
            await waitUntil { player.plays.count == index + 1 }
            XCTAssertLessThanOrEqual(runtime.syntheses.count, player.plays.count + 1)
            XCTAssertTrue(service.speaking)
            player.finish(index)
        }
        try await task.value
        XCTAssertFalse(service.speaking)
        XCTAssertEqual(runtime.syntheses.map(\.0), expectedChunks.map { String(source[$0.range]) })
        XCTAssertEqual(runtime.drainedCount, expectedChunks.count)
        XCTAssertEqual(Set(player.plays.map(\.1)).count, expectedChunks.count, "every audio chunk needs a distinct tag")
        XCTAssertEqual(runtime.syntheses.map { $0.1.speed }, Array(repeating: Float(0.75), count: expectedChunks.count),
                       "all admitted and later progressive chunks must retain the captured speed")

        let next = Task { try await service.speak("The next request uses the new speed.") }
        await waitUntil { player.plays.count == expectedChunks.count + 1 }
        XCTAssertEqual(runtime.syntheses.last?.1.speed, Float(1.75))
        player.finish(expectedChunks.count)
        try await next.value
    }

    func testStopDuringPlayingWithLookaheadClearsBothAndRejectsLateGeneration() async {
        let (service, runtime, player) = makeService()
        let source = String(repeating: "First bounded sentence has ordinary words. ", count: 30)
        var lookahead: CheckedContinuation<Data, Error>?
        runtime.synthesizeHandler = { _, _ in
            if runtime.syntheses.count == 2 {
                return try await withCheckedThrowingContinuation { lookahead = $0 }
            }
            return Data("first wav".utf8)
        }
        let task = Task { try await service.speak(source) }
        await waitUntil { player.plays.count == 1 && lookahead != nil }
        let staleTag = player.plays[0].1
        service.stop()
        await expectCancellation(task)
        XCTAssertFalse(service.speaking)
        XCTAssertEqual(player.stopCount, 1)
        XCTAssertEqual(runtime.stopCount, 1)
        lookahead?.resume(returning: Data("late lookahead wav".utf8))
        player.emit(.finished(staleTag))
        await Task.yield()
        XCTAssertEqual(player.plays.count, 1)
        XCTAssertEqual(runtime.drainedCount, 0)
    }

    func testLateOldLookaheadCannotEraseReplacementGenerationHandle() async {
        let (service, runtime, player) = makeService()
        let oldSource = String(repeating: "Old bounded sentence with words. ", count: 30)
        var oldLookahead: CheckedContinuation<Data, Error>?
        let replacementLookaheadCancelled = DispatchSemaphore(value: 0)
        runtime.synthesizeHandler = { _, _ in
            switch runtime.syntheses.count {
            case 2:
                return try await withCheckedThrowingContinuation { oldLookahead = $0 }
            case 4:
                return try await withTaskCancellationHandler {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return Data("unreachable replacement lookahead wav".utf8)
                } onCancel: {
                    replacementLookaheadCancelled.signal()
                }
            default:
                return Data("immediate wav".utf8)
            }
        }
        let old = Task { try await service.speak(oldSource) }
        await waitUntil { player.plays.count == 1 && oldLookahead != nil }
        player.finish(0)
        await waitUntil { runtime.drainedCount == 1 }
        service.stop()

        let replacementSource = String(repeating: "Replacement bounded sentence with words. ", count: 30)
        let replacement = Task { try await service.speak(replacementSource) }
        await waitUntil { runtime.syntheses.count == 4 && player.plays.count == 2 }
        oldLookahead?.resume(returning: Data("obsolete lookahead wav".utf8))
        await expectCancellation(old)

        service.stop()
        let directCancellationObserved = await Task.detached {
            replacementLookaheadCancelled.wait(timeout: .now() + 2) == .success
        }.value
        XCTAssertTrue(directCancellationObserved, "Stop must directly cancel the current request's lookahead")
        await expectCancellation(replacement)
        XCTAssertEqual(player.plays.count, 2)
        XCTAssertEqual(runtime.stopCount, 2)
    }

    func testLookaheadFailureDoesNotReplayAlreadySpokenSourceAndNextReadIsHealthy() async throws {
        let (service, runtime, player) = makeService()
        let source = String(repeating: "A bounded progressive sentence. ", count: 30)
        runtime.synthesizeHandler = { _, _ in
            if runtime.syntheses.count == 2 { throw NativeKokoroReadError.helperFailed(.synthesis) }
            return Data("public wav".utf8)
        }
        let failed = Task { try await service.speak(source) }
        await waitUntil { player.plays.count == 1 && runtime.syntheses.count == 2 }
        player.finish(0)
        do { try await failed.value; XCTFail("Expected partial failure") }
        catch { XCTAssertNotNil(error as? TextToSpeechService.TTSError) }
        XCTAssertEqual(player.plays.count, 1, "failed chunks must not replay earlier source")
        XCTAssertEqual(runtime.stopCount, 1)

        runtime.synthesizeHandler = nil
        let healthy = Task { try await service.speak("Healthy next request.") }
        await waitUntil { player.plays.count == 2 }
        player.finish(1)
        try await healthy.value
    }

    func testMissingSelectedVoiceAndUnsafeOSAreActionableWithNoHeartSubstitution() async {
        let (service, runtime, _) = makeService()
        service.voice = .bm_lewis
        runtime.prepareHandler = { voice in throw NativeKokoroReadError.selectedVoiceNotInstalled(voice) }
        let missingVoiceAvailable = await service.checkAvailable()
        XCTAssertFalse(missingVoiceAvailable)
        XCTAssertTrue(service.isSetUp)
        XCTAssertEqual(runtime.preparedVoices, ["bm_lewis"])
        XCTAssertTrue(service.unavailabilityMessage?.contains("bundled voice") == true)

        runtime.prepareHandler = { _ in throw NativeKokoroReadError.unsupportedOS }
        let unsafeOSAvailable = await service.checkAvailable()
        XCTAssertFalse(unsafeOSAvailable)
        XCTAssertTrue(service.unavailabilityMessage?.contains("26.4–26.5") == true)
    }

    func testParentCancellationDuringCancellationIgnorantStartupIsSilentAndBounded() async {
        let (service, runtime, player) = makeService()
        var startup: CheckedContinuation<NativeKokoroAssetSnapshot, Error>?
        runtime.prepareHandler = { _ in try await withCheckedThrowingContinuation { startup = $0 } }
        let task = Task { try await service.speak("Cancelled parent fixture.") }
        await waitUntil { startup != nil }
        task.cancel()
        await waitUntil { runtime.stopCount == 1 }
        startup?.resume(returning: runtime.snapshot("af_heart"))
        await expectCancellation(task)
        XCTAssertFalse(service.speaking)
        XCTAssertTrue(player.plays.isEmpty)
    }
}

@MainActor
private final class FakeNativeAudioHandle: NativeAudioHandle {
    let duration: TimeInterval
    var completion: ((Bool) -> Void)?
    private(set) var stopped = false
    init(duration: TimeInterval = 0.01) { self.duration = duration }
    func prepare() {}
    func play() -> Bool { true }
    func stop() { stopped = true }
    func finish(_ success: Bool) { completion?(success) }
}

@MainActor
private final class FakeNativeAudioInterruptionSource: NativeAudioInterruptionSource {
    private var handler: (() -> Void)?
    func install(_ handler: @escaping () -> Void) { self.handler = handler }
    func uninstall() { handler = nil }
    func fire() { handler?() }
}

private actor NativePlayerTestClock {
    private var calls = 0
    func sleep(_ nanoseconds: UInt64) async throws {
        calls += 1
        if calls == 1 { return }
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

@MainActor
private final class FakeNativeAudioHardware: NativeAudioHardwareObserving {
    final class Registration {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let callback: () -> Void
        var removed = false
        init(object: AudioObjectID, selector: AudioObjectPropertySelector, callback: @escaping () -> Void) {
            self.object = object; self.selector = selector; self.callback = callback
        }
    }
    var defaultOutputDevice: AudioObjectID = 41
    private(set) var registrations: [Registration] = []
    func observe(object: AudioObjectID, selector: AudioObjectPropertySelector,
                 handler: @escaping () -> Void) -> (() -> Void)? {
        let registration = Registration(object: object, selector: selector, callback: handler)
        registrations.append(registration)
        return {
            XCTAssertFalse(registration.removed, "each CoreAudio token must be removed once")
            registration.removed = true
        }
    }
}

@MainActor
final class AVNativeTTSPlayerLifecycleTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }

    func testProductionPlayerInterruptionIsTerminalOnceRejectsLateCallbackAndRecovers() async throws {
        let source = FakeNativeAudioInterruptionSource()
        var handles: [FakeNativeAudioHandle] = []
        let player = AVNativeTTSPlayer(makeHandle: { _ in
            let handle = FakeNativeAudioHandle(); handles.append(handle); return handle
        }, interruptionSource: source)
        var events: [NativeTTSPlaybackEvent] = []
        player.eventHandler = { events.append($0) }

        let old = UUID()
        try player.play(wav: Data("synthetic wav".utf8), tag: old)
        source.fire()
        handles[0].finish(true)
        source.fire()
        XCTAssertEqual(events, [.started(old), .interrupted(old)])
        XCTAssertTrue(handles[0].stopped)

        let fresh = UUID()
        try player.play(wav: Data("fresh synthetic wav".utf8), tag: fresh)
        handles[1].finish(true)
        await Task.yield()
        XCTAssertEqual(Array(events.suffix(2)), [.started(fresh), .finished(fresh)])
    }

    func testDurationWatchdogTerminatesMissingCallbackOnceAndNextPlaybackCompletes() async throws {
        let source = FakeNativeAudioInterruptionSource()
        let clock = NativePlayerTestClock()
        var handles: [FakeNativeAudioHandle] = []
        let player = AVNativeTTSPlayer(makeHandle: { _ in
            let handle = FakeNativeAudioHandle(); handles.append(handle); return handle
        }, interruptionSource: source, sleep: { try await clock.sleep($0) })
        var events: [NativeTTSPlaybackEvent] = []
        player.eventHandler = { events.append($0) }

        let timedOut = UUID()
        try player.play(wav: Data("timeout synthetic wav".utf8), tag: timedOut)
        await waitUntil { events.contains(.failed(timedOut)) }
        handles[0].finish(true)
        XCTAssertEqual(events.filter { $0 == .failed(timedOut) }.count, 1)

        let fresh = UUID()
        try player.play(wav: Data("fresh synthetic wav".utf8), tag: fresh)
        handles[1].finish(true)
        await Task.yield()
        XCTAssertEqual(Array(events.suffix(2)), [.started(fresh), .finished(fresh)])
    }

    func testConcreteSourceDefaultBindsWorkspaceCenterWithoutPostingSystemEvents() {
        let source = SystemNativeAudioInterruptionSource(hardware: FakeNativeAudioHardware())
        XCTAssertTrue(source.workspaceCenter === NSWorkspace.shared.notificationCenter)
        XCTAssertFalse(source.workspaceCenter === NotificationCenter.default)
    }

    func testConcreteSourceSleepForwardingAndRemovalUseTheOwnedWorkspaceCenter() {
        let workspace = NotificationCenter(), other = NotificationCenter(), object = NSObject()
        let hardware = FakeNativeAudioHardware()
        let source = SystemNativeAudioInterruptionSource(workspaceCenter: workspace,
            workspaceObject: object, hardware: hardware)
        var calls = 0
        source.install { calls += 1 }
        other.post(name: NSWorkspace.willSleepNotification, object: object)
        XCTAssertEqual(calls, 0)
        workspace.post(name: NSWorkspace.willSleepNotification, object: NSObject())
        XCTAssertEqual(calls, 0)
        workspace.post(name: NSWorkspace.willSleepNotification, object: object)
        XCTAssertEqual(calls, 1)
        let oldDefault = hardware.registrations[0].callback
        source.uninstall()
        source.uninstall()
        workspace.post(name: NSWorkspace.willSleepNotification, object: object)
        oldDefault()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(hardware.registrations.allSatisfy(\.removed))
        source.install { calls += 10 }
        oldDefault()
        XCTAssertEqual(calls, 1, "queued callbacks from a previous install cannot forward")
        workspace.post(name: NSWorkspace.willSleepNotification, object: object)
        XCTAssertEqual(calls, 11)
        source.uninstall()
        XCTAssertTrue(hardware.registrations.allSatisfy(\.removed))
    }

    func testConcreteCoreAudioBindingsRetargetAndRejectRemovedDeviceCallbacks() {
        let hardware = FakeNativeAudioHardware()
        let source = SystemNativeAudioInterruptionSource(workspaceCenter: NotificationCenter(),
            workspaceObject: NSObject(), hardware: hardware)
        var calls = 0
        source.install { calls += 1 }
        XCTAssertEqual(hardware.registrations.count, 2)
        let output = hardware.registrations[0], oldDevice = hardware.registrations[1]
        XCTAssertEqual(output.object, AudioObjectID(kAudioObjectSystemObject))
        XCTAssertEqual(output.selector, kAudioHardwarePropertyDefaultOutputDevice)
        XCTAssertEqual(oldDevice.object, 41)
        XCTAssertEqual(oldDevice.selector, kAudioDevicePropertyDeviceIsAlive)
        hardware.defaultOutputDevice = 42
        output.callback()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(oldDevice.removed)
        let replacement = hardware.registrations[2]
        XCTAssertEqual(replacement.object, 42)
        XCTAssertEqual(replacement.selector, kAudioDevicePropertyDeviceIsAlive)
        oldDevice.callback()
        XCTAssertEqual(calls, 1, "removed-device callbacks must not interrupt the new route")
        replacement.callback()
        XCTAssertEqual(calls, 2)
        source.uninstall()
        output.callback(); replacement.callback()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(hardware.registrations.allSatisfy(\.removed))
    }

    func testConcreteSystemSourceTerminatesActualPlayerOnceAndRecovers() async throws {
        let workspace = NotificationCenter(), object = NSObject(), hardware = FakeNativeAudioHardware()
        let source = SystemNativeAudioInterruptionSource(workspaceCenter: workspace,
            workspaceObject: object, hardware: hardware)
        var handles: [FakeNativeAudioHandle] = []
        let player = AVNativeTTSPlayer(makeHandle: { _ in
            let handle = FakeNativeAudioHandle(); handles.append(handle); return handle
        }, interruptionSource: source)
        var events: [NativeTTSPlaybackEvent] = []
        player.eventHandler = { events.append($0) }
        let first = UUID(), second = UUID(), third = UUID()
        try player.play(wav: Data("public synthetic bytes".utf8), tag: first)
        let oldFinish = handles[0].completion
        workspace.post(name: NSWorkspace.willSleepNotification, object: object)
        hardware.registrations[1].callback()
        XCTAssertEqual(events, [.started(first), .interrupted(first)])
        XCTAssertTrue(handles[0].stopped)
        try player.play(wav: Data("public synthetic bytes".utf8), tag: second)
        oldFinish?(true)
        await Task.yield()
        hardware.registrations[1].callback()
        XCTAssertEqual(Array(events.suffix(2)), [.started(second), .interrupted(second)])
        XCTAssertTrue(handles[1].stopped)
        try player.play(wav: Data("public synthetic bytes".utf8), tag: third)
        handles[2].finish(true)
        await Task.yield()
        XCTAssertEqual(Array(events.suffix(2)), [.started(third), .finished(third)])
        source.uninstall()
        XCTAssertTrue(hardware.registrations.allSatisfy(\.removed))
    }
}
