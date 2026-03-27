# Dikta Windows

A lightweight, fully offline dictation app for Windows. Press a hotkey, speak, and your words are pasted — no cloud services, no internet required (after first model download).

**Current Version:** 1.1

## Features

- **12 Languages** — English, Swedish, Indonesian, Spanish, French, German, Portuguese, Italian, Dutch, Finnish, Norwegian, Danish
- **Offline Transcription** — Uses Whisper.net for on-device speech recognition
- **Customizable Hotkey** — Default Ctrl+Shift+D, change anytime in settings
- **System Tray** — Minimalist menu bar control with language indicator
- **Settings Window** — Configure hotkey, language, model size, and audio feedback
- **History** — Recent transcriptions accessible from tray menu
- **Auto-Update Model** — Whisper models download on demand with progress UI

## Prerequisites

- **Windows 10 (build 19041+)** or **Windows 11**
- **.NET 8 SDK** — [Download from Microsoft](https://dotnet.microsoft.com/download/dotnet/8.0)
- **Microphone** — Any audio input device connected to your PC
- **~500 MB free disk space** — For the Whisper model (first download)

## Installation

### Option 1: Installer (Recommended)

1. Download `DiktaSetup-1.1.exe` from the [Releases page](../releases)
2. Run the installer
3. Select **Start at Login** if you want Dikta to launch automatically
4. Click **Install**
5. On first run, Dikta will offer to download the Whisper model (~500 MB)

### Option 2: Build from Source

#### Step 1: Clone and Restore

```bash
cd dikta-windows
dotnet restore
```

#### Step 2: Build

```bash
dotnet build -c Release
```

#### Step 3: Run

```bash
dotnet run -c Release
```

Dikta appears in the system tray. If a Whisper model isn't present, you'll be prompted to download one.

#### Step 3 Alternative: Publish Self-Contained

For distribution, publish as a self-contained executable:

```bash
dotnet publish -c Release -r win-x64 --self-contained true -o publish/
```

Then run `publish/DiktaWindows.exe`.

## First-Run Walkthrough

1. **Model Download** — On first launch, Dikta detects that no Whisper model is installed and prompts: *"Download model now?"*
   - Click **Yes** to proceed
   - A download progress window appears showing download percentage and size
   - This takes 2–5 minutes depending on internet speed (~500 MB download)

2. **Tray Icon** — After the model is ready, Dikta is idle in the system tray with a custom icon
   - **Hover tooltip** shows *"Dikta — English"* (current language)
   - **Right-click** to open the context menu

3. **First Recording** — Press the default hotkey **Ctrl+Shift+D**:
   - **Audio beep** signals recording has started
   - Speak clearly into your microphone
   - Press **Ctrl+Shift+D** again to stop
   - **Audio asterisk** signals transcription is complete
   - Your transcribed text appears in the clipboard and auto-pastes where you were typing

4. **Change Language** — Right-click tray → **Language** submenu → select your language
   - Next recording will use the selected language

5. **Open Settings** — Right-click tray → **Settings...**
   - **Hotkey** — Change the hotkey to avoid conflicts with other apps
   - **Language** — Select a different language
   - **Model** — Choose model size (small, medium, large)
   - **Mute** — Toggle beep/asterisk audio feedback
   - Click **Save** to apply or **Cancel** to discard changes

## Known Limitations

- **No Push-to-Talk** — Press hotkey to start recording, press again to stop (not continuous while held)
- **No Real-Time Transcription** — Transcription happens after you stop recording
- **No Text-to-Speech** — Dikta only transcribes; it doesn't speak back
- **First Model Download** — Requires internet on first run; subsequent transcriptions work fully offline
- **Windows Only** — Available for Windows 10 build 19041+ and Windows 11 only
- **Model Size** — Small model (~500 MB) is the recommended default; medium/large require more disk space and RAM

## Configuration

Dikta stores settings in `%APPDATA%\Dikta\config.json`. Restart the app after manual edits.

**Example:**

```json
{
  "language": "en",
  "hotkey_modifiers": "Control, Shift",
  "hotkey_key": "D",
  "model_size": "small",
  "mute_sounds": false,
  "history": [
    {
      "timestamp": "2026-03-27T10:30:00Z",
      "text": "hello world"
    }
  ]
}
```

## Troubleshooting

### "No microphone found"
- Check that your microphone is connected and enabled in **Windows Settings → Sound → Input devices**
- Ensure the app has microphone permission in **Windows Settings → Privacy & security → Microphone**

### "Download failed"
- Check your internet connection
- The model is ~500 MB; a slow connection may time out
- Manually delete `%APPDATA%\Dikta\models\` and try again

### App won't start
- Ensure **.NET 8 Runtime** is installed (or use the self-contained published build)
- Check that Windows Defender or antivirus is not blocking the app
- Verify your Windows version is 10 (build 19041+) or 11

### Config reset to defaults unexpectedly
- `config.json` may be corrupted. Close the app and manually edit `%APPDATA%\Dikta\config.json`, or delete it to restore defaults.

### Transcription is slow
- Model size affects speed. The "small" model is optimized for speed; "medium" and "large" are more accurate but slower.
- Microphone and CPU performance also impact transcription time.

## Build & Development

### Project Structure

```
dikta-windows/
├── App.xaml / App.xaml.cs        # WPF Application entry point
├── Models/
│   ├── AppConfig.cs              # Settings structure
│   ├── Language.cs               # 12-language enum
│   └── HistoryItem.cs            # Transcription history
├── Services/
│   ├── HotkeyManager.cs          # Win32 hotkey registration
│   ├── AudioRecorder.cs          # NAudio recording
│   ├── TranscriberService.cs     # Whisper.net wrapper
│   ├── ModelDownloader.cs        # HTTP streaming download
│   ├── TrayIconManager.cs        # System tray context menu
│   ├── ConfigService.cs          # JSON persistence
│   ├── ClipboardManager.cs       # Safe clipboard operations
│   ├── HistoryService.cs         # History persistence
│   └── AudioFeedback.cs          # System beep/asterisk sounds
├── Views/
│   ├── SettingsWindow.xaml       # Settings UI (WPF window)
│   └── DownloadProgressWindow.xaml # Model download progress UI
├── DiktaWindows.csproj           # C# project file
└── VERIFY.md                     # Testing checklist
```

### Dependencies

- **Whisper.net** (1.9.0) — Speech-to-text transcription engine
- **NAudio** (2.2.1) — Audio recording and playback
- **.NET 8** — Framework and runtime

### Running Tests

```bash
dotnet test
```

### Code Style

- Follow C# naming conventions (PascalCase for classes and methods, camelCase for variables)
- Keep methods focused and under 20 lines where practical
- Use meaningful names over comments

## Contributing

When making changes:
1. Build and test locally: `dotnet build && dotnet test`
2. Verify the checklist in `VERIFY.md` passes
3. Commit with a clear message describing the change

## License

Dikta is proprietary software. See `LICENSE` for details.

## Support

For issues, feature requests, or feedback:
- Check the troubleshooting section above
- Review `VERIFY.md` for known limitations and test coverage
- Open an issue or contact the development team

---

**Dikta v1.1** — Made offline, kept simple.
