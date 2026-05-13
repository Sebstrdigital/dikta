import XCTest
@testable import Dikta

final class MicMutingTests: XCTestCase {
    func testDefaultRegistryContainsAllMutersInOrder() {
        let registry = MuterRegistry()

        XCTAssertEqual(registry.registeredMuterIDs, [
            "GoogleMeetMuter",
            "TeamsMuter",
            "SlackMuter",
            "WhatsAppMuter",
            "UvenMuter",
        ])
    }

    func testTeamsMuterReturnsNilWhenTeamsNotRunning() {
        XCTAssertNil(TeamsMuter().mute())
    }

    func testSlackMuterReturnsNilWhenSlackNotRunning() {
        XCTAssertNil(SlackMuter().mute())
    }

    func testWhatsAppMuterReturnsNilWhenWhatsAppNotRunning() {
        XCTAssertNil(WhatsAppMuter().mute())
    }

    func testUvenMuterReturnsNilWhenUvenNotRunning() {
        XCTAssertNil(UvenMuter().mute())
    }

    func testMuteAllCallsEachMuterOnceAndCollectsTokens() {
        let log = EventLog()
        let firstToken = MuteToken(muterID: "first")
        let thirdToken = MuteToken(muterID: "third")

        let first = FakeMuter(id: "first", token: firstToken, log: log)
        let second = FakeMuter(id: "second", token: nil, log: log)
        let third = FakeMuter(id: "third", token: thirdToken, log: log)

        let registry = MuterRegistry(muters: [first, second, third])
        let tokens = registry.muteAll()

        XCTAssertEqual(tokens, [firstToken, thirdToken])
        XCTAssertEqual(log.events, ["mute-first", "mute-second", "mute-third"])
        XCTAssertEqual(first.muteCalls, 1)
        XCTAssertEqual(second.muteCalls, 1)
        XCTAssertEqual(third.muteCalls, 1)
    }

    func testUnmuteAllCallsUnmuteForEachToken() {
        let log = EventLog()
        let firstToken = MuteToken(muterID: "first")
        let thirdToken = MuteToken(muterID: "third")

        let first = FakeMuter(id: "first", token: firstToken, log: log)
        let second = FakeMuter(id: "second", token: nil, log: log)
        let third = FakeMuter(id: "third", token: thirdToken, log: log)

        let registry = MuterRegistry(muters: [first, second, third])
        registry.unmuteAll([thirdToken, firstToken])

        XCTAssertEqual(log.events, ["unmute-third", "unmute-first"])
        XCTAssertEqual(first.unmuteCalls, 1)
        XCTAssertEqual(second.unmuteCalls, 0)
        XCTAssertEqual(third.unmuteCalls, 1)
        XCTAssertEqual(first.receivedUnmuteTokens, [firstToken])
        XCTAssertEqual(third.receivedUnmuteTokens, [thirdToken])
    }

    func testMuteAndUnmuteAreRepeatable() {
        let log = EventLog()
        let firstToken = MuteToken(muterID: "first")
        let secondToken = MuteToken(muterID: "second")

        let first = FakeMuter(id: "first", token: firstToken, log: log)
        let second = FakeMuter(id: "second", token: secondToken, log: log)
        let registry = MuterRegistry(muters: [first, second])

        let firstCycle = registry.muteAll()
        registry.unmuteAll(firstCycle)
        let secondCycle = registry.muteAll()
        registry.unmuteAll(secondCycle)

        XCTAssertEqual(firstCycle, [firstToken, secondToken])
        XCTAssertEqual(secondCycle, [firstToken, secondToken])
        XCTAssertEqual(log.events, [
            "mute-first", "mute-second",
            "unmute-first", "unmute-second",
            "mute-first", "mute-second",
            "unmute-first", "unmute-second",
        ])
        XCTAssertEqual(first.muteCalls, 2)
        XCTAssertEqual(second.muteCalls, 2)
        XCTAssertEqual(first.unmuteCalls, 2)
        XCTAssertEqual(second.unmuteCalls, 2)
    }
}

private final class FakeMuter: MicMuter {
    let id: String
    let tokenToReturn: MuteToken?
    let log: EventLog

    private(set) var muteCalls = 0
    private(set) var unmuteCalls = 0
    private(set) var receivedUnmuteTokens: [MuteToken] = []

    init(id: String, token: MuteToken?, log: EventLog) {
        self.id = id
        self.tokenToReturn = token
        self.log = log
    }

    var muterID: String { id }

    func mute() -> MuteToken? {
        muteCalls += 1
        log.events.append("mute-\(id)")
        return tokenToReturn
    }

    func unmute(_ token: MuteToken) {
        unmuteCalls += 1
        receivedUnmuteTokens.append(token)
        log.events.append("unmute-\(id)")
    }
}

private final class EventLog {
    var events: [String] = []
}
