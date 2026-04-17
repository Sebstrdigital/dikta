using System.Drawing;
using System.Windows.Forms;
using DiktaWindows.Models;
using DiktaWindows.Views;

namespace DiktaWindows.Services;

public class TrayIconManager : IDisposable
{
    private readonly ConfigService _configService;
    private readonly HotkeyManager _hotkeyManager;
    private readonly AudioRecorder _recorder;
    private readonly TranscriberService _transcriber;
    private readonly AudioFeedback _audioFeedback;
    private readonly HistoryService _history;
    private readonly ModelDownloader _modelDownloader;

    private NotifyIcon? _notifyIcon;
    private ToolStripMenuItem? _languageMenu;
    private Icon? _idleIcon;
    private Icon? _recordingIcon;
    private bool _isRecording;
    private int _processingFlag; // 0 = idle, 1 = processing; guarded via Interlocked
    private SettingsWindow? _settingsWindow;

    public TrayIconManager(ConfigService configService, HotkeyManager hotkeyManager)
    {
        _configService = configService;
        _hotkeyManager = hotkeyManager;
        _recorder = new AudioRecorder();
        _transcriber = new TranscriberService(configService);
        _audioFeedback = new AudioFeedback(configService);
        _history = new HistoryService();
        _modelDownloader = new ModelDownloader();
    }

    public void Initialize()
    {
        _idleIcon      = TrayIconFactory.CreateIdleIcon();
        _recordingIcon = TrayIconFactory.CreateRecordingIcon();

        _notifyIcon = new NotifyIcon
        {
            Icon = _idleIcon,
            Visible = true,
            Text = BuildTooltip(),
            ContextMenuStrip = BuildContextMenu()
        };

        _hotkeyManager.HotkeyPressed += OnHotkeyPressed;
        _configService.SaveFailed += OnConfigSaveFailed;

        if (_configService.WasReset)
            _notifyIcon.ShowBalloonTip(3000, "Dikta", "Config was unreadable — reset to defaults.", ToolTipIcon.Warning);

        // Surface hotkey registration failure that occurred during HotkeyManager construction
        // (before TrayIconManager existed). The tray icon is now visible, so the balloon can show.
        if (_hotkeyManager.RegistrationFailedOnStartup)
            _notifyIcon.ShowBalloonTip(
                4000,
                "Dikta — Hotkey Unavailable",
                "The dictation hotkey is in use by another app. Open Settings to choose a different one.",
                ToolTipIcon.Warning);
    }

    private string BuildTooltip()
    {
        var lang = Language.FromCode(_configService.Config.Language);
        return $"Dikta — {lang.DisplayName}";
    }

    private void UpdateTrayState()
    {
        if (_notifyIcon is null) return;
        _notifyIcon.Icon = _isRecording ? _recordingIcon : _idleIcon;
        _notifyIcon.Text = BuildTooltip();
    }

    private ContextMenuStrip BuildContextMenu()
    {
        var menu = new ContextMenuStrip();

        // History submenu
        var historyMenu = new ToolStripMenuItem("History");
        UpdateHistoryMenu(historyMenu);
        menu.Items.Add(historyMenu);

        menu.Items.Add(new ToolStripSeparator());

        // Language submenu
        _languageMenu = new ToolStripMenuItem("Language");
        BuildLanguageMenu(_languageMenu);
        menu.Items.Add(_languageMenu);

        menu.Items.Add(new ToolStripSeparator());

        // Settings
        menu.Items.Add("Settings...", null, (s, e) => OpenSettings());

        menu.Items.Add(new ToolStripSeparator());

        // Quit
        menu.Items.Add("Quit", null, (s, e) =>
        {
            _notifyIcon!.Visible = false;
            System.Windows.Application.Current.Shutdown();
        });

        return menu;
    }

    private void BuildLanguageMenu(ToolStripMenuItem languageMenu)
    {
        languageMenu.DropDownItems.Clear();

        var current = _configService.Config.Language;
        foreach (var lang in Language.All)
        {
            var item = new ToolStripMenuItem(lang.DisplayName)
            {
                Checked = lang.WhisperCode == current,
                CheckOnClick = false
            };
            item.Click += (s, e) =>
            {
                _configService.Config.Language = lang.WhisperCode;
                _configService.Save();
                BuildLanguageMenu(languageMenu);
            };
            languageMenu.DropDownItems.Add(item);
        }
    }

    private void UpdateHistoryMenu(ToolStripMenuItem historyMenu)
    {
        historyMenu.DropDownItems.Clear();

        var recent = _history.Items.Take(10);
        foreach (var item in recent)
        {
            var preview = item.Text.Length > 50 ? item.Text[..50] + "..." : item.Text;
            historyMenu.DropDownItems.Add(preview, null, (s, e) =>
            {
                System.Windows.Forms.Clipboard.SetText(item.Text);
            });
        }

        if (!_history.Items.Any())
        {
            historyMenu.DropDownItems.Add("(no history)").Enabled = false;
        }
    }

    private async void OnHotkeyPressed()
    {
        // Atomically claim the processing slot (0→1). If the flag was already 1, another press
        // is in flight — return immediately so we never enter the transcription path twice.
        if (System.Threading.Interlocked.CompareExchange(ref _processingFlag, 1, 0) != 0)
            return;

        try
        {
            if (_isRecording)
            {
                // Stop recording
                _audioFeedback.PlayStop();
                var audioPath = await _recorder.StopRecordingAsync();
                _isRecording = false;
                UpdateTrayState();

                // Transcribe
                var text = await _transcriber.TranscribeAsync(audioPath);

                if (!string.IsNullOrWhiteSpace(text))
                {
                    await ClipboardManager.CopyAndPasteAsync(text);
                    _history.Add(text, _configService.Config.Language);
                }
            }
            else
            {
                // Start recording
                if (!_transcriber.IsModelAvailable())
                {
                    var modelName = _configService.Config.WhisperModel;
                    var sizeBytes = ModelDownloader.ExpectedModelSizes[modelName];
                    var sizeDisplay = sizeBytes >= 1_073_741_824
                        ? (sizeBytes / 1_073_741_824.0).ToString("F1") + " GB"
                        : (sizeBytes / 1_048_576.0).ToString("F0") + " MB";

                    var result = System.Windows.MessageBox.Show(
                        $"The Whisper model is not downloaded yet.\n\nDownload model now? (~{sizeDisplay})",
                        "Dikta — Download Model",
                        System.Windows.MessageBoxButton.YesNo,
                        System.Windows.MessageBoxImage.Question);

                    if (result != System.Windows.MessageBoxResult.Yes)
                        return;

                    var destPath = System.IO.Path.Combine(ConfigService.ModelsDir, $"ggml-{modelName}.bin");
                    bool downloadSucceeded = false;

                    while (!downloadSucceeded)
                    {
                        var progressWindow = new DownloadProgressWindow();
                        progressWindow.Show();
                        try
                        {
                            await _modelDownloader.DownloadModelAsync(modelName, destPath, progressWindow.Progress, progressWindow.Token);
                            progressWindow.MarkCompleted();
                            downloadSucceeded = true;
                        }
                        catch (OperationCanceledException)
                        {
                            progressWindow.Close();
                            return;
                        }
                        catch (Exception dlEx)
                        {
                            progressWindow.Close();
                            var retry = System.Windows.MessageBox.Show(
                                $"Model download failed:\n{dlEx.Message}\n\nRetry?",
                                "Dikta — Download Error",
                                System.Windows.MessageBoxButton.YesNo,
                                System.Windows.MessageBoxImage.Error);
                            if (retry != System.Windows.MessageBoxResult.Yes)
                                return;
                        }
                    }
                }

                _audioFeedback.PlayStart();
                _recorder.StartRecording();
                _isRecording = true;
                UpdateTrayState();
            }
        }
        catch (Exception ex)
        {
            _isRecording = false;
            UpdateTrayState();
            var message = ex is InvalidOperationException && ex.Message == "No microphone found"
                ? "No microphone found"
                : "Transcription failed. Please try again.";
            _notifyIcon?.ShowBalloonTip(3000, "Dikta", message, ToolTipIcon.Error);
        }
        finally
        {
            // Always return to idle — covers normal exit, early return, and unhandled throw.
            System.Threading.Interlocked.Exchange(ref _processingFlag, 0);
        }
    }

    /// <summary>Shows a tray balloon. Best-effort: silently ignored if the tray icon is not yet initialised.</summary>
    public void ShowBalloon(string title, string message)
    {
        _notifyIcon?.ShowBalloonTip(5000, title, message, ToolTipIcon.Error);
    }

    private void OnConfigSaveFailed(Exception ex)
    {
        _notifyIcon?.ShowBalloonTip(
            4000,
            "Dikta — Settings Not Saved",
            $"Could not write settings: {ex.Message}",
            ToolTipIcon.Error);
    }

    private void OpenSettings()
    {
        System.Windows.Application.Current.Dispatcher.Invoke(() =>
        {
            if (_settingsWindow != null)
            {
                _settingsWindow.Activate();
                return;
            }
            _settingsWindow = new SettingsWindow(_configService, _hotkeyManager);
            _settingsWindow.Closed += (s, e) => _settingsWindow = null;
            _settingsWindow.Show();
        });
    }

    public void Dispose()
    {
        _configService.SaveFailed -= OnConfigSaveFailed;
        _notifyIcon?.Dispose();
        _idleIcon?.Dispose();
        _recordingIcon?.Dispose();
        _recorder.Dispose();
        _transcriber.Dispose();
    }
}
