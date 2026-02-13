# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Dua Talk is a minimal, fully offline dictation application that transcribes speech to clipboard using a global hotkey. It uses Whisper for speech-to-text and runs as a macOS menu bar app.

This repository contains two implementations:
- **python/**: Python implementation using rumps, pynput, and Whisper
- **DuaTalk/**: Native Swift/SwiftUI implementation

## Python Development Commands

```bash
cd python

# Install dependencies (recommended)
uv sync
source .venv/bin/activate

# Alternative: pip install
pip install -e .

# Run the app
python dua_talk.py

# Run with different Whisper model
python dua_talk.py --whisper-model small.en
```

## Swift Development

```bash
cd DuaTalk

# Build with Swift Package Manager
swift build

# Or open in Xcode
open DuaTalk.xcodeproj
```

### Release Build (xcodebuild)

When building outside Xcode, the WhisperKit dependency's `swift-transformers_Hub.bundle` gets `com.apple.FinderInfo` extended attributes that cause code signing to fail with "resource fork, Finder information, or similar detritus not allowed". The workaround is to copy the `.app` to `/tmp`, strip xattrs, then sign:

```bash
cd DuaTalk

# Build
xcodebuild clean build -project DuaTalk.xcodeproj -scheme DuaTalk \
    -configuration Release -derivedDataPath build/derived -quiet

# Copy to /tmp, strip xattrs, sign
cp -R "build/derived/Build/Products/Release/Dua Talk.app" "/tmp/Dua Talk.app"
xattr -cr "/tmp/Dua Talk.app"
codesign --force --deep --sign "Developer ID Application: Sebastian Strandberg (UUM29335B4)" "/tmp/Dua Talk.app"
```

Or use the full release script which handles signing, notarization, and DMG creation:
```bash
./scripts/build-release.sh
```

## Prerequisites

For basic dictation (Raw mode), no external services are required.

For enhanced output modes (General, Code Prompt), Ollama must be running locally:
```bash
ollama pull gemma3
```

For text-to-speech (Read Aloud feature), Piper TTS must be installed:
```bash
brew install piper
# Download a voice model (e.g., en_US-lessac-medium) from github.com/rhasspy/piper
```

## Architecture

The application follows a simple pipeline:

```
Hotkey → Recording → Whisper STT → Output Mode Formatting → Auto-paste + History
```

### Key Components (Python)

- **python/dua_talk.py**: Main application with menu bar and global hotkey
  - `ConfigManager`: Persistent settings stored in `~/Library/Application Support/Dua Talk/config.json`
  - `OutputMode`: Defines available output modes (Raw, General, Code Prompt)
  - Menu bar integration via `rumps`
  - Global hotkey detection via `pynput`
  - Audio recording via `sounddevice`
  - Speech-to-text via Whisper
  - Mode-specific text formatting via Ollama (optional)
  - Auto-paste via simulated Cmd+V (preserves original clipboard)
  - History menu with last 5 dictations

### Audio Feedback

- **350 Hz beep**: Recording started
- **280 Hz beep**: Recording stopped, text pasted

## CLI Arguments

- `--model`: Ollama model for LLM formatting (default: gemma3)
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
- **Read Aloud (TTS)**: Cmd+Alt

Hotkeys can be customized via Settings menu.

## Text-to-Speech (Read Aloud)

Select text in any application, press the TTS hotkey (Cmd+Alt by default), and the text will be read aloud using Piper TTS.

**Requirements:**
- Piper TTS installed (`brew install piper`)
- A voice model downloaded (e.g., `en_US-lessac-medium.onnx`)

Voice models should be placed in `~/.local/share/piper-voices/` or `~/piper-voices/`.

## Output Modes

The app supports three output modes for dictation formatting:

| Mode | Requires Ollama | Description |
|------|-----------------|-------------|
| **Raw** | No | Verbatim Whisper transcription (default fallback) |
| **General** | Yes (gemma3) | Clean up fillers, fix punctuation, natural prose |
| **Code Prompt** | Yes (gemma3) | Structured prompts for AI coding assistants |

**Default behavior:**
- If Ollama available: defaults to **General** mode
- If Ollama unavailable: shows notification and falls back to **Raw** mode

### Example Transformations

**General Mode:**
- Raw: "um so I was thinking that we should probably you know schedule a meeting"
- Output: "I was thinking we should schedule a meeting."

**Code Prompt Mode:**
- Raw: "um so I need you to create a function that uh validates email addresses"
- Output: "Create a function that validates email addresses..."

## Menu Structure

```
🎤 Dua Talk
├── Start Recording
├── ────
├── History >
│   ├── "Last dictation preview..."
│   └── (up to 5 items)
├── ────
├── Mode: General >
│   ├── Raw
│   ├── General ✓
│   └── Code Prompt
├── Settings >
│   ├── Toggle Mode ✓
│   ├── Push-to-Talk Mode
│   ├── ────
│   ├── Set Toggle Hotkey... (⇧⌃)
│   ├── Set Push-to-Talk Hotkey... (⌘⇧)
│   ├── ────
│   └── Set Read Aloud Hotkey... (⌘⌥)
├── ────
└── Quit
```

## Configuration

Settings are persisted in `~/Library/Application Support/Dua Talk/config.json`:

```json
{
  "version": 2,
  "hotkeys": {
    "toggle": {"modifiers": ["shift", "ctrl"], "key": null},
    "push_to_talk": {"modifiers": ["cmd", "shift"], "key": null},
    "text_to_speech": {"modifiers": ["cmd", "alt"], "key": null}
  },
  "active_mode": "toggle",
  "output_mode": "general",
  "history": [
    {
      "text": "Hello world",
      "timestamp": "2024-01-15T10:30:00Z",
      "output_mode": "general"
    }
  ],
  "whisper_model": "base.en",
  "llm_model": "gemma3"
}
```

## Building the macOS App Bundle (Python)

The Python app can be packaged as a standalone macOS menu bar application using py2app.

### Install Build Dependencies

```bash
cd python

# Note: py2app 0.28.9+ has compatibility issues with newer setuptools
uv pip install "py2app>=0.28.0,<0.28.9" "setuptools>=69.0.0,<80"
# or
pip install "py2app>=0.28.0,<0.28.9" "setuptools>=69.0.0,<80"
```

### Build Commands

```bash
cd python

# Development build (alias mode, fast, uses system Python)
python setup.py py2app -A

# Production build (standalone, includes all dependencies)
python setup.py py2app
```

The built app will be at `python/dist/Dua Talk.app`.

### Running the App

```bash
cd python

# Open the built app
open "dist/Dua Talk.app"

# Or run directly for development
python dua_talk.py
```

### Menu Bar Features

- **Icon states**: 🎤 (idle), 🔴 (recording), ⏳ (processing), 🔊 (speaking)
- **Menu**: Start/Stop Recording, History, Output Mode, Settings, Quit
- **Hotkey**: Configurable via Settings menu
- **Notifications**: macOS notifications for status updates

## macOS Permissions

The app requires these permissions:
- **Microphone**: For recording audio (System Preferences → Privacy & Security → Microphone)
- **Accessibility**: For global hotkey detection and auto-paste (System Preferences → Privacy & Security → Accessibility)

Add Terminal/IDE during development, or Dua Talk.app after building.

**Note**: Auto-paste (Cmd+V simulation) requires the app to be code-signed for full functionality when built as a .app bundle.
