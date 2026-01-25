# Local Dictation Tool

A minimal, fully offline dictation tool that transcribes speech to clipboard using a global hotkey. A local alternative to Wispr Flow.

## Features

- **Fully Offline**: Uses Whisper for speech-to-text, no cloud services required
- **Global Hotkey**: Toggle recording with Left Shift + Left Control from anywhere
- **Audio Feedback**: Distinct beeps for start, stop, and ready states
- **Clipboard Integration**: Transcription automatically copied to clipboard
- **Optional LLM Cleanup**: Clean up transcription using Ollama (remove fillers, fix punctuation)

## Architecture

```
Left Shift + Left Control (start) → [beep] → Recording...
Left Shift + Left Control (stop)  → [beep] → Whisper STT → (optional LLM cleanup) → Clipboard → [double beep]
```

## Installation

### Using uv (Recommended)

```bash
# Install uv if you haven't already
curl -LsSf https://astral.sh/uv/install.sh | sh
# or on macOS: brew install uv

# Clone the repository
git clone https://github.com/vndee/local-talking-llm.git
cd local-talking-llm
git checkout feature/dictation-tool

# Install dependencies
uv sync

# Activate the virtual environment
source .venv/bin/activate  # On Windows: .venv\Scripts\activate
```

### Using pip

```bash
git clone https://github.com/vndee/local-talking-llm.git
cd local-talking-llm
git checkout feature/dictation-tool

python -m venv venv
source venv/bin/activate
pip install -e .
```

## macOS Permissions

On macOS, you need to grant Accessibility permissions for the global hotkey to work:

1. Go to **System Preferences → Privacy & Security → Accessibility**
2. Add your terminal application (Terminal.app, iTerm, or your IDE)
3. Restart the dictation tool

## Usage

### Basic Usage

```bash
python dictation.py
```

Press **Left Shift + Left Control** to start recording, speak, then press the same hotkey again to stop. Your transcription will be copied to the clipboard.

### Audio Feedback

- **Start recording**: High-pitched beep (600 Hz)
- **Stop recording**: Lower beep (400 Hz) - processing
- **Clipboard ready**: Double beep (800 Hz) - ready to paste

### With LLM Cleanup

Enable LLM cleanup to remove filler words and fix punctuation (requires [Ollama](https://ollama.ai)):

```bash
# Install Ollama and pull a model
ollama pull gemma3

# Run with cleanup enabled
python dictation.py --cleanup
```

### Configuration Options

```bash
python dictation.py --help
```

- `--cleanup`: Use LLM to clean transcription (remove fillers, fix punctuation)
- `--model`: Ollama model for cleanup (default: gemma3)
- `--whisper-model`: Whisper model size (default: base.en)

### Whisper Model Options

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| `tiny.en` | 39M | Fastest | Good |
| `base.en` | 74M | Fast | Better (default) |
| `small.en` | 244M | Medium | Great |
| `medium.en` | 769M | Slow | Excellent |

```bash
# Use a smaller model for faster transcription
python dictation.py --whisper-model tiny.en

# Use a larger model for better accuracy
python dictation.py --whisper-model small.en
```

## Workflow Example

1. Start the dictation tool: `python dictation.py`
2. Open any text field (email, document, chat)
3. Press **Left Shift + Left Control** → hear start beep
4. Speak your text
5. Press **Left Shift + Left Control** → hear stop beep
6. Wait for double beep (transcription ready)
7. Press **Cmd+V** (Mac) or **Ctrl+V** (Windows/Linux) to paste

## Troubleshooting

### Hotkey not working on macOS

Make sure you've granted Accessibility permissions to your terminal. The app needs to listen for global keyboard events.

### Microphone not detected

Check that your microphone is:
- Connected and powered on
- Selected as the default input device in system settings
- Not being used exclusively by another application

### LLM cleanup not working

Ensure Ollama is running and the model is available:

```bash
ollama list  # Check available models
ollama pull gemma3  # Pull the model if missing
```

## Original Voice Assistant

This tool is a fork of the full voice assistant. The original implementation with LLM conversation and ChatterBox TTS is preserved in the `main` branch.

## Resources

- [Whisper](https://github.com/openai/whisper) - OpenAI's speech recognition model
- [Ollama](https://ollama.ai) - Run LLMs locally
- [pynput](https://pynput.readthedocs.io/) - Global hotkey detection
