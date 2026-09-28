import Foundation

/// What the join driver looks for in a platform's pre-join page.
struct ShadowSelectors: Equatable, Codable {
    /// CSS selectors for the guest name field, first match wins.
    var nameFieldCSS: [String]
    /// Lowercased substrings matched against button text for the ask-to-join control.
    var joinButtonTexts: [String]
    /// Text shown while waiting in the lobby.
    var lobbyTexts: [String]
    /// CSS selectors that only exist once we are inside the call.
    var admittedCSS: [String]
    /// Text shown when the host refused us.
    var deniedTexts: [String]
    /// Buttons that dismiss the "allow mic and camera?" prompt without allowing.
    var dismissMediaTexts: [String]
    /// CSS selectors for one participant tile each, in-call.
    var participantCSS: [String]
    /// CSS selectors, relative to a tile, for the element holding the participant's name.
    /// Falls back to the tile's own text when none match.
    var participantNameCSS: [String]
    /// CSS selector that marks a tile as the active speaker: the tile itself or a descendant matches.
    var activeSpeakerCSS: [String]
}

enum MeetingPlatform: String, Equatable {
    case meet, teams, zoom
}

/// One row of the platform table: how to recognise a URL, how to rewrite it into the
/// browser-joinable form, and the DOM selectors (nil while still a placeholder).
struct ShadowPlatformProfile {
    let platform: MeetingPlatform
    let matches: (URL) -> Bool
    let rewrite: (URL) -> URL
    let selectors: ShadowSelectors?
}

enum ShadowPlatform {
    static let meetSelectors = ShadowSelectors(
        nameFieldCSS: ["input[aria-label=\"Your name\" i]", "input[placeholder=\"Your name\" i]"],
        joinButtonTexts: ["ask to join", "join now"],
        lobbyTexts: ["asking to be let in", "someone will let you in soon"],
        admittedCSS: ["button[aria-label*=\"Leave call\" i]"],
        deniedTexts: ["you can't join this video call", "denied your request"],
        dismissMediaTexts: ["continue without microphone and camera"],
        participantCSS: ["[data-participant-id]"],
        participantNameCSS: ["[data-self-name]"],
        activeSpeakerCSS: ["[data-speaking=\"true\"]"]
    )

    /// The single platform table. Only Meet has selectors; Teams and Zoom are placeholders.
    static let table: [ShadowPlatformProfile] = [
        ShadowPlatformProfile(
            platform: .meet,
            matches: { $0.host?.lowercased() == "meet.google.com" },
            rewrite: { $0 },
            selectors: meetSelectors),
        ShadowPlatformProfile(
            platform: .teams,
            matches: { ["teams.microsoft.com", "teams.live.com"].contains($0.host?.lowercased() ?? "") },
            rewrite: { $0 },
            selectors: nil),
        ShadowPlatformProfile(
            platform: .zoom,
            matches: { url in
                guard let host = url.host?.lowercased() else { return false }
                return host == "zoom.us" || host.hasSuffix(".zoom.us")
            },
            rewrite: zoomWebClientURL,
            selectors: nil),
    ]

    static func profile(for url: URL, in table: [ShadowPlatformProfile] = table) -> ShadowPlatformProfile? {
        table.first { $0.matches(url) }
    }

    /// `https://x.zoom.us/j/123?pwd=a` becomes `https://x.zoom.us/wc/join/123?pwd=a`.
    static func zoomWebClientURL(_ url: URL) -> URL {
        guard url.path.hasPrefix("/j/"),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.path = "/wc/join/" + url.path.dropFirst(3)
        return comps.url ?? url
    }
}
