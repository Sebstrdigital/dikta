using System.Text.Json.Serialization;

namespace DiktaWindows.Models;

public class AppConfig
{
    [JsonPropertyName("hotkey_modifiers")]
    public string HotkeyModifiers { get; set; } = "Ctrl+Shift";

    [JsonPropertyName("hotkey_key")]
    public string HotkeyKey { get; set; } = "D";

    [JsonPropertyName("language")]
    public string Language { get; set; } = "en";

    [JsonPropertyName("whisper_model")]
    public string WhisperModel { get; set; } = "small";

    [JsonPropertyName("mute_sounds")]
    public bool MuteSounds { get; set; } = false;
}
