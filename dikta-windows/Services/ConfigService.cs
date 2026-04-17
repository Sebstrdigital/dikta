using System.IO;
using System.Text.Json;
using DiktaWindows.Models;

namespace DiktaWindows.Services;

public class ConfigService
{
    private static readonly string AppDataDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Dikta");

    private static readonly string ConfigPath = Path.Combine(AppDataDir, "config.json");

    public AppConfig Config { get; private set; } = new();
    public bool WasReset { get; private set; }

    // Raised when Save fails (disk-full, permission-denied, etc.).
    // Subscribers receive the causal exception; the previous config file is preserved.
    public event Action<Exception>? SaveFailed;

    public ConfigService()
    {
        Directory.CreateDirectory(AppDataDir);
        Load();
    }

    public void Load()
    {
        if (!File.Exists(ConfigPath)) return;

        try
        {
            var json = File.ReadAllText(ConfigPath);
            Config = JsonSerializer.Deserialize<AppConfig>(json) ?? new AppConfig();
        }
        catch
        {
            Config = new AppConfig();
            WasReset = true;
        }
    }

    /// <summary>
    /// Atomically persists Config to disk.
    ///
    /// Strategy:
    ///   1. Serialize JSON to a sibling .tmp file.
    ///   2. If the destination already exists, use File.Replace for an atomic swap
    ///      (NTFS rename; destination backup is discarded).
    ///   3. If the destination does not yet exist (first-ever save), use File.Move.
    ///   4. On any IOException, fire SaveFailed and return — the previous valid
    ///      config.json is never touched.
    /// </summary>
    public void Save()
    {
        var tmpPath = ConfigPath + ".tmp";
        try
        {
            var json = JsonSerializer.Serialize(Config, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(tmpPath, json);

            if (File.Exists(ConfigPath))
            {
                // Atomic replace: swap tmp → config.json; no backup file kept.
                File.Replace(tmpPath, ConfigPath, destinationBackupFileName: null, ignoreMetadataErrors: true);
            }
            else
            {
                // First-ever save: destination does not exist yet, plain move is safe.
                File.Move(tmpPath, ConfigPath);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Clean up the tmp file if it was written but the replace/move failed.
            try { File.Delete(tmpPath); } catch { /* best-effort */ }

            SaveFailed?.Invoke(ex);
        }
    }

    public static string ModelsDir => Path.Combine(AppDataDir, "models");
    public static string HistoryPath => Path.Combine(AppDataDir, "history.json");
}
