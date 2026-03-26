import Foundation

/// Supported languages for dictation
enum Language: String, Codable, CaseIterable {
    case english = "en"
    case swedish = "sv"
    case indonesian = "id"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt"
    case italian = "it"
    case dutch = "nl"
    case finnish = "fi"
    case norwegian = "no"
    case danish = "da"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .swedish: return "Svenska"
        case .indonesian: return "Bahasa Indonesia"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .portuguese: return "Português"
        case .italian: return "Italiano"
        case .dutch: return "Nederlands"
        case .finnish: return "Suomi"
        case .norwegian: return "Norsk"
        case .danish: return "Dansk"
        }
    }

    /// Short code for menu bar display
    var menuBarCode: String {
        rawValue.uppercased()
    }

    /// Whisper language code
    var whisperCode: String {
        rawValue
    }

    /// Next language in the cycle (all languages)
    var next: Language {
        let all = Language.allCases
        let index = all.firstIndex(of: self)!
        return all[(index + 1) % all.count]
    }

    /// Next language in the cycle, restricted to the given enabled set.
    /// If the current language is not in the enabled set, returns the first enabled language.
    /// Falls back to self if the enabled set is empty.
    func next(in enabledLanguages: [Language]) -> Language {
        guard !enabledLanguages.isEmpty else { return self }
        guard let currentIndex = enabledLanguages.firstIndex(of: self) else {
            return enabledLanguages[0]
        }
        return enabledLanguages[(currentIndex + 1) % enabledLanguages.count]
    }
}
