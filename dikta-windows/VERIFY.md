# dikta-windows Verification Checklist

Comprehensive verification checklist for testing Dikta Windows v1.1 on Windows 10/11. Each test should take 1–2 minutes.

## Prerequisites

- [ ] Windows 10 (build 19041+) or Windows 11
- [ ] Microphone connected and working
- [ ] .NET 8 SDK installed (`dotnet --version` shows 8.x.x)
- [ ] Whisper model file at `%APPDATA%\Dikta\models\ggml-small.bin` (or triggered download on first run)

## Build & Runtime

- [ ] `dotnet restore` — NuGet packages resolve (Whisper.net 1.9.0, NAudio 2.2.1)
- [ ] `dotnet build -c Release` — zero errors, zero warnings
- [ ] `dotnet publish -c Release -r win-x64 --self-contained true` — publish succeeds
- [ ] Launch published app or `dotnet run` — tray icon appears in system tray
- [ ] Custom Dikta icon visible in tray (not generic application icon)
- [ ] Right-click tray icon — context menu shows History, Settings, Quit options
- [ ] No crash on startup; app runs cleanly in background

## Hotkey (Default: Ctrl+Shift+D)

- [ ] Press Ctrl+Shift+D — recording starts (system beep sound)
- [ ] Tray icon changes appearance to indicate recording state
- [ ] Press Ctrl+Shift+D again — recording stops (asterisk/completion sound)
- [ ] No key-repeat flood when holding the hotkey (MOD_NOREPEAT prevents spam)
- [ ] Hotkey works when any other application is focused (Notepad, browser, etc.)
- [ ] Hotkey does NOT work if app is quit

## Transcription & Clipboard

- [ ] Record a short English phrase ("hello world") — transcription completes within 5 seconds
- [ ] Transcribed text appears in clipboard
- [ ] Text auto-pastes into a Notepad window (Ctrl+V pastes transcribed text)
- [ ] Text auto-pastes into a browser text field
- [ ] Temporary WAV file is cleaned up from `%TEMP%` after transcription
- [ ] No transcription crashes or hangs

## 12 Languages Support

Each language is selectable from the tray menu and settings window. Test each language (under 1 min per language):

- [ ] **English (EN)** — tray menu shows "English", transcribe in English
- [ ] **Swedish (SV)** — tray menu shows "Svenska", transcribe in Swedish
- [ ] **Indonesian (ID)** — tray menu shows "Indonesian", transcribe in Indonesian
- [ ] **Spanish (ES)** — tray menu shows "Español", transcribe in Spanish
- [ ] **French (FR)** — tray menu shows "Français", transcribe in French
- [ ] **German (DE)** — tray menu shows "Deutsch", transcribe in German
- [ ] **Portuguese (PT)** — tray menu shows "Português", transcribe in Portuguese
- [ ] **Italian (IT)** — tray menu shows "Italiano", transcribe in Italian
- [ ] **Dutch (NL)** — tray menu shows "Nederlands", transcribe in Dutch
- [ ] **Finnish (FI)** — tray menu shows "Suomi", transcribe in Finnish
- [ ] **Norwegian (NO)** — tray menu shows "Norsk", transcribe in Norwegian
- [ ] **Danish (DA)** — tray menu shows "Dansk", transcribe in Danish

For each: select from tray menu → Language submenu → verify language name and checkmark → record phrase → verify transcription

## Model Download

- [ ] Delete `%APPDATA%\Dikta\models\ggml-small.bin`
- [ ] Press Ctrl+Shift+D — dialog appears: "Download model now?" with Yes/No buttons
- [ ] Click Yes — DownloadProgressWindow appears showing:
  - [ ] Download percentage (0–100%)
  - [ ] Downloaded size (MB)
  - [ ] Total size (MB)
  - [ ] Cancel button is clickable
- [ ] Download completes (~500 MB for small model, progress reaches 100%)
- [ ] Model file appears at `%APPDATA%\Dikta\models\ggml-small.bin` with correct size
- [ ] First recording after download completes successfully
- [ ] Download errors (e.g., disconnect network mid-download) show error message and allow retry

## Settings Window

Open by right-clicking tray icon → Settings.

### Hotkey Configuration
- [ ] Settings window opens
- [ ] Hotkey section shows dropdown for Modifier (Ctrl, Alt, Shift, Win) and Key (A–Z, 0–9, F1–F12)
- [ ] Current hotkey (Ctrl+Shift+D) is pre-selected
- [ ] Change to Ctrl+Alt+W, click Save
- [ ] Settings window closes
- [ ] New hotkey Ctrl+Alt+W triggers recording (old hotkey no longer works)
- [ ] Pressing hotkey again toggles recording state

### Language Selection
- [ ] Language dropdown in settings shows all 12 languages with native display names
- [ ] Current language (e.g., "English") is pre-selected
- [ ] Select "Español" → Save
- [ ] Tray menu → Language submenu shows "Español" with checkmark
- [ ] Recording uses Spanish transcription

### Model Selection
- [ ] Model dropdown shows "small", "medium", "large" with file sizes
- [ ] Selected model shows "Downloaded" or "Not downloaded" status
- [ ] Selecting a different model and saving triggers download on next record (if not cached)
- [ ] After switching models, recordings use the new model

### Mute Toggle
- [ ] "Mute sounds" checkbox is present
- [ ] Unchecked (default) — hotkey press produces beep, release produces asterisk/completion sound
- [ ] Check "Mute sounds" and Save
- [ ] Hotkey press/release produces no audio feedback
- [ ] Uncheck and Save — audio feedback returns

### Save & Cancel
- [ ] Change multiple settings (hotkey, language, model, mute)
- [ ] Click Cancel without saving
- [ ] Settings window closes; changes are NOT applied (previous values remain in tray menu)
- [ ] Open settings again — original values are still there
- [ ] Change settings again and click Save
- [ ] Settings window closes; changes ARE applied and persist after app restart

## Tray Icon States

- [ ] **Idle state** — tray icon displays standard Dikta icon (non-recording appearance)
- [ ] **Recording state** — tray icon visually changes (different color, overlay, or animation) to indicate active recording
- [ ] **Hover tooltip** — moving mouse over tray icon shows "Dikta — English" (or current language name)
- [ ] Tooltip updates when language is changed in settings

## History

- [ ] Record a phrase ("first test") → text appears in tray menu → History submenu
- [ ] Record a second phrase ("second test") → both items appear in History (newest first)
- [ ] History displays 5 most recent transcriptions
- [ ] Click a history item — text is copied to clipboard and auto-pastes
- [ ] History persists across app restart (stored in `%APPDATA%\Dikta\config.json`)

## Error Cases

### No Microphone
- [ ] Physically disconnect microphone (or mute all audio input in Windows Settings)
- [ ] Press Ctrl+Shift+D — tray balloon notification appears: "No microphone found"
- [ ] App does not crash; remains ready for next hotkey press
- [ ] Reconnect microphone — next hotkey press records successfully

### Corrupt Config File
- [ ] Close app
- [ ] Manually corrupt `%APPDATA%\Dikta\config.json` (e.g., remove closing brace)
- [ ] Restart app — tray icon appears without crash
- [ ] Tray balloon notification: "Settings reset to defaults" or similar
- [ ] Recording with default settings (English, Ctrl+Shift+D) works
- [ ] Config file is repaired with default values

### Transcription Failure
- [ ] Simulate a failure by placing an invalid/empty model file at `%APPDATA%\Dikta\models\ggml-small.bin`
- [ ] Press Ctrl+Shift+D → recording starts → stops
- [ ] Tray balloon notification: "Transcription failed" (or similar error message)
- [ ] App returns to idle state (not stuck in "processing")
- [ ] Next hotkey press works normally

## Configuration Persistence

- [ ] Edit `%APPDATA%\Dikta\config.json` directly to set language to "fr", mute_sounds to true
- [ ] Restart app
- [ ] Tray menu → Language shows "Français" with checkmark
- [ ] Settings window shows Mute toggle checked
- [ ] Hotkey press produces no audio feedback
- [ ] Recording uses French Whisper model

## Audio Feedback

- [ ] Mute unchecked — hotkey press produces audible beep
- [ ] Mute unchecked — release produces audible asterisk/completion tone
- [ ] Audio quality is clear, not distorted
- [ ] Both sounds complete before app finishes initial setup

## Cleanup & Exit

- [ ] Open app, make a recording, close via tray menu → Quit
- [ ] App process exits cleanly (no orphan processes in Task Manager)
- [ ] Temporary WAV file is removed
- [ ] Config and history are saved
- [ ] Restarting app shows same language and history

## Performance & Stability

- [ ] Rapid hotkey presses (5–10 presses in quick succession) do not crash app
- [ ] Long recording (30+ seconds) completes without hang
- [ ] Typing in clipboard target while recording does not interfere with transcription
- [ ] App uses <100 MB RAM at idle, <300 MB while transcribing

## Known Limitations

- [ ] No real-time transcription (only batch mode after release)
- [ ] No push-to-talk — hotkey press starts, second press stops
- [ ] First model download requires internet connection
- [ ] Windows 10 build 19041+ or Windows 11 (no legacy Windows support)

## Verification Complete

Once all tests pass:
- [ ] All checkboxes above are checked
- [ ] No crashes or hang-ups encountered
- [ ] All features work as specified

**Sign off:** Date: _______ Tester: _____________

App is ready for release candidate build.
