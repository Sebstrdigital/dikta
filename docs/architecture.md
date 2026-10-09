# Dikta Architecture

## Pipeline

```
Hotkey → Recording → Parakeet Ultra → Auto-paste + History
                  └→ Debrief → transcript-language inference → summary
```

Every macOS speech-to-text entry point—dictation, imported audio, microphone
Debrief, and two-track call Debrief—uses one `ParakeetEngine` backed by the
pinned FluidAudio Ultra model. Ultra receives no language hint.

## Key Files (Swift)

- **Models/**
  - `AppConfig.swift` — Full persisted config. Legacy engine/model/language
    values remain compatibility data and continue to round-trip.
  - `TranscriptionEngineKind.swift` — Stable legacy engine raw values only.
  - `HotkeyConfig.swift` — Hotkey matching and the four active modes;
    `languageToggle` remains decodable but inactive.
  - `Language.swift` — Compatibility values and formatter capabilities.
- **Services/**
  - `TranscriptionEngine.swift` — Testable speech-to-text protocol.
  - `ParakeetEngine.swift` — The sole production STT implementation, fixed
    to Ultra. `ParakeetBackend` lets tests avoid real model loads.
  - `TranscriptionSupport.swift` — Shared disk-space and transcript cleanup/
    timestamp ordering helpers extracted before Whisper removal.
  - `TextLanguageInference.swift` — Conservative inference from actual text.
  - `HotkeyManager.swift`, `ConfigService.swift`, `ClipboardManager.swift`.
- **ViewModels/**
  - `MenuBarViewModel.swift` — Main app state machine and all STT routing.
- **Views/**
  - `MenuBarView.swift` — Menus without STT engine/model/language controls.
  - `OnboardingWindow.swift` and `HotkeyRecordingWindow.swift`.

## Hotkeys

`HotkeyManager` uses a CGEvent tap for key and modifier events. Active modes
are Record, Push-to-Talk, Read Aloud, and Format Selection. The old language
hotkey remains in decoded config so upgrades preserve data, but it is not
registered, displayed, or considered by collision detection.

## Config compatibility

The app still decodes legacy `engine`, `whisper_model`, `language`,
`enabled_languages`, and `language_toggle` values—including Indonesian and
unknown engine values through the existing fallback—without using them to
choose STT behavior. Unrelated settings and history continue to round-trip.

Tests construct `ConfigService` with temporary files. The isolated validation
scheme also sets `DIKTA_CONFIG_FILE` for the app test host and
`DIKTA_REAL_SESSIONS_DIR` to an empty synthetic directory.

## Menu structure

```
Dikta
├── History
├── Hotkeys: Record / Push-to-Talk / Read Aloud / Format Selection
├── Audio
├── Debrief: mode / source / import / summary engine / folder
├── Advanced: login / updates / diagnostics / TTS voice
├── About
└── Quit
```

## Transcription and automatic language

`MenuBarViewModel` constructs one `ParakeetEngine`; tests inject
`FakeTranscriptionEngine`. Ultra model load/download failures remain visible
through the protocol's readiness, error, and progress state. FluidAudio keeps
its model cache under Application Support; Dikta never deletes old or current
model caches.

Language-sensitive work happens only after text exists:

- Format Selection infers from the selected text. Confident English, Spanish,
  French, German, Portuguese, Italian, and Dutch preserve embedding eligibility;
  Swedish remains heuristic-only. Short, ambiguous, mixed, and unsupported
  text uses heuristic-only splitting.
- Debrief infers English or Swedish from the transcript. Uncertain, mixed, and
  unsupported transcripts fall back to English prompts and rendering.
- Ultra code-switching is best-effort. Public qualification showed that short
  English contributions can disappear in mixed English/Swedish takes; this is
  an accepted limitation, not reliable mixed-language support.

The app target and release archive have no WhisperKit dependency or bundled
Whisper model. The separate benchmark and TimestampProbe products retain
WhisperKit for comparison work.

## Debrief

Debrief mode replaces the dictation path with transcribe → summarize → paste, saving each
run to its own folder under `~/Documents/Dikta` (`DebriefStore`). With **Source = Microphone
+ system audio** the recording becomes a *call recording*, which captures two tracks instead
of one: `MenuBarViewModel.startCallRecording` opens a session folder plus a
`StreamingWavWriter` per track, starts the system-audio capture first (its `start()` is the
TCC permission gate and can block for seconds — starting the mic first would offset the two
tracks by that wait), then the microphone. The mic's converted buffers reach `me.wav` through
`AudioRecorder.onLiveSamples` and the tap's through the capture's delivery queue; both
callbacks only hand the buffer to that track's own serial queue, so the disk write (and its
`fsync`) never runs on an audio thread. Nothing is accumulated in RAM during capture
(`accumulateInMemory == false`), so a call of any length streams to disk and survives a crash.
Stop halts the capture first, then the mic, drains each track's queue and closes both writers.
The record hotkey toggles a call recording; push-to-talk is ignored while one runs.

### Live chunking and the rolling summary

Every debrief — call, mic-only and imported file — runs through one API:
`DebriefPipeline.startLiveSession(tracks:language:micSensitivity:)` returns a
`DebriefLiveSession` that owns a `ChunkedTranscriptionSession` and a `RollingDebriefSummarizer`.
Audio is `append`ed as it is captured, from the same per-track serial queue that writes the WAV,
so the chunker sees each track's buffers in capture order. Roughly every five minutes the chunker
cuts (at silence where it can find it, otherwise a hard cut with overlap ears), transcribes that
chunk in the background *while the recording continues*, and calls back with its per-track
segments; the session merges them (`TwoTrackMerger` for two tracks, plain concatenation for one —
a mic debrief has one speaker and is never labeled) and feeds the text to the rolling summarizer,
which folds each chunk in as a delta over a numbered state that Swift, not the model, owns.

`finish()` closes the final chunk and waits at most `max(pipeline timeout, 120 s)` for the
transcription still in flight — everything earlier was already transcribed during the recording,
which is why a one-hour call's summary is ready about a minute after stop rather than after a
full re-transcription. On timeout the chunks that did complete are summarized anyway and the
reason is recorded on `DebriefResult.issues`. A mic-only debrief uses the same machinery with a
single track, streaming to `audio.wav` as it records (`accumulateInMemory == false`), so a long
mic debrief is crash-safe too.

**Single-chunk bypass.** Anything short enough to be one chunk behaves exactly as it did before
chunking existed. The in-RAM and on-disk entry points (`run(samples:)`, `runTwoTrack(paths:)`)
know the length up front, so a recording at or under `targetChunkSeconds` takes the old
whole-recording path verbatim — one `transcribe` call raced against the configured timeout. A
live session that turns out to have produced one chunk holds that chunk back from the rolling
summarizer entirely and summarizes the full transcript with the single-pass
`DebriefSummarizer`, so a short debrief never spends an extra LLM call. Both paths end in the
same `finishTranscribedDebrief` tail: write transcript, reject silence, normalize and validate
the summary, write it, report it.

`runTwoTrack(paths:)` remains the recovery path for a call whose WAVs are already on disk (a
session the app crashed during, replayed through "Load audio file").

One `DEBRIEF_LIVE` diagnostic line is logged per chunk (index, audio seconds, per-track wall
time, silence-vs-hard cut, padding, errors) and one at finish (chunk count, single-pass vs
rolling, and seconds from stop to summary — the feature's headline metric).

## macOS Permissions

- **Microphone** — for recording (entitlement: `com.apple.security.device.audio-input`)
- **Accessibility** — for global hotkeys and auto-paste
- **System Audio Recording Only** — for the debrief "Microphone + system audio" source (CoreAudio process tap, deployment target 14.2+). This is an audio-only TCC prompt; it lands under Privacy & Security → "System Audio Recording Only", separate from Screen Recording. macOS shows **no** recording indicator while a tap runs — Dikta's icon/sounds and the one-time in-app consent notice are the only signal the user gets, so the user is responsible for telling call participants. If the permission is missing, the tap still starts and delivers exact zeros, so `MenuBarViewModel` watches the Them track and warns once (`silentSystemAudioMessage`) after `silentSystemAudioWarningSeconds` of digital silence; any non-zero sample switches the watchdog off for the rest of the call. The app is not sandboxed (hardened runtime only), so this requires no entitlement changes.

## Text-to-Speech

Kokoro TTS is set up from the About window. Creates a Python venv at `~/Library/Application Support/Dikta/venv` and installs kokoro + dependencies.

## Release Build Notes

Release archives do not bundle Whisper. The release script preserves Sparkle signing order and the packaged Native Kokoro helper while signing the main app with its entitlements.
