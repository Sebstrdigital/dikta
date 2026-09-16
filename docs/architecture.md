# Dikta Architecture

## Pipeline

```
Hotkey → Recording → WhisperKit STT → Auto-paste + History
```

## Key Files (Swift)

- **Models/**
  - `AppConfig.swift` — Full config structure, persisted as JSON
  - `HotkeyConfig.swift` — Modifier keys (shift, ctrl, cmd, alt, fn), hotkey matching logic
  - `WhisperModel.swift` — Available models: small, medium, plus KB-Whisper Small (`kbWhisperSmall`), a Swedish-tuned model that is never user-selectable — `MenuBarViewModel.effectiveModel(for:)` auto-selects it whenever the active language is Svenska, overriding the user's own model preference, and releases back to it for every other language
  - `MicDistance.swift` — Close/Normal/Far presets for speech detection sensitivity
  - `Language.swift` — Supported languages: English, Swedish, Indonesian
- **Services/**
  - `HotkeyManager.swift` — CGEventTap-based global hotkey detection (flagsChanged + keyDown/keyUp)
  - `ConfigService.swift` — Singleton config manager, persists to `~/Library/Application Support/Dikta/config.json`
  - `UpdateChecker.swift` — Checks GitHub releases for newer versions
  - `TextToSpeechService.swift` — Kokoro TTS integration via local Python server
  - `TextSelectionService.swift` — Gets selected text via Accessibility API
  - `ClipboardManager.swift` — Clipboard operations and auto-paste (Cmd+V simulation)
- **ViewModels/**
  - `MenuBarViewModel.swift` — Main app state machine (idle/loading/recording/processing/speaking), delegates hotkey events
- **Views/**
  - `MenuBarView.swift` — Menu structure: Hotkeys, Audio, Write in, Advanced
  - `OnboardingWindow.swift` — About window with permission checks, TTS install, version display, update checker
  - `HotkeyRecordingWindow.swift` — Hotkey capture UI

## Hotkey Detection

Uses `CGEvent.tapCreate` listening for `keyDown`, `keyUp`, and `flagsChanged` events. Modifier-only hotkeys (e.g., Shift+Ctrl) detected via `flagsChanged`. fn/Globe key uses `.maskSecondaryFn`.

`HotkeyConfig.matchesModifiers()` does **strict matching** — all modifiers in `ModifierKey.allCases` must match exactly.

## Hotkey Modes

- **Toggle** (default): Press to start, press again to stop
- **Push-to-Talk**: Hold to record, release to stop
- **Read Aloud**: Press to read selected text via TTS
- **Language Toggle**: Press to cycle between languages

Default hotkeys: Toggle = Shift+Ctrl, PTT = Cmd+Shift, TTS = Cmd+Alt, Language = Cmd+Ctrl.

## Config

Persisted at `~/Library/Application Support/Dikta/config.json`.

Key fields: `hotkeys` (toggle, push_to_talk, text_to_speech, language_toggle), `whisper_model`, `language`, `mic_distance`, `mute_sounds`, `mute_notifications`.

## Menu Structure

```
Dikta
├── Stop Recording / Stop Speaking / Processing...
├── History >
├── Hotkeys >
│   ├── Set Record Hotkey...
│   ├── Set Push-to-Talk Hotkey...
│   ├── Set Read Aloud Hotkey...
│   └── Set Language Toggle Hotkey...
├── Audio >
│   ├── Mute Sounds
│   ├── Mute Notifications
│   └── Mic Distance: Close / Normal / Far
├── Write in: (language) >
│   ├── English
│   ├── Svenska
│   └── Bahasa Indonesia
├── Advanced >
│   ├── Whisper Model: Small / Medium (KB-Whisper Small hidden — auto-selected for Svenska, see below)
│   └── Voice: (Kokoro voices)
├── About
└── Quit
```

## Swedish Auto-Select (KB-Whisper)

Whenever the active language (`ConfigService.language`) is Svenska, the transcription
engine loads KB-Whisper Small instead of the user's chosen Whisper Model preference —
its Swedish WER is far better than the general models', but it must never be used for
any other language, where its WER is far worse. This is computed by
`MenuBarViewModel.effectiveModel(for:)` and is separate from the persisted preference
(`ConfigService.whisperModel`): picking a different model in the Whisper Model submenu
while Svenska is active updates the preference but keeps KB-Whisper loaded, and the
submenu shows a disabled row explaining this. Switching away from Svenska reloads back
to the preference automatically. KB-Whisper Small is never offered as a manual choice
(`WhisperModel.isUserSelectable == false`).

## macOS Permissions

- **Microphone** — for recording (entitlement: `com.apple.security.device.audio-input`)
- **Accessibility** — for global hotkeys and auto-paste

## Text-to-Speech

Kokoro TTS is set up from the About window. Creates a Python venv at `~/Library/Application Support/Dikta/venv` and installs kokoro + dependencies.

## Release Build Notes

The re-signing step after bundling the Whisper model must pass `--entitlements` or they get stripped. This is handled in `scripts/build-release.sh`.
