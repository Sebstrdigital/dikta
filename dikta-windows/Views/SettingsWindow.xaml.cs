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

    public SettingsWindow(ConfigService configService, HotkeyManager hotkeyManager)
    {
        InitializeComponent();
        _configService = configService;
        _hotkeyManager = hotkeyManager;

        PopulateKeyCombo();
        PopulateLanguageCombo();
        PopulateModelCombo();
        LoadCurrentHotkey();
    }

    private void PopulateKeyCombo()
    {
        for (char c = 'A'; c <= 'Z'; c++)
            KeyCombo.Items.Add(c.ToString());
        for (char c = '0'; c <= '9'; c++)
            KeyCombo.Items.Add(c.ToString());
    }

    private void LoadCurrentHotkey()
    {
        var currentMods = _configService.Config.HotkeyModifiers
            .Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Select(m => m.ToLowerInvariant())
            .ToHashSet();

        foreach (ListBoxItem item in ModifiersList.Items)
        {
            if (currentMods.Contains(item.Content.ToString()!.ToLowerInvariant()))
                ModifiersList.SelectedItems.Add(item);
        }

        var currentKey = _configService.Config.HotkeyKey.ToUpperInvariant();
        KeyCombo.SelectedItem = currentKey;
        if (KeyCombo.SelectedItem == null && KeyCombo.Items.Count > 0)
            KeyCombo.SelectedIndex = 0;

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
    }

    private void PopulateLanguageCombo()
    {
        foreach (var lang in Language.All)
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
        var selectedMods = ModifiersList.SelectedItems
            .Cast<ListBoxItem>()
            .Select(i => i.Content.ToString()!)
            .ToList();

        var modifierString = selectedMods.Count > 0
            ? string.Join("+", selectedMods)
            : string.Empty;

        var key = KeyCombo.SelectedItem?.ToString() ?? _configService.Config.HotkeyKey;

        try
        {
            _hotkeyManager.ReregisterHotkey(modifierString, key);
        }
        catch (InvalidOperationException ex)
        {
            MessageBox.Show(ex.Message, "Hotkey Registration Failed", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        _configService.Config.HotkeyModifiers = modifierString;
        _configService.Config.HotkeyKey = key;
        _configService.Config.MuteSounds = MuteSoundsCheckBox.IsChecked ?? false;

        if (LanguageCombo.SelectedItem is ComboBoxItem langItem)
            _configService.Config.Language = langItem.Tag?.ToString() ?? _configService.Config.Language;

        if (ModelCombo.SelectedItem is ComboBoxItem modelItem)
            _configService.Config.WhisperModel = modelItem.Tag?.ToString() ?? _configService.Config.WhisperModel;

        _configService.Save();

        Close();
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        Close();
    }
}
