using System.Text.Json.Serialization;

namespace DiktaWindows.Models;

public class HistoryItem
{
    [JsonPropertyName("text")]
    public string Text { get; set; } = "";

    [JsonPropertyName("timestamp")]
    public DateTime Timestamp { get; set; } = DateTime.UtcNow;

    [JsonPropertyName("language")]
    public string Language { get; set; } = "en";
}
