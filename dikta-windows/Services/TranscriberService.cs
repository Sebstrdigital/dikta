using System.IO;
using System.Text.RegularExpressions;
using DiktaWindows.Models;
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

        try
        {
            using var factory = WhisperFactory.FromPath(modelPath);

            var language = Language.FromCode(_configService.Config.Language).WhisperCode;

            using var processor = factory.CreateBuilder()
                .WithLanguage(language)
                .Build();

            using var fileStream = File.OpenRead(audioFilePath);

            var result = new List<string>();
            await foreach (var segment in processor.ProcessAsync(fileStream))
            {
                var text = segment.Text.Trim();
                // Strip bracket noise tokens like [BLANK_AUDIO], [Music], etc.
                text = Regex.Replace(text, @"\[[^\]]+\]", "").Trim();
                if (!string.IsNullOrEmpty(text))
                    result.Add(text);
            }

            return result.Count > 0 ? string.Join(" ", result) : string.Empty;
        }
        finally
        {
            try
            {
                if (File.Exists(audioFilePath))
                    File.Delete(audioFilePath);
            }
            catch
            {
                // Best-effort cleanup of temp file
            }
        }
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
