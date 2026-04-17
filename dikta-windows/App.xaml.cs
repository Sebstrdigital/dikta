using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using DiktaWindows.Services;

namespace DiktaWindows;

public partial class App : Application
{
    private const string MutexName = @"Global\Dikta-SingleInstance";
    private static readonly string CrashLogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Dikta",
        "last-crash.log");

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string lpString);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    private static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);

    private Mutex? _singleInstanceMutex;
    private TrayIconManager? _trayIcon;
    private HotkeyManager? _hotkeyManager;
    private ConfigService? _configService;

    protected override void OnStartup(StartupEventArgs e)
    {
        // Single-instance guard: acquire named mutex before creating any windows.
        _singleInstanceMutex = new Mutex(
            initiallyOwned: true,
            name: MutexName,
            out bool createdNew);

        if (!createdNew)
        {
            // Another instance is already running. Signal it and exit cleanly.
            uint showMsg = RegisterWindowMessage("DiktaShowOnboarding");
            if (showMsg != 0)
            {
                PostMessage(HWND_BROADCAST, showMsg, IntPtr.Zero, IntPtr.Zero);
                System.Diagnostics.Debug.WriteLine(
                    $"[Dikta] Second-instance detected — broadcast WM {showMsg} (DiktaShowOnboarding).");
            }

            _singleInstanceMutex.Dispose();
            _singleInstanceMutex = null;
            Shutdown();
            return;
        }

        // Wire unhandled-exception handlers so crashes are logged and surfaced.
        DispatcherUnhandledException += (_, ex) =>
        {
            WriteCrashLog(ex.Exception);
            ShowCrashBalloon(ex.Exception.Message);
            ex.Handled = true;
            Shutdown(1);
        };

        AppDomain.CurrentDomain.UnhandledException += (_, ex) =>
        {
            var exception = ex.ExceptionObject as Exception
                ?? new Exception(ex.ExceptionObject?.ToString() ?? "Unknown exception");
            WriteCrashLog(exception);
            ShowCrashBalloon(exception.Message);
            // CLR will terminate the process after this handler returns for fatal exceptions.
        };

        TaskScheduler.UnobservedTaskException += (_, ex) =>
        {
            WriteCrashLog(ex.Exception);
            ShowCrashBalloon(ex.Exception.Message);
            ex.SetObserved(); // Prevent the default escalation policy from terminating the process.
        };

        base.OnStartup(e);

        _configService = new ConfigService();
        _hotkeyManager = new HotkeyManager(_configService);
        _trayIcon = new TrayIconManager(_configService, _hotkeyManager);

        // Wire cross-instance "show onboarding" signal to the HotkeyManager listener.
        uint showOnboardingMsg = RegisterWindowMessage("DiktaShowOnboarding");
        if (showOnboardingMsg != 0)
        {
            _hotkeyManager.RegisterExternalMessage(showOnboardingMsg);
            _hotkeyManager.ShowOnboardingRequested += OnShowOnboardingRequested;
        }

        _trayIcon.Initialize();
    }

    private static void WriteCrashLog(Exception ex)
    {
        try
        {
            string? dir = Path.GetDirectoryName(CrashLogPath);
            if (dir != null)
                Directory.CreateDirectory(dir);

            string content =
                $"UTC: {DateTime.UtcNow:O}\r\n" +
                $"Type: {ex.GetType().FullName}\r\n" +
                $"Message: {ex.Message}\r\n" +
                $"StackTrace:\r\n{ex.StackTrace}\r\n";

            File.WriteAllText(CrashLogPath, content);
        }
        catch
        {
            // Best-effort: if we can't write the log, there is nothing more we can do.
        }
    }

    private void ShowCrashBalloon(string message)
    {
        try
        {
            _trayIcon?.ShowBalloon("Dikta crashed", $"Dikta crashed: {message}. Please report this.");
        }
        catch
        {
            // Best-effort: tray may not be initialised yet for very early crashes.
        }
    }

    private void OnShowOnboardingRequested()
    {
        System.Diagnostics.Debug.WriteLine(
            "[Dikta] First instance received DiktaShowOnboarding broadcast.");
        // Full foreground activation is handled in F-4. Nothing more needed here.
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayIcon?.Dispose();
        _hotkeyManager?.Dispose();

        // Release the mutex so the next launch can acquire it.
        if (_singleInstanceMutex != null)
        {
            try { _singleInstanceMutex.ReleaseMutex(); }
            catch (ApplicationException) { /* already released */ }
            _singleInstanceMutex.Dispose();
            _singleInstanceMutex = null;
        }

        base.OnExit(e);
    }
}
