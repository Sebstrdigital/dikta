using System.IO;
using System.Windows;
using System.Windows.Controls;
using DiktaWindows.Models;
using DiktaWindows.Services;

namespace DiktaWindows.Views;

public partial class SettingsWindow : Window
{
    private readonly ConfigService _configService;
    private readonly HotkeyManager _hotkeyManager;

    private string _pendingModifiers = "";
    private string _pendingKey = "";

    public SettingsWindow(ConfigService configService, HotkeyManager hotkeyManager)
    {
        InitializeComponent();
        _configService = configService;
        _hotkeyManager = hotkeyManager;

        PopulateLanguageCombo();
        PopulateModelCombo();
        PopulateMicSensitivityCombo();
        LoadCurrentSettings();

        _pendingModifiers = _configService.Config.HotkeyModifiers;
        _pendingKey = _configService.Config.HotkeyKey;
        CurrentHotkeyLabel.Text = FormatHotkey(_pendingModifiers, _pendingKey);
    }

    private void PopulateMicSensitivityCombo()
    {
        var options = new[]
        {
            (DiktaWindows.Models.MicSensitivity.Normal,  "Normal (desk / laptop mic)"),
            (DiktaWindows.Models.MicSensitivity.Headset, "Headset (Bluetooth / wired headset)"),
        };

        foreach (var (value, label) in options)
        {
            MicSensitivityCombo.Items.Add(new ComboBoxItem
            {
                Content = label,
                Tag = value
            });
        }
    }

    private void LoadCurrentSettings()
    {
        MuteSoundsCheckBox.IsChecked = _configService.Config.MuteSounds;

        var currentLang = _configService.Config.Language;
        foreach (ComboBoxItem item in LanguageCombo.Items)
        {
            if (item.Tag?.ToString() == currentLang)
            {
                LanguageCombo.SelectedItem = item;
                break;
            }
        }
        if (LanguageCombo.SelectedItem == null && LanguageCombo.Items.Count > 0)
            LanguageCombo.SelectedIndex = 0;

        var currentModel = _configService.Config.WhisperModel;
        foreach (ComboBoxItem item in ModelCombo.Items)
        {
            if (item.Tag?.ToString() == currentModel)
            {
                ModelCombo.SelectedItem = item;
                break;
            }
        }
        if (ModelCombo.SelectedItem == null && ModelCombo.Items.Count > 0)
            ModelCombo.SelectedIndex = 0;

        var currentSensitivity = _configService.Config.Sensitivity;
        foreach (ComboBoxItem item in MicSensitivityCombo.Items)
        {
            if (item.Tag is DiktaWindows.Models.MicSensitivity tag && tag == currentSensitivity)
            {
                MicSensitivityCombo.SelectedItem = item;
                break;
            }
        }
        if (MicSensitivityCombo.SelectedItem == null && MicSensitivityCombo.Items.Count > 0)
            MicSensitivityCombo.SelectedIndex = 0;
    }

    private static string FormatHotkey(string modifiers, string key)
    {
        var parts = modifiers
            .Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .ToList();
        if (!string.IsNullOrEmpty(key))
            parts.Add(key);
        return string.Join(" + ", parts);
    }

    private void ChangeHotkeyButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new HotkeyRecordingWindow(_hotkeyManager) { Owner = this };
        var result = dialog.ShowDialog();

        if (result == true)
        {
            _pendingModifiers = dialog.CapturedModifiers;
            _pendingKey = dialog.CapturedKey;
            CurrentHotkeyLabel.Text = FormatHotkey(_pendingModifiers, _pendingKey);
        }
    }

    private void PopulateLanguageCombo()
    {
        foreach (var lang in DiktaWindows.Models.Language.All)
        {
            LanguageCombo.Items.Add(new ComboBoxItem
            {
                Content = lang.DisplayName,
                Tag = lang.WhisperCode
            });
        }
    }

    private void PopulateModelCombo()
    {
        var models = new[]
        {
            ("small",  "small (~500 MB)"),
            ("medium", "medium (~1.5 GB)"),
            ("large",  "large (~3 GB)"),
        };

        foreach (var (key, label) in models)
        {
            var path = Path.Combine(ConfigService.ModelsDir, $"ggml-{key}.bin");
            var status = File.Exists(path) ? "Downloaded" : "Not downloaded";
            ModelCombo.Items.Add(new ComboBoxItem
            {
                Content = $"{label}  —  {status}",
                Tag = key
            });
        }
    }

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        // Safety double-check: re-register in case dialog's registration was lost.
        // This is idempotent if the binding already matches.
        try
        {
            _hotkeyManager.ReregisterHotkey(_pendingModifiers, _pendingKey);
        }
        catch (InvalidOperationException ex)
        {
            MessageBox.Show(ex.Message, "Hotkey Registration Failed", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        _configService.Config.HotkeyModifiers = _pendingModifiers;
        _configService.Config.HotkeyKey = _pendingKey;
        _configService.Config.MuteSounds = MuteSoundsCheckBox.IsChecked ?? false;

        if (LanguageCombo.SelectedItem is ComboBoxItem langItem)
            _configService.Config.Language = langItem.Tag?.ToString() ?? _configService.Config.Language;

        if (ModelCombo.SelectedItem is ComboBoxItem modelItem)
            _configService.Config.WhisperModel = modelItem.Tag?.ToString() ?? _configService.Config.WhisperModel;

        if (MicSensitivityCombo.SelectedItem is ComboBoxItem sensItem && sensItem.Tag is DiktaWindows.Models.MicSensitivity sensValue)
            _configService.Config.Sensitivity = sensValue;

        Exception? saveError = null;
        void OnSaveFailed(Exception ex) => saveError = ex;

        _configService.SaveFailed += OnSaveFailed;
        _configService.Save();
        _configService.SaveFailed -= OnSaveFailed;

        if (saveError is not null)
        {
            MessageBox.Show(
                $"Settings could not be saved:\n{saveError.Message}",
                "Dikta — Save Failed",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            return;
        }

        _saved = true;
        Close();
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        // Close() will fire OnWindowClosing which handles the restore.
        Close();
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        // Covers every close path: Cancel button, title-bar X, Alt+F4, system menu.
        // If user changed the hotkey via the dialog but never saved, the dialog's
        // pre-save test already re-registered the new binding — restore the persisted one
        // to keep runtime + config in sync.
        if (!_saved &&
            (_pendingModifiers != _configService.Config.HotkeyModifiers ||
             _pendingKey != _configService.Config.HotkeyKey))
        {
            try
            {
                _hotkeyManager.ReregisterHotkey(
                    _configService.Config.HotkeyModifiers,
                    _configService.Config.HotkeyKey);
            }
            catch { /* best-effort restore */ }
        }

        base.OnClosing(e);
    }

    private bool _saved;
}
