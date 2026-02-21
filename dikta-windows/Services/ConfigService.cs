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

    public ConfigService()
    {
        Directory.CreateDirectory(AppDataDir);
        Load();
    }

    public void Load()
    {
        if (!File.Exists(ConfigPath)) return;

        var json = File.ReadAllText(ConfigPath);
        Config = JsonSerializer.Deserialize<AppConfig>(json) ?? new AppConfig();
    }

    public void Save()
    {
        var json = JsonSerializer.Serialize(Config, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(ConfigPath, json);
    }

    public static string ModelsDir => Path.Combine(AppDataDir, "models");
    public static string HistoryPath => Path.Combine(AppDataDir, "history.json");
}
