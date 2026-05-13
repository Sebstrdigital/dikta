using System.IO;
using System.Net.Http;
using System.Threading;

namespace DiktaWindows.Services;

public class ModelDownloader
{
    private static readonly HttpClient _httpClient = new() { Timeout = Timeout.InfiniteTimeSpan };
    private const string BaseUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

    // Approximate model sizes in bytes — used for UX display only (e.g. "Download model now? (~500 MB)").
    // Not used for validation; Whisper.net will reject corrupt files at load time.
    private static readonly Dictionary<string, long> _expectedModelSizes = new()
    {
        { "small", 487_601_967 },      // ~465 MB
        { "medium", 1_533_763_059 }    // ~1.5 GB
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

        // Atomic rename to final destination
        if (File.Exists(destinationPath))
            File.Delete(destinationPath);
        File.Move(tmpPath, destinationPath);
    }
}
