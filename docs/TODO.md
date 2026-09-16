# Dikta TODO

## UX Improvements

- [ ] Processing cancel: let user press hotkey again during processing to abort

## Features

- [ ] Export history to file (markdown or plain text)
- [ ] Customizable history length (currently hardcoded to 5)

## Ideas (2026-09-16, from a real business use case)

- [ ] **Post-meeting debrief mode.** Dictate live or import an audio file recorded right after an offline meeting; transcribe long-form audio and then produce a summary, action items, decisions and open questions. Offline processing matters (secure sites). Depends on: long-audio transcription (WhisperKit chunking), a "meeting notes" document type in the formatter, and the open LLM question (Apple Foundation Models vs a bundled small model).
- [ ] **Meeting note-taker for Slack / Teams / Zoom.** Either capture the call audio locally (ScreenCaptureKit / CoreAudio process tap, speaker separation via a diarization model) or join as a bot participant. Local capture keeps the offline and private promise; bot participation is far heavier. Investigate before choosing.
