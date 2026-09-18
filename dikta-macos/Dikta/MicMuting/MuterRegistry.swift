/// Seam over `MuterRegistry` so `MenuBarViewModel` can inject a fake in tests
/// that asserts whether/how often `muteAll()` was called, without touching
/// real mic-muting apps.
protocol MuterRegistering {
    func muteAll() -> [MuteToken]
    func unmuteAll(_ tokens: [MuteToken])
}

final class MuterRegistry: MuterRegistering {
    private let muters: [any MicMuter]

    init(muters: [any MicMuter] = [
        GoogleMeetMuter(),
        TeamsMuter(),
        SlackMuter(),
        WhatsAppMuter(),
        UvenMuter(),
    ]) {
        self.muters = muters
    }

    var registeredMuterIDs: [String] {
        muters.map(\.muterID)
    }

    func muteAll() -> [MuteToken] {
        muters.compactMap { muter in
            muter.mute()
        }
    }

    func unmuteAll(_ tokens: [MuteToken]) {
        for token in tokens {
            guard let muter = muters.first(where: { $0.muterID == token.muterID }) else {
                continue
            }
            muter.unmute(token)
        }
    }
}
