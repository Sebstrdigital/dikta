# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Dua Talk is a minimal, fully offline dictation application that transcribes speech to clipboard using a global hotkey. It uses Whisper for speech-to-text and runs as a macOS menu bar app.

## Development Commands

```bash
# Install dependencies (recommended)
uv sync
source .venv/bin/activate

# Alternative: pip install
pip install -e .

# Run the app
python dua_talk.py

# Run with LLM cleanup (requires Ollama)
python dua_talk.py --cleanup

# Run with different Whisper model
python dua_talk.py --whisper-model small.en
```

## Prerequisites

For basic dictation, no external services are required.

For LLM cleanup feature, Ollama must be running locally:
```bash
ollama pull gemma3
```

## Architecture

The application follows a simple pipeline:

```
Hotkey → Recording → Whisper STT → (optional LLM cleanup) → Auto-paste + History
```

### Key Components

- **dua_talk.py**: Main application with menu bar and global hotkey
  - `ConfigManager`: Persistent settings stored in `~/Library/Application Support/Dua Talk/config.json`
  - Menu bar integration via `rumps`
  - Global hotkey detection via `pynput`
  - Audio recording via `sounddevice`
  - Speech-to-text via Whisper
  - Optional text cleanup via Ollama
  - Auto-paste via simulated Cmd+V (preserves original clipboard)
  - History menu with last 5 dictations

### Audio Feedback

- **350 Hz beep**: Recording started
- **280 Hz beep**: Recording stopped, text pasted

## CLI Arguments

- `--cleanup`: Use LLM to clean transcription (remove fillers, fix punctuation)
- `--model`: Ollama model for cleanup (default: gemma3)
- `--whisper-model`: Whisper model size (default: base.en)

## Hotkey Modes

### Toggle Mode (default)
- Press hotkey → start recording
- Press hotkey again → stop recording and paste

### Push-to-Talk Mode
- Hold hotkey → recording
- Release hotkey → stop recording and paste

Default hotkeys:
- **Toggle**: Shift+Ctrl
- **Push-to-Talk**: Cmd+Shift

Hotkeys can be customized via Settings menu.

## Menu Structure

```
🎤 Dua Talk
├── Start Recording
├── ────
├── History >
│   ├── "Last dictation preview..."
│   └── (up to 5 items)
├── ────
├── Cleanup: Off
├── Settings >
│   ├── Toggle Mode ✓
│   ├── Push-to-Talk Mode
│   ├── ────
│   ├── Set Toggle Hotkey... (⇧⌃)
│   └── Set Push-to-Talk Hotkey... (⌘⇧)
├── ────
└── Quit
```

## Configuration

Settings are persisted in `~/Library/Application Support/Dua Talk/config.json`:

```json
{
  "version": 1,
  "hotkeys": {
    "toggle": {"modifiers": ["shift", "ctrl"], "key": null},
    "push_to_talk": {"modifiers": ["cmd", "shift"], "key": null}
  },
  "active_mode": "toggle",
  "history": [],
  "cleanup_enabled": false,
  "whisper_model": "base.en",
  "llm_model": "gemma3"
}
```

## Building the macOS App Bundle

The app can be packaged as a standalone macOS menu bar application using py2app.

### Install Build Dependencies

```bash
# Note: py2app 0.28.9+ has compatibility issues with newer setuptools
uv pip install "py2app>=0.28.0,<0.28.9" "setuptools>=69.0.0,<80"
# or
pip install "py2app>=0.28.0,<0.28.9" "setuptools>=69.0.0,<80"
```

### Build Commands

```bash
# Development build (alias mode, fast, uses system Python)
python setup.py py2app -A

# Production build (standalone, includes all dependencies)
python setup.py py2app
```

The built app will be at `dist/Dua Talk.app`.

### Running the App

```bash
# Open the built app
open "dist/Dua Talk.app"

# Or run directly for development
python dua_talk.py
```

### Menu Bar Features

- **Icon states**: 🎤 (idle), 🔴 (recording), ⏳ (processing)
- **Menu**: Start/Stop Recording, History, Settings, Toggle Cleanup, Quit
- **Hotkey**: Configurable via Settings menu
- **Notifications**: macOS notifications for status updates

## macOS Permissions

The app requires these permissions:
- **Microphone**: For recording audio (System Preferences → Privacy & Security → Microphone)
- **Accessibility**: For global hotkey detection and auto-paste (System Preferences → Privacy & Security → Accessibility)

Add Terminal/IDE during development, or Dua Talk.app after building.

**Note**: Auto-paste (Cmd+V simulation) requires the app to be code-signed for full functionality when built as a .app bundle.
