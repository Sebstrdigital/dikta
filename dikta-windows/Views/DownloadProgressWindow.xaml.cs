using System.Windows;

namespace DiktaWindows.Views;

public partial class DownloadProgressWindow : Window
{
    private readonly CancellationTokenSource _cts = new();
    private bool _completed;

    public CancellationToken Token => _cts.Token;
    public IProgress<(long bytesRead, long? totalBytes)> Progress { get; }

    public DownloadProgressWindow()
    {
        InitializeComponent();
        Progress = new Progress<(long bytesRead, long? totalBytes)>(UpdateProgress);
    }

    private void UpdateProgress((long bytesRead, long? totalBytes) info)
    {
        var mbRead = info.bytesRead / (1024.0 * 1024.0);
        if (info.totalBytes is { } total && total > 0)
        {
            var mbTotal = total / (1024.0 * 1024.0);
            var pct = (double)info.bytesRead / total * 100.0;
            DownloadProgressBar.Value = pct;
            StatusText.Text = $"Downloading\u2026 {pct:F0}%";
            SizeText.Text = $"{mbRead:F0} MB / {mbTotal:F0} MB";
        }
        else
        {
            SizeText.Text = $"{mbRead:F0} MB downloaded";
        }
    }

    public void MarkCompleted()
    {
        _completed = true;
        Dispatcher.Invoke(Close);
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        _cts.Cancel();
        CancelButton.IsEnabled = false;
        StatusText.Text = "Cancelling\u2026";
    }

    protected override void OnClosed(EventArgs e)
    {
        base.OnClosed(e);
        if (!_completed)
            _cts.Cancel();
    }
}
