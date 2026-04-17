namespace DiktaWindows.Models;

public enum MicSensitivity { Normal, Headset }

public static class MicSensitivityExtensions
{
    public static float NoSpeechThreshold(this MicSensitivity s) => s switch
    {
        MicSensitivity.Headset => 0.15f,
        _ => 0.3f
    };
}
