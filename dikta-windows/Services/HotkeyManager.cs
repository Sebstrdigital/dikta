using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace DiktaWindows.Services;

public class HotkeyManager : IDisposable
{
    private const int WM_HOTKEY = 0x0312;
    private const int HOTKEY_ID = 9000;

    private readonly ConfigService _configService;
    private HwndSource? _source;
    private IntPtr _windowHandle;

    public event Action? HotkeyPressed;

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public HotkeyManager(ConfigService configService)
    {
        _configService = configService;
    }

    public void Register(IntPtr windowHandle)
    {
        _windowHandle = windowHandle;
        _source = HwndSource.FromHwnd(windowHandle);
        _source?.AddHook(HwndHook);

        // Default: Ctrl+Shift+D
        // MOD_CONTROL = 0x0002, MOD_SHIFT = 0x0004
        uint modifiers = 0x0002 | 0x0004;
        uint key = 0x44; // 'D'

        RegisterHotKey(_windowHandle, HOTKEY_ID, modifiers, key);
    }

    private IntPtr HwndHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_HOTKEY && wParam.ToInt32() == HOTKEY_ID)
        {
            HotkeyPressed?.Invoke();
            handled = true;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        UnregisterHotKey(_windowHandle, HOTKEY_ID);
        _source?.RemoveHook(HwndHook);
    }
}
