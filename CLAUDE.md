# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Local Talking LLM is a fully offline voice assistant that combines speech recognition, LLM processing, and text-to-speech synthesis. It operates entirely locally without cloud services or API keys.

## Development Commands

```bash
# Install dependencies (recommended)
uv sync
source .venv/bin/activate

# Alternative: pip install
pip install -e .

# Download required NLTK data
python -c "import nltk; nltk.download('punkt_tab')"

# Run the application
python app.py

# Run with voice cloning
python app.py --voice path/to/voice_sample.wav

# Run with custom settings
python app.py --exaggeration 0.7 --cfg-weight 0.3 --model codellama
```

## Prerequisites

Ollama must be running locally with a model pulled:
```bash
ollama pull gemma3
```

## Architecture

The application follows a three-stage pipeline:

```
User Speech → Whisper (STT) → Ollama LLM → ChatterBox (TTS) → Audio Output
```

### Key Components

- **app.py**: Main application orchestrating the voice assistant loop
  - Records audio via `sounddevice`
  - Transcribes with Whisper (`base.en` model)
  - Gets LLM responses via LangChain + Ollama
  - Synthesizes speech via ChatterBox TTS
  - Includes dynamic emotion analysis that adjusts TTS expressiveness

- **tts.py**: `TextToSpeechService` wrapper around ChatterBox TTS
  - `synthesize()`: Single sentence synthesis
  - `long_form_synthesize()`: Multi-sentence with NLTK tokenization and 250ms silence between sentences
  - Auto-detects device (CUDA/MPS/CPU)
  - Patches `torch.load` for cross-device model loading

### LangChain Setup

Uses modern LCEL syntax with `ChatPromptTemplate`, `OllamaLLM`, and `RunnableWithMessageHistory` for session-aware conversations.

## CLI Arguments

- `--voice`: Audio file path for voice cloning
- `--exaggeration`: Emotion intensity 0.0-1.0 (default: 0.5)
- `--cfg-weight`: Pacing/delivery control 0.0-1.0 (default: 0.5)
- `--model`: Ollama model name (default: gemma3)
- `--save-voice`: Save generated audio to `voices/` directory
