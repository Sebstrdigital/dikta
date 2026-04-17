using System;
using System.IO;
using System.Text.Json;
using DiktaWindows.Models;

namespace DiktaWindows.Services;

public class HistoryService
{
    private const int MaxEntries = 50;
    private readonly object _lock = new();
    private List<HistoryItem> _items = new();

    public IReadOnlyList<HistoryItem> Items
    {
        get
        {
            lock (_lock)
            {
                return _items.ToList().AsReadOnly();
            }
        }
    }

    public HistoryService()
    {
        Load();
    }

    public void Add(string text, string language)
    {
        lock (_lock)
        {
            _items.Insert(0, new HistoryItem
            {
                Text = text,
                Timestamp = DateTime.UtcNow,
                Language = language
            });

            if (_items.Count > MaxEntries)
                _items = _items.Take(MaxEntries).ToList();
        }

        Save();
    }

    private void Load()
    {
        if (!File.Exists(ConfigService.HistoryPath)) return;

        try
        {
            var json = File.ReadAllText(ConfigService.HistoryPath);
            _items = JsonSerializer.Deserialize<List<HistoryItem>>(json) ?? new();
        }
        catch (JsonException)
        {
            _items = new();
        }
        catch (FileNotFoundException)
        {
            _items = new();
        }
        catch (UnauthorizedAccessException)
        {
            _items = new();
        }
    }

    private void Save()
    {
        lock (_lock)
        {
            try
            {
                var json = JsonSerializer.Serialize(_items.ToList(), new JsonSerializerOptions { WriteIndented = true });
                var tmpPath = ConfigService.HistoryPath + ".tmp";
                File.WriteAllText(tmpPath, json);
                File.Move(tmpPath, ConfigService.HistoryPath, overwrite: true);
            }
            catch (IOException ex)
            {
                DiagnosticLogger.Warning($"HistoryService.Save failed. Path={ConfigService.HistoryPath}, Exception={ex.GetType().Name}: {ex.Message}");
                // Clean up any lingering .tmp file (best-effort)
                try
                {
                    var tmpPath = ConfigService.HistoryPath + ".tmp";
                    if (File.Exists(tmpPath))
                        File.Delete(tmpPath);
                }
                catch { /* best-effort cleanup */ }
                // Do NOT rethrow — transcription succeeded; history persistence failure should not surface as user error
            }
            catch (UnauthorizedAccessException ex)
            {
                DiagnosticLogger.Warning($"HistoryService.Save failed. Path={ConfigService.HistoryPath}, Exception={ex.GetType().Name}: {ex.Message}");
                // Clean up any lingering .tmp file (best-effort)
                try
                {
                    var tmpPath = ConfigService.HistoryPath + ".tmp";
                    if (File.Exists(tmpPath))
                        File.Delete(tmpPath);
                }
                catch { /* best-effort cleanup */ }
                // Do NOT rethrow — transcription succeeded; history persistence failure should not surface as user error
            }
            catch (JsonException ex)
            {
                DiagnosticLogger.Warning($"HistoryService.Save failed. Path={ConfigService.HistoryPath}, Exception={ex.GetType().Name}: {ex.Message}");
                // Clean up any lingering .tmp file (best-effort)
                try
                {
                    var tmpPath = ConfigService.HistoryPath + ".tmp";
                    if (File.Exists(tmpPath))
                        File.Delete(tmpPath);
                }
                catch { /* best-effort cleanup */ }
                // Do NOT rethrow — transcription succeeded; history persistence failure should not surface as user error
            }
        }
    }
}
