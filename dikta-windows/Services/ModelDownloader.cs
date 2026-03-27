using System.IO;
using System.Net.Http;

namespace DiktaWindows.Services;

public class ModelDownloader
{
    private static readonly HttpClient _httpClient = new();
    private const string BaseUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

    // Expected model sizes in bytes (with 1% tolerance)
    private static readonly Dictionary<string, long> ExpectedModelSizes = new()
    {
        { "small", 511_705_088 },      // 488 MB
        { "medium", 1_606_632_448 },   // 1533 MB
        { "large", 3_244_867_584 }     // 3095 MB
    };

    public async Task DownloadModelAsync(
        string modelName,
        string destinationPath,
        IProgress<(long bytesRead, long? totalBytes)>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var url = $"{BaseUrl}ggml-{modelName}.bin";
        var tmpPath = destinationPath + ".tmp";

        Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);

        // Clean up any previous partial download
        if (File.Exists(tmpPath))
            File.Delete(tmpPath);

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

        // Atomic rename: only promote to .bin after successful completion
        if (File.Exists(destinationPath))
            File.Delete(destinationPath);
        File.Move(tmpPath, destinationPath);

        // Validate file size after successful download
        ValidateModelFile(modelName, destinationPath);
    }

    private void ValidateModelFile(string modelName, string filePath)
    {
        if (!ExpectedModelSizes.TryGetValue(modelName, out var expectedSize))
            throw new ArgumentException($"Unknown model size: {modelName}");

        var fileInfo = new FileInfo(filePath);
        var actualSize = fileInfo.Length;

        // Allow 1% tolerance for file size variations
        var tolerance = (long)(expectedSize * 0.01);
        var minSize = expectedSize - tolerance;
        var maxSize = expectedSize + tolerance;

        if (actualSize < minSize || actualSize > maxSize)
        {
            // Delete corrupt file
            try
            {
                File.Delete(filePath);
            }
            catch
            {
                // Ignore errors during cleanup
            }

            throw new InvalidOperationException(
                $"Downloaded model file is corrupt. Expected size: ~{expectedSize / (1024 * 1024)} MB, " +
                $"but got {actualSize / (1024 * 1024)} MB. File has been deleted. Please try again.");
        }
    }
}
