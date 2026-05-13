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

    public const int ProcessingFrameCount = 8;

    public static Icon[] CreateProcessingFrames()
    {
        var frames = new Icon[ProcessingFrameCount];
        for (int i = 0; i < ProcessingFrameCount; i++)
            frames[i] = CreateProcessingFrame(i * 360f / ProcessingFrameCount);
        return frames;
    }

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

        var hIcon = bmp.GetHicon();
        var icon  = (Icon)Icon.FromHandle(hIcon).Clone();
        DestroyIcon(hIcon);
        return icon;
    }

    // Half-tone gray fill + faded "D" + rotating bright arc as ring overlay.
    // `arcStartDeg` advances per frame to animate the spinner.
    private static Icon CreateProcessingFrame(float arcStartDeg)
    {
        using var bmp = new Bitmap(32, 32, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);

        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        g.Clear(Color.Transparent);

        // Inset half-tone gray fill so the arc reads as an outer ring.
        using var bgBrush = new SolidBrush(Color.FromArgb(110, 110, 115));
        g.FillEllipse(bgBrush, 3, 3, 25, 25);

        // Faded "D"
        using var font = new Font("Segoe UI", 17, FontStyle.Bold, GraphicsUnit.Pixel);
        using var textBrush = new SolidBrush(Color.FromArgb(200, 255, 255, 255));
        const string letter = "D";
        var size = g.MeasureString(letter, font);
        float x = (32f - size.Width)  / 2f + 0.5f;
        float y = (32f - size.Height) / 2f;
        g.DrawString(letter, font, textBrush, x, y);

        // Bright rotating arc — 110° sweep, ~2.5px stroke.
        using var arcPen = new Pen(Color.FromArgb(255, 255, 255, 255), 2.5f)
        {
            StartCap = LineCap.Round,
            EndCap   = LineCap.Round
        };
        g.DrawArc(arcPen, 1.5f, 1.5f, 28f, 28f, arcStartDeg, 110f);

        var hIcon = bmp.GetHicon();
        var icon  = (Icon)Icon.FromHandle(hIcon).Clone();
        DestroyIcon(hIcon);
        return icon;
    }
}
