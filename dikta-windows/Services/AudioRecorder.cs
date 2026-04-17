using System.IO;
using NAudio.Wave;

namespace DiktaWindows.Services;

public class AudioRecorder : IDisposable
{
    private WaveInEvent? _waveIn;
    private WaveFileWriter? _writer;
    private string? _tempFilePath;
    private TaskCompletionSource<string>? _stopTcs;

    public bool IsRecording { get; private set; }

    public string StartRecording()
    {
        if (WaveIn.DeviceCount == 0)
            throw new InvalidOperationException("No microphone found");

        _tempFilePath = Path.Combine(Path.GetTempPath(), $"dikta_{Guid.NewGuid()}.wav");

        // 16kHz mono 16-bit — what Whisper expects
        var waveFormat = new WaveFormat(16000, 16, 1);

        _waveIn = new WaveInEvent
        {
            WaveFormat = waveFormat,
            BufferMilliseconds = 100
        };

        try
        {
            _writer = new WaveFileWriter(_tempFilePath, waveFormat);
        }
        catch
        {
            _waveIn.Dispose();
            _waveIn = null;
            throw;
        }

        _waveIn.DataAvailable += (s, e) =>
        {
            _writer?.Write(e.Buffer, 0, e.BytesRecorded);
        };

        _waveIn.RecordingStopped += OnRecordingStopped;

        _waveIn.StartRecording();
        IsRecording = true;

        DiagnosticLogger.Info($"Recording started. TempFile={_tempFilePath}");

        return _tempFilePath;
    }

    public Task<string> StopRecordingAsync()
    {
        _stopTcs = new TaskCompletionSource<string>();

        _waveIn?.StopRecording();

        return _stopTcs.Task;
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        DiagnosticLogger.Info($"Recording stopped. TempFile={_tempFilePath}, StoppedArgsException={e.Exception?.Message ?? "none"}");

        _writer?.Dispose();
        _writer = null;

        _waveIn?.Dispose();
        _waveIn = null;

        IsRecording = false;

        _stopTcs?.TrySetResult(_tempFilePath ?? "");
    }

    public void Dispose()
    {
        if (IsRecording)
        {
            _waveIn?.StopRecording();
            // RecordingStopped will handle cleanup
        }
        else
        {
            _writer?.Dispose();
            _waveIn?.Dispose();
        }
    }
}
