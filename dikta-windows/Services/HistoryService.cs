using System.IO;
using System.Text.Json;
using DiktaWindows.Models;

namespace DiktaWindows.Services;

public class HistoryService
{
    private const int MaxEntries = 50;
    private List<HistoryItem> _items = new();

    public IReadOnlyList<HistoryItem> Items => _items.AsReadOnly();

    public HistoryService()
    {
        Load();
    }

    public void Add(string text, string language)
    {
        _items.Insert(0, new HistoryItem
        {
            Text = text,
            Timestamp = DateTime.UtcNow,
            Language = language
        });

        if (_items.Count > MaxEntries)
            _items = _items.Take(MaxEntries).ToList();

        Save();
    }

    private void Load()
    {
        if (!File.Exists(ConfigService.HistoryPath)) return;

        var json = File.ReadAllText(ConfigService.HistoryPath);
        _items = JsonSerializer.Deserialize<List<HistoryItem>>(json) ?? new();
    }

    private void Save()
    {
        var json = JsonSerializer.Serialize(_items, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(ConfigService.HistoryPath, json);
    }
}
