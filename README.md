# Dua Talk

A minimal, fully offline dictation tool that runs as a macOS menu bar app. Transcribes speech to clipboard using a global hotkey and optionally formats output with a local LLM.

## Implementations

This repository contains two implementations:
- **python/**: Python implementation using rumps, pynput, and Whisper
- **DuaTalk/**: Native Swift/SwiftUI implementation

## Features

- **Fully Offline**: Uses Whisper for speech-to-text, no cloud services required
- **Menu Bar App**: Runs unobtrusively in your macOS menu bar
- **Global Hotkey**: Toggle or push-to-talk recording from anywhere
- **Output Modes**: Raw transcription, general cleanup, or code prompt formatting
- **Auto-paste**: Automatically pastes transcription after recording
- **History**: Access your last 5 dictations from the menu
- **Audio Feedback**: Beeps indicate recording start/stop

## Python Installation

### Using uv (Recommended)

```bash
# Install uv if you haven't already
curl -LsSf https://astral.sh/uv/install.sh | sh
# or on macOS: brew install uv

# Clone and setup
git clone https://github.com/vndee/local-talking-llm.git
cd local-talking-llm/python

# Install dependencies and activate
uv sync
source .venv/bin/activate
```

### Using pip

```bash
git clone https://github.com/vndee/local-talking-llm.git
cd local-talking-llm/python

python -m venv .venv
source .venv/bin/activate
pip install -e .
```

## Running the Python App

```bash
cd python

# Activate the virtual environment
source .venv/bin/activate

# Run the app
python dua_talk.py

# Run with a different Whisper model
python dua_talk.py --whisper-model small.en
```

## Swift Installation

```bash
cd DuaTalk

# Build with Swift Package Manager
swift build

# Or open in Xcode
open DuaTalk.xcodeproj
```

## macOS Permissions

The app requires these permissions in **System Preferences → Privacy & Security**:

- **Microphone**: For recording audio
- **Accessibility**: For global hotkey detection and auto-paste

Add your terminal application during development. After building as an app bundle, add `Dua Talk.app`.

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

For General and Code Prompt modes, install Ollama:

```bash
ollama pull gemma3
```

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
Ensure Accessibility permissions are granted to your terminal or the built app.

### LLM modes not working
Check that Ollama is running and the model is available:

```bash
ollama list
ollama pull gemma3
```

## Resources

- [Whisper](https://github.com/openai/whisper) - OpenAI's speech recognition model
- [Ollama](https://ollama.ai) - Run LLMs locally
