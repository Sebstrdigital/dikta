import Foundation

struct MuteToken: Equatable {
    let muterID: String
    let previousFrontmostBundleID: String?
    let browserBundleID: String?
    let browserWindowTitle: String?
    let meetingLocator: String?

    init(
        muterID: String = "",
        previousFrontmostBundleID: String? = nil,
        browserBundleID: String? = nil,
        browserWindowTitle: String? = nil,
        meetingLocator: String? = nil
    ) {
        self.muterID = muterID
        self.previousFrontmostBundleID = previousFrontmostBundleID
        self.browserBundleID = browserBundleID
        self.browserWindowTitle = browserWindowTitle
        self.meetingLocator = meetingLocator
    }
}

protocol MicMuter {
    var muterID: String { get }

    func mute() -> MuteToken?
    func unmute(_ token: MuteToken)
}

extension MicMuter {
    var muterID: String { String(describing: type(of: self)) }
}
