using System.IO;
using System.Media;

namespace DiktaWindows.Services;

public class AudioFeedback
{
    private readonly ConfigService _configService;

    public AudioFeedback(ConfigService configService)
    {
        _configService = configService;
    }

    public void PlayStart()
    {
        if (_configService.Config.MuteSounds) return;
        PlaySound("start.wav");
    }

    public void PlayStop()
    {
        if (_configService.Config.MuteSounds) return;
        PlaySound("stop.wav");
    }

    private static void PlaySound(string filename)
    {
        var path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Sounds", filename);
        if (!File.Exists(path)) return;

        var player = new SoundPlayer(path);
        player.Play();
    }
}
