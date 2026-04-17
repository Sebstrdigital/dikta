using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Media;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using DiktaWindows.Services;

namespace DiktaWindows.Views;

public partial class OnboardingWindow : Window
{
    private readonly ConfigService _configService;

    public OnboardingWindow(ConfigService configService)
    {
        InitializeComponent();
        _configService = configService;

        LoadVersion();
        LoadHotkey();
        RefreshMicStatus();

        // "Don't show on startup" checked  ↔  ShowOnStartup = false
        DontShowCheckBox.IsChecked = !_configService.Config.ShowOnStartup;

        Closing += OnWindowClosing;
        Activated += OnWindowActivated;
    }

    private void OnWindowClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        _configService.Config.ShowOnStartup = !(DontShowCheckBox.IsChecked ?? false);
        _configService.Save();
    }

    private void OnWindowActivated(object? sender, EventArgs e)
    {
        RefreshMicStatus();
    }

    private void LoadVersion()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "unknown";
        VersionLabel.Text = $"v{version}";
    }

    private void LoadHotkey()
    {
        var modifiers = _configService.Config.HotkeyModifiers;
        var key = _configService.Config.HotkeyKey;

        // Split on "+" and rejoin with " + " for display (e.g. "Ctrl+Shift" → "Ctrl + Shift")
        var parts = modifiers
            .Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .ToList();

        if (!string.IsNullOrEmpty(key))
            parts.Add(key);

        HotkeyLabel.Text = string.Join(" + ", parts);
    }

    private void RefreshMicStatus()
    {
        bool hasAnyCaptureDevice;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
            hasAnyCaptureDevice = devices.Count > 0;
        }
        catch
        {
            // MMDevice API unavailable / COM error — fall back to WaveIn-only heuristic.
            hasAnyCaptureDevice = WaveIn.DeviceCount > 0;
        }

        int waveInCount = WaveIn.DeviceCount;

        if (waveInCount >= 1)
        {
            MicStatusLabel.Text = "Granted";
            MicStatusLabel.Foreground = Brushes.Green;
            GrantButton.Visibility = Visibility.Collapsed;
        }
        else if (hasAnyCaptureDevice)
        {
            // Device exists but WaveIn cannot see it → permission denied
            MicStatusLabel.Text = "Microphone access denied";
            MicStatusLabel.Foreground = Brushes.Red;
            GrantButton.Visibility = Visibility.Visible;
        }
        else
        {
            // No device detected at all → hardware issue
            MicStatusLabel.Text = "No microphone detected";
            MicStatusLabel.Foreground = Brushes.Red;
            GrantButton.Visibility = Visibility.Collapsed;
        }
    }

    private void GrantButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone")
            {
                UseShellExecute = true
            });
        }
        catch
        {
            // Best-effort: swallow all exceptions — settings URI may not be available.
        }
    }
}
