using System.IO;
using System.Net.Http;
using System.Threading;

namespace DiktaWindows.Services;

public class ModelDownloader
{
    private static readonly HttpClient _httpClient = new() { Timeout = Timeout.InfiniteTimeSpan };
    private const string BaseUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

    // Expected model sizes in bytes (with 1% tolerance)
    private static readonly Dictionary<string, long> _expectedModelSizes = new()
    {
        { "small", 511_705_088 },      // 488 MB
        { "medium", 1_606_632_448 },   // 1533 MB
        { "large", 3_244_867_584 }     // 3095 MB
    };

    public static IReadOnlyDictionary<string, long> ExpectedModelSizes => _expectedModelSizes;

    public async Task DownloadModelAsync(
        string modelName,
        string destinationPath,
        IProgress<(long bytesRead, long? totalBytes)>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var url = $"{BaseUrl}ggml-{modelName}.bin";
        var tmpPath = destinationPath + ".tmp";

        Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);

        // Preserve any previous validation-failure artefact for post-mortem inspection.
        // A plain .tmp that survived means validation failed last time — rename it to
        // .tmp.failed so the developer can inspect it, then start a fresh download.
        // Only keep the most recent failure (overwrite any older .tmp.failed).
        if (File.Exists(tmpPath))
            File.Move(tmpPath, tmpPath + ".failed", overwrite: true);

        using var response = await _httpClient.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();

        var totalBytes = response.Content.Headers.ContentLength;

        using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        try
        {
            using var fileStream = new FileStream(tmpPath, FileMode.Create, FileAccess.Write, FileShare.None, bufferSize: 81920);
            var buffer = new byte[81920];
            long bytesRead = 0;
            int read;

            while ((read = await stream.ReadAsync(buffer, cancellationToken)) > 0)
            {
                await fileStream.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                bytesRead += read;
                progress?.Report((bytesRead, totalBytes));
            }
        }
        catch
        {
            // Clean up partial download on failure or cancellation
            if (File.Exists(tmpPath))
                File.Delete(tmpPath);
            throw;
        }

        // Validate file size BEFORE moving to final destination (US-002)
        // On validation failure, keep the .tmp file for debugging
        if (!_expectedModelSizes.TryGetValue(modelName, out var expectedSize))
            throw new ArgumentException($"Unknown model size: {modelName}");

        var fileInfo = new FileInfo(tmpPath);
        var actualSize = fileInfo.Length;

        // Allow 1% tolerance for file size variations
        var tolerance = (long)(expectedSize * 0.01);
        var minSize = expectedSize - tolerance;
        var maxSize = expectedSize + tolerance;

        if (actualSize < minSize || actualSize > maxSize)
        {
            // IMPORTANT: Do NOT delete .tmp on validation failure — keep for debugging
            throw new InvalidDataException(
                $"Downloaded model size mismatch: expected ~{expectedSize:N0} bytes (±1%), got {actualSize:N0} bytes. Partial file kept at {tmpPath} for debugging.");
        }

        // Atomic rename: only promote to .bin after successful size validation
        if (File.Exists(destinationPath))
            File.Delete(destinationPath);
        File.Move(tmpPath, destinationPath);
    }
}
