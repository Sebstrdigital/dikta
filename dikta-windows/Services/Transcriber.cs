using System.IO;
using Whisper.net;

namespace DiktaWindows.Services;

public class TranscriberService
{
    private readonly ConfigService _configService;

    public TranscriberService(ConfigService configService)
    {
        _configService = configService;
    }

    public async Task<string> TranscribeAsync(string audioFilePath)
    {
        var modelPath = GetModelPath();

        if (!File.Exists(modelPath))
            throw new FileNotFoundException($"Whisper model not found at {modelPath}. Please download the model first.");

        using var factory = WhisperFactory.FromPath(modelPath);

        var language = _configService.Config.Language == "sv" ? "sv" : "en";

        using var processor = factory.CreateBuilder()
            .WithLanguage(language)
            .Build();

        var result = new List<string>();

        await foreach (var segment in processor.ProcessAsync(audioFilePath))
        {
            result.Add(segment.Text.Trim());
        }

        // Clean up temp file
        if (File.Exists(audioFilePath))
            File.Delete(audioFilePath);

        return string.Join(" ", result);
    }

    private string GetModelPath()
    {
        var model = _configService.Config.WhisperModel;
        return Path.Combine(ConfigService.ModelsDir, $"ggml-{model}.bin");
    }

    public bool IsModelAvailable()
    {
        return File.Exists(GetModelPath());
    }
}
