import Foundation
import Carbon.HIToolbox

/// Modifier keys for hotkey combinations
enum ModifierKey: String, Codable, CaseIterable {
    case shift
    case ctrl
    case cmd
    case alt
    case fn

    /// Display symbol for the modifier
    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .ctrl: return "⌃"
        case .cmd: return "⌘"
        case .alt: return "⌥"
        case .fn: return "fn"
        }
    }

    /// CGEventFlags for this modifier
    var cgEventFlag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .ctrl: return .maskControl
        case .cmd: return .maskCommand
        case .alt: return .maskAlternate
        case .fn: return .maskSecondaryFn
        }
    }
}

/// Hotkey mode (toggle vs push-to-talk vs text-to-speech)
enum HotkeyMode: String, Codable, CaseIterable {
    case toggle = "toggle"
    case pushToTalk = "push_to_talk"
    case textToSpeech = "text_to_speech"
    case languageToggle = "language_toggle"
    case formatSelection = "format_selection"
    
    var displayName: String {
        switch self {
        case .toggle: return "Record"
        case .pushToTalk: return "Push-to-Talk"
        case .textToSpeech: return "Read Aloud"
        case .languageToggle: return "Switch Language"
        case .formatSelection: return "Format Selection"
        }
    }

    var description: String {
        switch self {
        case .toggle: return "Press to start, press again to stop"
        case .pushToTalk: return "Hold to record, release to stop"
        case .textToSpeech: return "Read selected text aloud"
        case .languageToggle: return "Cycle through languages"
        case .formatSelection: return "Format selected text"
        }
    }
}

/// Configuration for a hotkey combination
struct HotkeyConfig: Codable, Equatable, Hashable {
    var modifiers: [ModifierKey]
    var key: String?

    /// Order-independent equality: [.shift, .ctrl] == [.ctrl, .shift]
    static func == (lhs: HotkeyConfig, rhs: HotkeyConfig) -> Bool {
        Set(lhs.modifiers) == Set(rhs.modifiers) && lhs.key == rhs.key
    }

    /// Hash consistent with order-independent Equatable: hash modifiers as a Set
    /// so that configs with the same modifiers in different orders produce the same hash.
    func hash(into hasher: inout Hasher) {
        hasher.combine(Set(modifiers))
        hasher.combine(key)
    }

    /// Format hotkey for display (e.g., "⇧⌃" or "⌘⇧A")
    var displayString: String {
        var parts = modifiers.map { $0.symbol }
        if let key = key {
            parts.append(key.uppercased())
        }
        return parts.joined()
    }

    /// Check if the given event flags match this hotkey's modifiers
    func matchesModifiers(_ flags: CGEventFlags) -> Bool {
        for modifier in ModifierKey.allCases {
            let isRequired = modifiers.contains(modifier)
            let isPressed = flags.contains(modifier.cgEventFlag)
            if isRequired != isPressed {
                return false
            }
        }
        return true
    }

    /// Default toggle hotkey: Shift+Ctrl
    static let defaultToggle = HotkeyConfig(modifiers: [.shift, .ctrl], key: nil)

    /// Default push-to-talk hotkey: Cmd+Shift
    static let defaultPushToTalk = HotkeyConfig(modifiers: [.cmd, .shift], key: nil)

    /// Default text-to-speech hotkey: Cmd+Alt
    static let defaultTextToSpeech = HotkeyConfig(modifiers: [.cmd, .alt], key: nil)

    /// Default language toggle hotkey: Cmd+Ctrl
    static let defaultLanguageToggle = HotkeyConfig(modifiers: [.cmd, .ctrl], key: nil)

    /// Default format selection hotkey: Cmd+Shift+F
    static let defaultFormatSelection = HotkeyConfig(modifiers: [.cmd, .shift], key: "f")
}
