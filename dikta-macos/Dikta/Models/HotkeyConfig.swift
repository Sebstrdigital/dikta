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
enum HotkeyMode: String, Codable {
    case toggle = "toggle"
    case pushToTalk = "push_to_talk"
    case textToSpeech = "text_to_speech"

    var displayName: String {
        switch self {
        case .toggle: return "Toggle Mode"
        case .pushToTalk: return "Push-to-Talk Mode"
        case .textToSpeech: return "Text-to-Speech"
        }
    }
}

/// Configuration for a hotkey combination
struct HotkeyConfig: Codable, Equatable {
    var modifiers: [ModifierKey]
    var key: String?

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
}
