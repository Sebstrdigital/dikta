# Dikta TODO

## UX Improvements

- [ ] Processing cancel: let user press hotkey again during processing to abort

## Features

- [ ] Export history to file (markdown or plain text)
- [ ] Customizable history length (currently hardcoded to 5)

## Ideas (2026-09-16, from a real business use case)

- [ ] **Post-meeting debrief mode.** PoC on branch `feat/debrief-mode` (2026-09-17, see `tasks/feature-debrief-mode.md`, probe write-up `docs/review-2026-09/debrief-probe-2026-09-17.md`). Remaining: real recordings from Sebastian, prompt tuning (placeholders, decision/action duplication), MLX comparison, voice framing phrase, document output. Original idea: Dictate live or import an audio file recorded right after an offline meeting; transcribe long-form audio and then produce a summary, action items, decisions and open questions. Offline processing matters (secure sites). Depends on: long-audio transcription (WhisperKit chunking), a "meeting notes" document type in the formatter, and the open LLM question (Apple Foundation Models vs a bundled small model).
- [ ] **Meeting note-taker for Slack / Teams / Zoom.** Either capture the call audio locally (ScreenCaptureKit / CoreAudio process tap, speaker separation via a diarization model) or join as a bot participant. Local capture keeps the offline and private promise; bot participation is far heavier. Investigate before choosing.

## Python port (dikta-py, 2026-09-19)

Foundation + audio-file debrief landed. Follow-ups, roughly in order:

- Chunked transcription + rolling summary for recordings over five minutes (port ChunkedTranscriptionSession / RollingDebriefSummarizer).
- Bundled local LLM: llama-cpp-python + GGUF (Qwen3-4B vs Gemma-3-4B, decide by probe on the real sv/en corpus) so debrief works with no Ollama.
- KB-Whisper CTranslate2 conversion for Swedish (auto-select when language is sv, like macOS).
- Windows: `default_root()` should use the Known Folders Documents path, not `~/Documents`.
- Tray app, hotkeys, paste, live mic debrief (Phase 2 in tasks/plan-python-cross-platform.md).
- Packaging: PyInstaller + Inno Setup (Windows), AppImage (Linux).
- Local ffmpeg on the dev Mac is broken (SIGABRT); tests encode AAC in-process via PyAV instead, so nothing depends on it.
