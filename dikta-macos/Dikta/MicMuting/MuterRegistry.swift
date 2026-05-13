final class MuterRegistry {
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
