import Foundation
@testable import Dikta

/// Test double for `ShadowHost`. Tests push events with `send(_:)`.
@MainActor
final class FakeShadowHost: ShadowHost {
    let events: AsyncStream<ShadowEvent>
    private let continuation: AsyncStream<ShadowEvent>.Continuation

    var audioProcessIDs: [pid_t] = []
    private(set) var joinedURL: URL?
    private(set) var joinedName: String?
    private(set) var leaveCallCount = 0

    init() {
        var cont: AsyncStream<ShadowEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    func join(url: URL, displayName: String) async {
        joinedURL = url
        joinedName = displayName
    }

    func leave() async {
        leaveCallCount += 1
        continuation.finish()
    }

    func send(_ event: ShadowEvent) { continuation.yield(event) }
}
