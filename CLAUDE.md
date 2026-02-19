# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Dua Talk is a minimal, fully offline dictation app for macOS (v0.1). It transcribes speech to clipboard using a global hotkey, running as a menu bar app. No cloud services required.

The primary implementation is **DuaTalk/** (native Swift/SwiftUI). A legacy Python implementation exists in **python/**.

## Swift Development

```bash
cd DuaTalk

# Build and run
swift build
.build/debug/DuaTalk

# Or open in Xcode
open DuaTalk.xcodeproj
```

### Release Build

The full release script handles archiving, signing, bundling the Whisper model, notarization, and DMG creation:

```bash
./scripts/build-release.sh
```

Output: `DuaTalk/build/DuaTalk.dmg`

**Important build note**: The re-signing step after bundling the Whisper model must pass `--entitlements` or they get stripped. This is handled in the script.

## Architecture

```
Hotkey → Recording → WhisperKit STT → Auto-paste + History
```

### Key Files (Swift)

- **Models/**
  - `AppConfig.swift` — Full config structure, persisted as JSON
  - `HotkeyConfig.swift` — Modifier keys (shift, ctrl, cmd, alt, fn), hotkey matching logic
  - `WhisperModel.swift` — Available models: small, medium
  - `Language.swift` — Supported languages: English, Swedish
- **Services/**
  - `HotkeyManager.swift` — CGEventTap-based global hotkey detection (flagsChanged + keyDown/keyUp)
  - `ConfigService.swift` — Singleton config manager, persists to `~/Library/Application Support/Dua Talk/config.json`
  - `TextToSpeechService.swift` — Kokoro TTS integration via local Python server
  - `TextSelectionService.swift` — Gets selected text via Accessibility API
  - `ClipboardManager.swift` — Clipboard operations and auto-paste (Cmd+V simulation)
- **ViewModels/**
  - `MenuBarViewModel.swift` — Main app state machine (idle/loading/recording/processing/speaking), delegates hotkey events
- **Views/**
  - `MenuBarView.swift` — Menu structure: Settings, Advanced, History
  - `OnboardingWindow.swift` — Setup screen with permission checks, TTS install, version display
  - `HotkeyRecordingWindow.swift` — Hotkey capture UI

### Hotkey Detection

Uses `CGEvent.tapCreate` listening for `keyDown`, `keyUp`, and `flagsChanged` events. Modifier-only hotkeys (e.g., Shift+Ctrl) are detected via `flagsChanged`. The fn/Globe key uses `.maskSecondaryFn`.

`HotkeyConfig.matchesModifiers()` does **strict matching** — all modifiers in `ModifierKey.allCases` must match exactly (required pressed, non-required not pressed).

### Config

Persisted at `~/Library/Application Support/Dua Talk/config.json`. Key fields: `hotkeys` (toggle, push_to_talk, text_to_speech), `active_mode`, `whisper_model`, `language`.

## Hotkey Modes

- **Toggle** (default): Press hotkey to start, press again to stop
- **Push-to-Talk**: Hold hotkey to record, release to stop
- **Read Aloud**: Press hotkey to read selected text via TTS

Default hotkeys: Toggle = Shift+Ctrl, PTT = Cmd+Shift, TTS = Cmd+Alt. All customizable via Settings menu.

## Text-to-Speech

Kokoro TTS is set up from the onboarding window (Setup... in menu bar). Creates a Python venv at `~/Library/Application Support/Dua Talk/venv` and installs kokoro + dependencies.

## Menu Structure

```
Dua Talk
├── Stop Recording / Stop Speaking / Processing...
├── History >
├── Settings >
│   ├── Toggle Mode / Push-to-Talk Mode
│   ├── Set Toggle Hotkey... / Set Push-to-Talk Hotkey...
│   └── Set Read Aloud Hotkey...
├── Advanced >
│   ├── Language: English / Svenska
│   ├── Whisper Model: Small / Medium
│   └── Voice: (Kokoro voices)
├── Setup...
└── Quit
```

## macOS Permissions

- **Microphone** — for recording (entitlement: `com.apple.security.device.audio-input`)
- **Accessibility** — for global hotkeys and auto-paste

## Python Implementation (Legacy)

```bash
cd python
uv sync && source .venv/bin/activate
python dua_talk.py
```

Not actively developed. See `python/` for details.
