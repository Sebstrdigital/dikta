using System.Drawing;
using System.Windows.Forms;
using DiktaWindows.Models;

namespace DiktaWindows.Services;

public class TrayIconManager : IDisposable
{
    private readonly ConfigService _configService;
    private readonly HotkeyManager _hotkeyManager;
    private readonly AudioRecorder _recorder;
    private readonly TranscriberService _transcriber;
    private readonly AudioFeedback _audioFeedback;
    private readonly HistoryService _history;

    private NotifyIcon? _notifyIcon;
    private bool _isRecording;

    public TrayIconManager(ConfigService configService, HotkeyManager hotkeyManager)
    {
        _configService = configService;
        _hotkeyManager = hotkeyManager;
        _recorder = new AudioRecorder();
        _transcriber = new TranscriberService(configService);
        _audioFeedback = new AudioFeedback(configService);
        _history = new HistoryService();
    }

    public void Initialize()
    {
        _notifyIcon = new NotifyIcon
        {
            Icon = SystemIcons.Application, // TODO: custom icon
            Visible = true,
            Text = "Dikta",
            ContextMenuStrip = BuildContextMenu()
        };

        _hotkeyManager.HotkeyPressed += OnHotkeyPressed;
    }

    private ContextMenuStrip BuildContextMenu()
    {
        var menu = new ContextMenuStrip();

        // History submenu
        var historyMenu = new ToolStripMenuItem("History");
        UpdateHistoryMenu(historyMenu);
        menu.Items.Add(historyMenu);

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

    private void UpdateHistoryMenu(ToolStripMenuItem historyMenu)
    {
        historyMenu.DropDownItems.Clear();

        var recent = _history.Items.Take(10);
        foreach (var item in recent)
        {
            var preview = item.Text.Length > 50 ? item.Text[..50] + "..." : item.Text;
            historyMenu.DropDownItems.Add(preview, null, (s, e) =>
            {
                System.Windows.Clipboard.SetText(item.Text);
            });
        }

        if (!_history.Items.Any())
        {
            historyMenu.DropDownItems.Add("(no history)").Enabled = false;
        }
    }

    private async void OnHotkeyPressed()
    {
        if (_isRecording)
        {
            // Stop recording
            _audioFeedback.PlayStop();
            var audioPath = _recorder.StopRecording();
            _isRecording = false;

            // TODO: update tray icon to processing state

            // Transcribe
            var text = await _transcriber.TranscribeAsync(audioPath);

            if (!string.IsNullOrWhiteSpace(text))
            {
                ClipboardManager.CopyAndPaste(text);
                _history.Add(text, _configService.Config.Language);
            }

            // TODO: update tray icon to idle state
        }
        else
        {
            // Start recording
            if (!_transcriber.IsModelAvailable())
            {
                System.Windows.MessageBox.Show(
                    $"Whisper model not found.\n\nPlease download the model file to:\n{ConfigService.ModelsDir}",
                    "Dikta — Model Missing",
                    System.Windows.MessageBoxButton.OK,
                    System.Windows.MessageBoxImage.Warning);
                return;
            }

            _audioFeedback.PlayStart();
            _recorder.StartRecording();
            _isRecording = true;

            // TODO: update tray icon to recording state
        }
    }

    private void OpenSettings()
    {
        // TODO: implement settings window (US-003)
    }

    public void Dispose()
    {
        _notifyIcon?.Dispose();
        _recorder.Dispose();
    }
}
