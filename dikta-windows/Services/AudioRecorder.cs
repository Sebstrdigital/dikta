using System.IO;
using NAudio.Wave;

namespace DiktaWindows.Services;

public class AudioRecorder : IDisposable
{
    private WaveInEvent? _waveIn;
    private WaveFileWriter? _writer;
    private string? _tempFilePath;

    public bool IsRecording { get; private set; }

    public string StartRecording()
    {
        _tempFilePath = Path.Combine(Path.GetTempPath(), $"dikta_{Guid.NewGuid()}.wav");

        // 16kHz mono 16-bit — what Whisper expects
        var waveFormat = new WaveFormat(16000, 16, 1);

        _waveIn = new WaveInEvent
        {
            WaveFormat = waveFormat,
            BufferMilliseconds = 100
        };

        _writer = new WaveFileWriter(_tempFilePath, waveFormat);

        _waveIn.DataAvailable += (s, e) =>
        {
            _writer?.Write(e.Buffer, 0, e.BytesRecorded);
        };

        _waveIn.StartRecording();
        IsRecording = true;

        return _tempFilePath;
    }

    public string StopRecording()
    {
        _waveIn?.StopRecording();
        _writer?.Dispose();
        _waveIn?.Dispose();

        _waveIn = null;
        _writer = null;
        IsRecording = false;

        return _tempFilePath ?? "";
    }

    public void Dispose()
    {
        if (IsRecording) StopRecording();
    }
}
