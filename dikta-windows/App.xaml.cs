using System.Windows;
using DiktaWindows.Services;

namespace DiktaWindows;

public partial class App : Application
{
    private TrayIconManager? _trayIcon;
    private HotkeyManager? _hotkeyManager;
    private ConfigService? _configService;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _configService = new ConfigService();
        _hotkeyManager = new HotkeyManager(_configService);
        _trayIcon = new TrayIconManager(_configService, _hotkeyManager);

        _trayIcon.Initialize();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayIcon?.Dispose();
        _hotkeyManager?.Dispose();
        base.OnExit(e);
    }
}
