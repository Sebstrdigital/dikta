# Dikta TODO

Scope note (2026-09-28): Dikta stays a macOS tool. Linux/Omarchy is covered by Voxtype (Parakeet v3), no Dikta work planned there. The Python cross-platform port is parked on branch `feat/python-port-foundation` (see `tasks/plan-python-cross-platform.md`); revive only if the Windows port needs replacing.

## Deferred from v1.5 (2026-09-28)

- [ ] Remove the Whisper engines (WhisperKit, KB-Whisper) in favour of Parakeet — decided 2026-09-29, timing open; wait for Swedish WER evidence from diagnostic logs first.
- [ ] XCTSkip for `DebriefRealTranscriptTests` when local sessions are too short. Without it the release test gate blocks releases unless `DIKTA_REAL_SESSIONS_DIR` is set.
- [ ] Startup fallback when a persisted Parakeet engine fails to load (today only live switches fall back).
- [ ] Merge Parakeet's per-word segments before Me/Them interleaving in Call Debrief.
- [ ] Doc wording: FluidAudio itself runs on macOS 14, only Redux needs 15.
- [ ] Unsupported-language routing when a Parakeet engine is explicitly selected (Parakeet v3 covers 25 languages, Dikta offers 12; decide behaviour for the gap).
- [ ] Streaming transcription spike (FluidAudio streaming API) for lower stop-to-paste latency.
- [ ] `MicMutingTests` presses the real mute; needs a fake or a skip on developer machines.

## Call Debrief quality (v1.4, still open)

- [ ] Verify on 2–3 real 30–60 min Slack/Teams calls: DEBRIEF_LIVE stop-to-summary seconds, chunk boundary quality, rolling-summary drift, whether prompt continuation should be on.
- [ ] Summary misattribution: owner sometimes assigned to the other attendee; meeting bookings filed as decisions; due dates paraphrased or invented. Levers: deterministic relative-date resolver, more real recordings.
- [ ] Foundation Models context overflow on ~10 min Swedish calls (consolidation skipped, raw state pasted). Measure prompt/state/chunk token sizes with diagnostic logging on.
- [ ] Mic clipping check (me.wav peak 1.000 on a WhatsApp call); revisit sensitivity presets.
- [ ] Diarization spike (FluidAudio / sherpa-onnx) once the above is stable.

## UX Improvements

- [ ] Processing cancel: let user press hotkey again during processing to abort

## Features

- [ ] Export history to file (markdown or plain text)
- [ ] Customizable history length (currently hardcoded to 5)
- [ ] Per-document-type formatter follow-up (see `docs/formatter-spec.md`)

## Hygiene (low priority)

- [ ] Paste off MainActor; `DiktaCore` target split; XCTest guard as init param
- [ ] `DIKTA_REAL_SESSIONS_DIR` is inert under `xcodebuild test` (no shared .xcscheme)
- [ ] WhisperKit logs "Not enough free disk space" with 59 GB free
- [ ] `dikta-python/` legacy directory still tracked; remove or archive

## Done

- [x] Post-meeting debrief mode — shipped v1.4 (PR #21), 2026-09-17
- [x] Meeting note-taker for Slack / Teams / Zoom — shipped as Call Debrief v1.4 (PR #22, local process tap, Me/Them), 2026-09-18
- [x] Silent "Them" track (missing `NSAudioCaptureUsageDescription`) — fixed 1.4.1, shipped in v1.5
- [x] Parakeet engine switch (Redux / v3 / Ultra) — shipped v1.5, 2026-09-28
