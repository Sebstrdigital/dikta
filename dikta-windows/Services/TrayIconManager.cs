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
    private bool _processing;

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
        if (_processing) return;

        try
        {
            if (_isRecording)
            {
                _processing = true;

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

                _processing = false;
            }
            else
            {
                // Start recording
                if (!_transcriber.IsModelAvailable())
                {
                    var result = System.Windows.MessageBox.Show(
                        "The Whisper model is not downloaded yet.\n\nDownload model now? (~150 MB)",
                        "Dikta — Download Model",
                        System.Windows.MessageBoxButton.YesNo,
                        System.Windows.MessageBoxImage.Question);

                    if (result != System.Windows.MessageBoxResult.Yes)
                        return;

                    _processing = true;
                    var modelName = _configService.Config.WhisperModel;
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
                            _processing = false;
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
                            {
                                _processing = false;
                                return;
                            }
                        }
                    }
                    _processing = false;
                }

                _audioFeedback.PlayStart();
                _recorder.StartRecording();
                _isRecording = true;
                UpdateTrayState();
            }
        }
        catch (Exception ex)
        {
            _processing = false;
            _isRecording = false;
            UpdateTrayState();
            System.Diagnostics.Debug.WriteLine($"OnHotkeyPressed error: {ex}");
        }
    }

    private void OpenSettings()
    {
        // TODO: implement settings window
    }

    public void Dispose()
    {
        _notifyIcon?.Dispose();
        _idleIcon?.Dispose();
        _recordingIcon?.Dispose();
        _recorder.Dispose();
    }
}
