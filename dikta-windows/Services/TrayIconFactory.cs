using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace DiktaWindows.Services;

/// <summary>
/// Generates tray icons programmatically — no .ico file required.
/// Idle: dark charcoal background. Recording: red background.
/// </summary>
internal static class TrayIconFactory
{
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);

    public static Icon CreateIdleIcon()      => CreateLetterIcon(Color.FromArgb(44, 44, 46));
    public static Icon CreateRecordingIcon() => CreateLetterIcon(Color.FromArgb(229, 57, 53));

    private static Icon CreateLetterIcon(Color background)
    {
        using var bmp = new Bitmap(32, 32, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);

        g.SmoothingMode   = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        g.Clear(Color.Transparent);

        // Filled circle background
        using var bgBrush = new SolidBrush(background);
        g.FillEllipse(bgBrush, 1, 1, 29, 29);

        // White "D" centred in circle
        using var font = new Font("Segoe UI", 17, FontStyle.Bold, GraphicsUnit.Pixel);
        using var textBrush = new SolidBrush(Color.White);
        const string letter = "D";
        var size = g.MeasureString(letter, font);
        float x = (32f - size.Width)  / 2f + 0.5f;
        float y = (32f - size.Height) / 2f;
        g.DrawString(letter, font, textBrush, x, y);

        // GetHicon gives an HICON handle; clone into a managed Icon then release the raw handle.
        var hIcon = bmp.GetHicon();
        var icon  = (Icon)Icon.FromHandle(hIcon).Clone();
        DestroyIcon(hIcon);
        return icon;
    }
}
