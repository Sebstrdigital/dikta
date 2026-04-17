using System.IO;
using System.Text.RegularExpressions;
using DiktaWindows.Models;
using Whisper.net;

namespace DiktaWindows.Services;

public class TranscriberService : IDisposable
{
    private readonly ConfigService _configService;

    // Cached factory — reused across transcriptions when the model path is unchanged.
    private WhisperFactory? _factory;
    private string? _cachedModelPath;

    public TranscriberService(ConfigService configService)
    {
        _configService = configService;
    }

    public async Task<string> TranscribeAsync(string audioFilePath)
    {
        var modelPath = GetModelPath();

        if (!File.Exists(modelPath))
            throw new FileNotFoundException($"Whisper model not found at {modelPath}. Please download the model first.");

        // Invalidate cached factory if the model path has changed (e.g. user switched model in Settings).
        if (_factory != null && _cachedModelPath != modelPath)
        {
            _factory.Dispose();
            _factory = null;
            _cachedModelPath = null;
        }

        // Load from disk only on first transcription or after a model-path change.
        if (_factory == null)
        {
            _factory = WhisperFactory.FromPath(modelPath);
            _cachedModelPath = modelPath;
        }

        var sw = System.Diagnostics.Stopwatch.StartNew();
        long audioSize = File.Exists(audioFilePath) ? new FileInfo(audioFilePath).Length : 0;

        try
        {
            var language = Language.FromCode(_configService.Config.Language).WhisperCode;
            var noSpeechThreshold = _configService.Config.Sensitivity.NoSpeechThreshold();

            // Build a fresh processor each call so language/sensitivity settings are applied.
            using var processor = _factory.CreateBuilder()
                .WithLanguage(language)
                .WithNoSpeechThreshold(noSpeechThreshold)
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

            sw.Stop();
            DiagnosticLogger.Info($"Transcription complete. Lang={language}, AudioBytes={audioSize}, DurationMs={sw.ElapsedMilliseconds}, OutputChars={(result.Count > 0 ? string.Join(" ", result).Length : 0)}");

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

    public void Dispose()
    {
        _factory?.Dispose();
        _factory = null;
        _cachedModelPath = null;
    }
}
