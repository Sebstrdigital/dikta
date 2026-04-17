using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace DiktaWindows.Services;

public static class ClipboardManager
{
    private const ushort VK_LCONTROL = 0xA2;
    private const ushort VK_V = 0x56;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_SCANCODE = 0x0008;
    private const uint MAPVK_VK_TO_VSC = 0;
    private const int INPUT_KEYBOARD = 1;

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public int type;
        public InputUnion u;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKey(uint uCode, uint uMapType);

    [DllImport("user32.dll")]
    private static extern IntPtr GetOpenClipboardWindow();

    public static async Task CopyAndPasteAsync(string text)
    {
        // Set clipboard on UI thread using WinForms clipboard (avoids CLIPBRD_E_CANT_OPEN)
        await System.Windows.Application.Current.Dispatcher.InvokeAsync(() =>
        {
            System.Windows.Forms.Clipboard.SetText(text);
        });

        // Wait until the clipboard is idle (no other window holds it open) or 500 ms elapses.
        // This avoids a fixed delay while still handling slow apps that take time to release
        // the clipboard after SetText returns.
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < 500 && GetOpenClipboardWindow() != IntPtr.Zero)
        {
            await Task.Delay(10);
        }

        // Simulate Ctrl+V atomically via SendInput.
        // Use VK_LCONTROL (left Ctrl) so apps that track left/right modifier keys see the
        // correct extended key. Populate wScan via MapVirtualKey so apps that inspect scan
        // codes (Outlook, Teams, some browser address bars) accept the event. If
        // MapVirtualKey returns 0 for either key we fall back to virtual-key-only (no
        // KEYEVENTF_SCANCODE), which preserves the original behaviour.
        var inputs = new INPUT[4];

        ushort scanCtrl = (ushort)MapVirtualKey(VK_LCONTROL, MAPVK_VK_TO_VSC);
        ushort scanV    = (ushort)MapVirtualKey(VK_V,        MAPVK_VK_TO_VSC);
        bool useScanCode = scanCtrl != 0 && scanV != 0;

        uint flagsScancode     = useScanCode ? KEYEVENTF_SCANCODE           : 0u;
        uint flagsScancodeUp   = useScanCode ? KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP : KEYEVENTF_KEYUP;

        // Ctrl down
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki = new KEYBDINPUT { wVk = VK_LCONTROL, wScan = scanCtrl, dwFlags = flagsScancode };

        // V down
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki = new KEYBDINPUT { wVk = VK_V, wScan = scanV, dwFlags = flagsScancode };

        // V up
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].u.ki = new KEYBDINPUT { wVk = VK_V, wScan = scanV, dwFlags = flagsScancodeUp };

        // Ctrl up
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].u.ki = new KEYBDINPUT { wVk = VK_LCONTROL, wScan = scanCtrl, dwFlags = flagsScancodeUp };

        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }
}
