# Dua Talk

A minimal, fully offline dictation app for macOS. Press a hotkey, speak, and your words are pasted instantly. No cloud services, no subscriptions.

## Install

Download the latest DMG from [Releases](https://github.com/Sebstrdigital/dua-talk/releases), drag to Applications, and launch. The setup screen will guide you through permissions.

Or build from source:

```bash
git clone https://github.com/Sebstrdigital/dua-talk.git
cd dua-talk/DuaTalk
swift build
.build/debug/DuaTalk
```

## Features

- **Fully Offline** — WhisperKit runs speech-to-text locally on your Mac
- **Menu Bar App** — sits quietly in your menu bar
- **Global Hotkeys** — toggle or push-to-talk recording from any app
- **fn/Globe Key Support** — use the fn key as a hotkey modifier
- **Auto-paste** — transcription goes straight to your cursor
- **Text-to-Speech** — select text and have it read aloud via Kokoro TTS
- **History** — access your last 5 dictations from the menu
- **Multi-language** — English and Swedish

## Permissions

The setup screen checks these for you on first launch:

| Permission | Why | How |
|------------|-----|-----|
| **Microphone** | Record audio | Click "Grant" on the setup screen |
| **Accessibility** | Global hotkeys + auto-paste | System Settings > Privacy & Security > Accessibility |

## Hotkeys

All hotkeys are customizable via **Settings** in the menu bar.

| Mode | Default | Behavior |
|------|---------|----------|
| **Toggle** | Shift + Ctrl | Press to start, press again to stop |
| **Push-to-Talk** | Cmd + Shift | Hold to record, release to stop |
| **Read Aloud** | Cmd + Alt | Reads selected text aloud |

Switch between Toggle and Push-to-Talk in the Settings menu.

## Text-to-Speech

Select text in any app and press the Read Aloud hotkey. Set up the TTS engine from the setup screen (Setup... in the menu bar) — it downloads Kokoro TTS automatically.

## Advanced Settings

Available under **Advanced** in the menu bar:

| Setting | Options |
|---------|---------|
| **Language** | English, Svenska |
| **Whisper Model** | Small (~500MB, balanced), Medium (~1.5GB, accurate) |
| **Voice** | Multiple Kokoro TTS voices |

## Building a Release

```bash
cd DuaTalk
./scripts/build-release.sh
```

This archives, signs, bundles the Whisper model, notarizes with Apple, and produces a DMG at `build/DuaTalk.dmg`.

Requires a Developer ID certificate and notarization credentials (see script header for setup).

## Python Implementation

A legacy Python implementation is also available in `python/`. See `python/` for details.

```bash
cd python
uv sync && source .venv/bin/activate
python dua_talk.py
```

## Troubleshooting

**Hotkey not working** — Check that the app (or Terminal for dev builds) is listed in System Settings > Privacy & Security > Accessibility. Restart after granting.

**Microphone not detected** — Click "Grant" on the setup screen, or manually enable in System Settings > Privacy & Security > Microphone.

**Text-to-speech not working** — Open the setup screen (Setup... in menu bar) and click "Set Up" next to Text-to-Speech. Requires Python 3.

**App won't start** — Clean and rebuild: `cd DuaTalk && rm -rf .build && swift build`

## Resources

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — On-device speech recognition for Apple Silicon
- [Kokoro TTS](https://github.com/hexgrad/kokoro) — Text-to-speech engine

## License

[MIT License](LICENSE)
