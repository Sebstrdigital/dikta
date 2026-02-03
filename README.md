# Dua Talk

A minimal, fully offline dictation tool that runs as a macOS menu bar app. Transcribes speech to clipboard using a global hotkey and optionally formats output with a local LLM.

## Quick Start (Swift - Recommended)

```bash
# Clone the repo
git clone https://github.com/duadigital/dua-talk.git
cd dua-talk/DuaTalk

# Build and run
swift build
.build/debug/DuaTalk
```

The app will appear in your menu bar (🎤). First run will download the Whisper model.

**Required permissions** (macOS will prompt you):
- **Microphone** - for recording
- **Accessibility** - for hotkeys (System Settings → Privacy & Security → Accessibility → add Terminal)

**Default hotkey**: `Shift + Ctrl` to start/stop recording.

## Quick Start (Python)

```bash
# Install uv (package manager)
brew install uv

# Clone and setup
git clone https://github.com/duadigital/dua-talk.git
cd dua-talk/python

# Install and run
uv sync
source .venv/bin/activate
python dua_talk.py
```

## Features

- **Fully Offline**: Uses Whisper for speech-to-text, no cloud services required
- **Menu Bar App**: Runs unobtrusively in your macOS menu bar
- **Global Hotkey**: Toggle or push-to-talk recording from anywhere
- **Output Modes**: Raw transcription, general cleanup, or code prompt formatting
- **Auto-paste**: Automatically pastes transcription after recording
- **History**: Access your last 5 dictations from the menu
- **Audio Feedback**: Sounds indicate recording start/stop

## Implementations

This repository contains two implementations:
- **DuaTalk/**: Native Swift/SwiftUI implementation (recommended)
- **python/**: Python implementation using rumps, pynput, and Whisper

## macOS Permissions

The app requires these permissions in **System Settings → Privacy & Security**:

| Permission | Why | How to Grant |
|------------|-----|--------------|
| **Microphone** | Recording audio | macOS will prompt on first use |
| **Accessibility** | Global hotkeys + auto-paste | Manually add Terminal (or the .app) in System Settings |

**Important**: After granting Accessibility permission, you may need to restart the app.

## Hotkey Modes

| Mode | Default Hotkey | Behavior |
|------|----------------|----------|
| **Toggle** | Shift + Ctrl | Press to start, press again to stop |
| **Push-to-Talk** | Cmd + Shift | Hold to record, release to stop |

Hotkeys can be customized via the Settings menu.

## Output Modes

| Mode | Requires Ollama | Description |
|------|-----------------|-------------|
| **Raw** | No | Verbatim Whisper transcription |
| **General** | Yes | Removes fillers, fixes punctuation |
| **Code Prompt** | Yes | Formats as prompts for AI coding assistants |

For General and Code Prompt modes, install Ollama first:

```bash
# Install Ollama (https://ollama.ai)
brew install ollama

# Start the Ollama service
ollama serve &

# Pull the required model
ollama pull gemma3
```

The app will automatically detect if Ollama is available and fall back to Raw mode if not.

## CLI Options

```bash
python dua_talk.py --help
```

- `--model`: Ollama model for LLM formatting (default: gemma3)
- `--whisper-model`: Whisper model size (default: base.en)

### Whisper Model Options

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| `tiny.en` | 39M | Fastest | Good |
| `base.en` | 74M | Fast | Better (default) |
| `small.en` | 244M | Medium | Great |
| `medium.en` | 769M | Slow | Excellent |

## Building the macOS App (Python)

```bash
cd python

# Install build dependencies
uv pip install "py2app>=0.28.0,<0.28.9" "setuptools>=69.0.0,<80"

# Build standalone app
python setup.py py2app

# Run the built app
open "dist/Dua Talk.app"
```

## Troubleshooting

### Hotkey not working
1. Check Accessibility permission: System Settings → Privacy & Security → Accessibility
2. Add Terminal (or the app) to the list
3. Restart the app after granting permission

### No audio / Microphone not working
1. Check Microphone permission: System Settings → Privacy & Security → Microphone
2. Ensure your mic is selected as input device in System Settings → Sound

### LLM modes not working (General/Code Prompt)
```bash
# Check if Ollama is running
ollama list

# If not running, start it
ollama serve &

# Pull the model if missing
ollama pull gemma3
```

### App won't start / Build fails
```bash
# Clean and rebuild (Swift)
cd DuaTalk
rm -rf .build
swift build

# For Python, recreate venv
cd python
rm -rf .venv
uv sync
```

## Resources

- [Whisper](https://github.com/openai/whisper) - OpenAI's speech recognition model
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) - Swift implementation used by the native app
- [Ollama](https://ollama.ai) - Run LLMs locally
