import XCTest
@testable import Dikta

@MainActor
final class ShadowHostTests: XCTestCase {

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/meet-join.html")

    /// The fixture is a file URL; a Meet-selector row that matches it stands in for meet.google.com.
    private static let fixtureProfiles = [
        ShadowPlatformProfile(platform: .meet, matches: { $0.isFileURL }, rewrite: { $0 },
                              selectors: ShadowPlatform.meetSelectors)
    ]
    private static let fastDriver = ShadowJoinDriver(
        evaluate: { _ in "" }, pollInterval: .milliseconds(50),
        controlsTimeout: .seconds(20), admissionTimeout: .seconds(20))

    /// Collects state events until a terminal one (admitted / failed) or the timeout.
    private func collectStates(from host: ShadowHost, timeout: TimeInterval = 40) async -> [ShadowJoinState] {
        let collector = Task { () -> [ShadowJoinState] in
            var states: [ShadowJoinState] = []
            for await event in host.events {
                guard case .state(let s) = event else { continue }
                states.append(s)
                switch s {
                case .admitted, .failed: return states
                default: break
                }
            }
            return states
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            collector.cancel()
        }
        let states = await collector.value
        timer.cancel()
        return states
    }

    // MARK: - Platform table

    func testPlatformDetection() {
        func platform(_ s: String) -> MeetingPlatform? { ShadowPlatform.profile(for: URL(string: s)!)?.platform }
        XCTAssertEqual(platform("https://meet.google.com/abc-defg-hij"), .meet)
        XCTAssertEqual(platform("https://teams.microsoft.com/l/meetup-join/x"), .teams)
        XCTAssertEqual(platform("https://teams.live.com/meet/123"), .teams)
        XCTAssertEqual(platform("https://us02web.zoom.us/j/123456"), .zoom)
        XCTAssertNil(platform("https://example.com/j/123"))
        XCTAssertNil(platform("https://notzoom.us/j/1"))
    }

    func testZoomRewritesToWebClient() {
        let url = URL(string: "https://us02web.zoom.us/j/123456789?pwd=abc")!
        let profile = ShadowPlatform.profile(for: url)!
        XCTAssertEqual(profile.rewrite(url).absoluteString, "https://us02web.zoom.us/wc/join/123456789?pwd=abc")
        let already = URL(string: "https://us02web.zoom.us/wc/join/123")!
        XCTAssertEqual(profile.rewrite(already), already)
    }

    func testOnlyMeetHasSelectors() {
        for profile in ShadowPlatform.table {
            XCTAssertEqual(profile.selectors != nil, profile.platform == .meet, "\(profile.platform)")
        }
    }

    // MARK: - Fake host

    func testFakeHostDeliversEvents() async {
        let host = FakeShadowHost()
        await host.join(url: URL(string: "https://meet.google.com/x")!, displayName: "Dikta · notes (Test)")
        host.send(.state(.joining))
        host.send(.participantJoined("Odalys Brandt"))
        await host.leave()
        var seen: [ShadowEvent] = []
        for await e in host.events { seen.append(e) }
        XCTAssertEqual(seen, [.state(.joining), .participantJoined("Odalys Brandt")])
        XCTAssertEqual(host.joinedName, "Dikta · notes (Test)")
        XCTAssertEqual(host.leaveCallCount, 1)
    }

    // MARK: - WebKit process filter

    func testWebKitScanner_picksOnlyOwnedAudioHelpers() {
        let own: pid_t = 100
        let procs = [
            ShadowProcessInfo(pid: 100, path: "/Applications/Dikta.app/Contents/MacOS/Dikta", responsiblePID: 100),
            ShadowProcessInfo(pid: 101, path: "/S/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/x", responsiblePID: 100),
            ShadowProcessInfo(pid: 102, path: "/S/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc/x", responsiblePID: 100),
            ShadowProcessInfo(pid: 103, path: "/S/WebKit.framework/XPCServices/com.apple.WebKit.Networking.xpc/x", responsiblePID: 100),
            ShadowProcessInfo(pid: 200, path: "/S/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/x", responsiblePID: 999),
        ]
        XCTAssertEqual(WebKitProcessScanner.audioProcessIDs(in: procs, ownPID: own), [101, 102])
    }

    // MARK: - WKWebView host against the fixture

    func testWKWebViewHost_joinsFixture() async {
        let host = WKWebViewShadowHost(profiles: Self.fixtureProfiles, driver: Self.fastDriver, processLister: { [] })
        await host.join(url: Self.fixtureURL, displayName: "Dikta · notes (Test)")
        let states = await collectStates(from: host)
        await host.leave()
        XCTAssertEqual(states, [.joining, .waitingForAdmission, .admitted])
        XCTAssertFalse(host.audioProcessIDs.contains(getpid()))
    }

    func testWKWebViewHost_unsupportedURLFails() async {
        let host = WKWebViewShadowHost(processLister: { [] })
        await host.join(url: URL(string: "https://example.com/meeting")!, displayName: "x")
        let states = await collectStates(from: host, timeout: 5)
        await host.leave()
        XCTAssertEqual(states, [.joining, .failed(.unsupportedPlatform)])
    }

    // MARK: - Chrome host

    func testChromeHost_noBrowserFailsWithoutLaunching() async {
        let host = ChromeShadowHost(profiles: Self.fixtureProfiles, browser: { nil })
        await host.join(url: Self.fixtureURL, displayName: "x")
        let states = await collectStates(from: host, timeout: 5)
        XCTAssertEqual(states, [.joining, .failed(.noBrowser)])
        XCTAssertEqual(host.audioProcessIDs, [])
        await host.leave()
    }

    func testChromiumLocator_firstFoundWins() {
        let found = ChromiumLocator.find(candidates: ["/a", "/b", "/c"], isExecutable: { $0 != "/a" })
        XCTAssertEqual(found?.path, "/b")
        XCTAssertNil(ChromiumLocator.find(candidates: ["/a"], isExecutable: { _ in false }))
    }

    func testChromeHost_joinsFixture() async throws {
        guard ChromiumLocator.find() != nil else { throw XCTSkip("no Chromium browser installed") }
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("dikta-shadow-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: profile) }
        let host = ChromeShadowHost(profiles: Self.fixtureProfiles, profileDir: profile,
                                    extraArguments: ["--headless=new"], driver: Self.fastDriver)
        await host.join(url: Self.fixtureURL, displayName: "Dikta · notes (Test)")
        let pids = host.audioProcessIDs
        let states = await collectStates(from: host)
        await host.leave()
        XCTAssertEqual(states, [.joining, .waitingForAdmission, .admitted])
        XCTAssertEqual(pids.count, 1)
    }

    // MARK: - Speaker capture

    func testSpeakerTracker_diffsSnapshots() {
        var t = ShadowSpeakerPoller.Tracker()
        XCTAssertEqual(t.ingest(.init(participants: ["Anna", "Bo"], speaker: "Anna")),
                       [.participantJoined("Anna"), .participantJoined("Bo"), .activeSpeaker("Anna")])
        XCTAssertEqual(t.ingest(.init(participants: ["Anna", "Bo"], speaker: "Anna")), [])
        XCTAssertEqual(t.ingest(.init(participants: ["Anna"], speaker: nil)),
                       [.activeSpeaker(nil), .participantLeft("Bo")])
    }

    func testTimelineRecorder_appendsJSONLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speakers-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let rec = SpeakerTimelineRecorder(fileURL: url)
        rec.record(.participantJoined("Anna"))
        rec.record(.activeSpeaker("Anna"))
        rec.record(.pageWarning("ignored"))
        rec.record(.activeSpeaker(nil))
        // Readable before close: nothing is buffered in the process.
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        rec.close()
        XCTAssertEqual(lines.count, 3)
        let objs = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(objs.map { $0["kind"] as? String }, ["joined", "activeSpeaker", "activeSpeaker"])
        XCTAssertEqual(objs[0]["name"] as? String, "Anna")
        XCTAssertTrue(objs[2]["name"] is NSNull)
        XCTAssertNotNil(objs[0]["t"] as? Double)
    }

    /// Runs the fixture's scripted sequence and returns the recorded timeline.
    private func recordFixtureTimeline(interval: Duration) async throws -> [[String: Any]] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speakers-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let driver = ShadowJoinDriver(evaluate: { _ in "" }, pollInterval: interval,
                                      controlsTimeout: .seconds(20), admissionTimeout: .seconds(20))
        let host = WKWebViewShadowHost(profiles: Self.fixtureProfiles, driver: driver, processLister: { [] })
        let rec = SpeakerTimelineRecorder(fileURL: url)
        let consumer = Task { await rec.consume(host.events) }
        await host.join(url: Self.fixtureURL, displayName: "Dikta · notes (Test)")
        try await Task.sleep(for: .seconds(11))
        await host.leave()
        await consumer.value
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    func testWKWebViewHost_recordsScriptedSpeakerTimeline() async throws {
        let interval = 0.25
        let lines = try await recordFixtureTimeline(interval: .milliseconds(250))
        let speaker = lines.filter { $0["kind"] as? String == "activeSpeaker" }
        XCTAssertEqual(speaker.map { $0["name"] as? String }, ["Anna", "Bo", "Anna", nil])
        let t = speaker.map { $0["t"] as! Double }
        // Script: Anna at 0, Bo at 3, Anna at 5, none at 8 (relative to the first change).
        for (got, want) in zip(t, [0.0, 3.0, 5.0, 8.0]) {
            XCTAssertEqual(got - t[0], want, accuracy: interval + 0.1)
        }
        XCTAssertEqual(lines.filter { $0["kind"] as? String == "joined" }.compactMap { $0["name"] as? String }, ["Anna", "Bo"])
        XCTAssertEqual(lines.filter { $0["kind"] as? String == "left" }.compactMap { $0["name"] as? String }, ["Bo"])
    }

    func testSpeakerPoller_unrecognisedDOMWarnsOnceAndKeepsPolling() async {
        var polls = 0
        let poller = ShadowSpeakerPoller(evaluate: { _ in polls += 1; return "{\"ok\":false}" },
                                         pollInterval: .milliseconds(10))
        var events: [ShadowEvent] = []
        let task = Task { await poller.run(selectors: ShadowPlatform.meetSelectors) { events.append($0) } }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await task.value
        XCTAssertGreaterThan(polls, 3)
        XCTAssertEqual(events.count, 1)
        guard case .pageWarning(let m) = events.first else { return XCTFail("no warning") }
        XCTAssertTrue(m.hasPrefix("SHADOW_DOM"))
    }
}
