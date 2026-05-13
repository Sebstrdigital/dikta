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
        SystemSounds.Beep.Play();
    }

    public void PlayStop()
    {
        if (_configService.Config.MuteSounds) return;
        SystemSounds.Asterisk.Play();
    }
}
