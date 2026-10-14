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

### Dictation reliability and long recordings (reported 2026-10-14; deferred)

Planning/investigation only. No implementation, new release, or publishing authorized by these entries.

- [ ] Investigate missing recording-start sound. User reports recording starts without its cue. `MenuBarViewModel` requests `beepOn()` after recorder startup; inspect cue scheduling, feedback-engine readiness/recovery, output-route changes, and interaction with microphone startup. Reproduce with isolated tests and a separately authorized live check; do not assume a cause or silently restart the user's app. Recent targeted audio-error lookup returned no matches, which is not proof of healthy playback. Acceptance: identify the cause and verify an audible, timely cue across repeated starts and relevant route changes.
- [ ] Review recording-stop sound semantics. User reports a 1–2 second delay after clicking Stop. Normal dictation currently requests `beepOff()` after transcription completes, not at recording stop. Decide whether to provide immediate recording-stopped feedback and a distinct completion cue; avoid presenting completion latency as continued recording.
- [ ] Design long dictation without a user-visible fixed duration cutoff, including hour-long sessions. Current normal-dictation buffer auto-processes at 4,800,000 samples (five minutes at 16 kHz); diagnostics show a recording on 2026-10-14 from 08:41:13 to 08:46:13 reaching exactly that cap, but its identity was not confirmed against transcript content. Prefer bounded RAM and disk-backed capture over simply raising the in-memory cap. Evaluate continuous disk capture plus chunked transcription, including reuse of existing debrief streaming/chunking components without inheriting summarization or call-mode behavior. User suggestion: roughly five-minute files with a few seconds of overlap; treat chunk size and overlap as design candidates, not settled requirements. Overlap can come from one continuous capture stream rather than separate microphone recorders. Ensure no gaps or duplicated words at boundaries, correct ordering and one coherent final dictation/paste after explicit Stop. Compare transcription during capture versus after Stop for responsiveness and resource contention. Define temporary-audio privacy/cleanup, disk-full and transcription-failure recovery, cancellation, and any exceptional safety limits. Preserve offline operation; clarify silence auto-stop behavior separately rather than silently changing it. Acceptance: synthetic/public-fixture long-session tests prove bounded memory, boundary correctness, ordered final text, and safe failure handling; live hour-long qualification requires separate permission. No automatic five-minute recording stop in the proposed user experience.

- [ ] Processing cancel: let user press hotkey again during processing to abort

## Features

- [ ] Release follow-up: diagnose the Read Aloud crash reported while reading a Markdown table on the 1.5.7 preview (2026-10-12). Exact captured input and cause are unconfirmed; successful later wrapper tests do not prove the crash fixed. Resolve before recommending another release; crash-report/private-data access requires explicit permission.
- [ ] Read Aloud selection support in Neovim (reported 2026-10-12): user observes selected text does not appear to reach the clipboard for Read Aloud. Defer investigation and improvement; selection mode, terminal environment, clipboard integration, and cause are unconfirmed. Do not assume the existing pi terminal-selection issue has the same cause. No implementation authorized.
- [ ] Export history to file (markdown or plain text)
- [ ] Customizable history length (currently hardcoded to 5)

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
