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
Hotkey (Shift+Ctrl) → Recording → Whisper STT → (optional LLM cleanup) → Clipboard
```

### Key Components

- **dua_talk.py**: Main application with menu bar and global hotkey
  - Menu bar integration via `rumps`
  - Global hotkey detection via `pynput`
  - Audio recording via `sounddevice`
  - Speech-to-text via Whisper
  - Optional text cleanup via Ollama
  - Clipboard integration via `pbcopy`
  - Audio feedback (beeps) for user feedback

### Audio Feedback

- **350 Hz beep**: Recording started
- **280 Hz beep**: Recording stopped, clipboard ready

## CLI Arguments

- `--cleanup`: Use LLM to clean transcription (remove fillers, fix punctuation)
- `--model`: Ollama model for cleanup (default: gemma3)
- `--whisper-model`: Whisper model size (default: base.en)

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
- **Menu**: Start/Stop Recording, Toggle Cleanup, Quit
- **Hotkey**: Shift+Ctrl still works for hands-free operation
- **Notifications**: macOS notifications for status updates

## macOS Permissions

The app requires these permissions:
- **Microphone**: For recording audio (System Preferences → Privacy & Security → Microphone)
- **Accessibility**: For global hotkey detection (System Preferences → Privacy & Security → Accessibility)

Add Terminal/IDE during development, or Dua Talk.app after building.
