namespace DiktaWindows.Models;

/// <summary>Supported languages for dictation — mirrors the macOS Language enum.</summary>
public sealed class Language
{
    public static readonly Language English    = new("en", "English",          "EN");
    public static readonly Language Swedish    = new("sv", "Svenska",          "SV");
    public static readonly Language Indonesian = new("id", "Bahasa Indonesia", "ID");
    public static readonly Language Spanish    = new("es", "Español",          "ES");
    public static readonly Language French     = new("fr", "Français",         "FR");
    public static readonly Language German     = new("de", "Deutsch",          "DE");
    public static readonly Language Portuguese = new("pt", "Português",        "PT");
    public static readonly Language Italian    = new("it", "Italiano",         "IT");
    public static readonly Language Dutch      = new("nl", "Nederlands",       "NL");
    public static readonly Language Finnish    = new("fi", "Suomi",            "FI");
    public static readonly Language Norwegian  = new("no", "Norsk",            "NO");
    public static readonly Language Danish     = new("da", "Dansk",            "DA");

    public static readonly IReadOnlyList<Language> All = new[]
    {
        English, Swedish, Indonesian, Spanish, French, German,
        Portuguese, Italian, Dutch, Finnish, Norwegian, Danish
    };

    /// <summary>Whisper language code passed to Whisper.net (e.g. "en", "sv").</summary>
    public string WhisperCode { get; }

    /// <summary>Native display name shown in the UI (e.g. "Svenska", "Français").</summary>
    public string DisplayName { get; }

    /// <summary>Short uppercase code for tray / menu bar display (e.g. "EN", "SV").</summary>
    public string MenuBarCode { get; }

    private Language(string whisperCode, string displayName, string menuBarCode)
    {
        WhisperCode = whisperCode;
        DisplayName = displayName;
        MenuBarCode = menuBarCode;
    }

    /// <summary>
    /// Returns the Language matching <paramref name="code"/>, or <see cref="English"/> if unknown.
    /// </summary>
    public static Language FromCode(string code) =>
        All.FirstOrDefault(l => l.WhisperCode == code) ?? English;
}
