using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using DiktaWindows.Services;
using DiktaWindows.Views;

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
        // An AbandonedMutexException is thrown when the previous owner crashed while
        // holding the mutex. The exception itself signals that we now own the mutex,
        // so we treat it the same as createdNew=true and continue startup normally.
        bool createdNew;
        try
        {
            _singleInstanceMutex = new Mutex(
                initiallyOwned: true,
                name: MutexName,
                out createdNew);
        }
        catch (AbandonedMutexException ex)
        {
            // Previous instance crashed while holding the mutex. We now own it.
            _singleInstanceMutex = ex.Mutex;
            createdNew = true;
        }

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

            _singleInstanceMutex?.Dispose();
            _singleInstanceMutex = null;
            Shutdown();
            return;
        }

        // Wire unhandled-exception handlers so crashes are logged and surfaced.
        DispatcherUnhandledException += (_, ex) =>
        {
            DiagnosticLogger.Exception("UI thread crash", ex.Exception);
            WriteCrashLog(ex.Exception);
            ShowCrashBalloon(ex.Exception.Message);
            ex.Handled = true;
            Shutdown(1);
        };

        AppDomain.CurrentDomain.UnhandledException += (_, ex) =>
        {
            var exception = ex.ExceptionObject as Exception
                ?? new Exception(ex.ExceptionObject?.ToString() ?? "Unknown exception");
            DiagnosticLogger.Exception("AppDomain crash", exception);
            WriteCrashLog(exception);
            ShowCrashBalloon(exception.Message);
            // CLR will terminate the process after this handler returns for fatal exceptions.
        };

        TaskScheduler.UnobservedTaskException += (_, ex) =>
        {
            DiagnosticLogger.Exception("Unobserved task exception", ex.Exception);
            WriteCrashLog(ex.Exception);
            ShowCrashBalloon(ex.Exception.Message);
            ex.SetObserved(); // Prevent the default escalation policy from terminating the process.
        };

        base.OnStartup(e);

        DiagnosticLogger.Info($"App startup. Version={Assembly.GetExecutingAssembly().GetName().Version}, OS={Environment.OSVersion}, Runtime={RuntimeInformation.FrameworkDescription}");

        _configService = new ConfigService();

        var modelPath = Path.Combine(ConfigService.ModelsDir, $"ggml-{_configService.Config.WhisperModel}.bin");
        DiagnosticLogger.Info($"Config loaded. ModelPath={modelPath}, ModelExists={File.Exists(modelPath)}");

        _hotkeyManager = new HotkeyManager(_configService);
        _trayIcon = new TrayIconManager(_configService, _hotkeyManager);

        // Wire cross-instance "show onboarding" signal to the HotkeyManager listener.
        // TrayIconManager subscribes to ShowOnboardingRequested in its Initialize() — see
        // dikta-windows/Services/TrayIconManager.cs — which opens/activates the OnboardingWindow.
        uint showOnboardingMsg = RegisterWindowMessage("DiktaShowOnboarding");
        if (showOnboardingMsg != 0)
        {
            _hotkeyManager.RegisterExternalMessage(showOnboardingMsg);
        }

        _trayIcon.Initialize();

        if (_configService.Config.ShowOnStartup)
        {
            // Route through TrayIconManager so the single-window guard tracks this instance.
            // Otherwise tray "About" would open a duplicate modal while the startup one is still visible.
            _trayIcon.OpenOnboarding();
        }
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
            // ShowBalloonTip is a WinForms call that must run on the UI thread.
            // Dispatcher.Invoke is safe even when already on the UI thread (no-ops to a direct call).
            // If the Dispatcher is null (very early crash before the Application is fully initialised),
            // fall through to the direct call inside the catch-all above.
            var dispatcher = Application.Current?.Dispatcher;
            if (dispatcher != null)
                dispatcher.Invoke(() => _trayIcon?.ShowBalloon("Dikta crashed", $"Dikta crashed: {message}. Please report this."));
            else
                _trayIcon?.ShowBalloon("Dikta crashed", $"Dikta crashed: {message}. Please report this.");
        }
        catch
        {
            // Best-effort: tray may not be initialised yet for very early crashes.
        }
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
