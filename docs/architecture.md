# Dikta Architecture

## Pipeline

```
Hotkey → Recording → WhisperKit STT → Auto-paste + History
```

## Key Files (Swift)

- **Models/**
  - `AppConfig.swift` — Full config structure, persisted as JSON
  - `HotkeyConfig.swift` — Modifier keys (shift, ctrl, cmd, alt, fn), hotkey matching logic
  - `WhisperModel.swift` — Available models: small, medium, plus KB-Whisper Small (`kbWhisperSmall`), a Swedish-tuned model that is never user-selectable — `MenuBarViewModel.effectiveModel(for:)` auto-selects it whenever the active language is Svenska, overriding the user's own model preference, and releases back to it for every other language
  - `MicDistance.swift` — Close/Normal/Far presets for speech detection sensitivity
  - `Language.swift` — Supported languages: English, Swedish, Indonesian
- **Services/**
  - `HotkeyManager.swift` — CGEventTap-based global hotkey detection (flagsChanged + keyDown/keyUp)
  - `ConfigService.swift` — Singleton config manager, persists to `~/Library/Application Support/Dikta/config.json`
  - `TranscriptionEngine.swift` — Protocol both STT backends conform to (see Transcription Engine below)
  - `Transcriber.swift` — WhisperKit-backed `TranscriptionEngine`
  - `ParakeetEngine.swift` — FluidAudio-backed `TranscriptionEngine`, one of the three Parakeet variants
  - `UpdateChecker.swift` — Checks GitHub releases for newer versions
  - `TextToSpeechService.swift` — Kokoro TTS integration via local Python server
  - `TextSelectionService.swift` — Gets selected text via Accessibility API
  - `ClipboardManager.swift` — Clipboard operations and auto-paste (Cmd+V simulation)
- **ViewModels/**
  - `MenuBarViewModel.swift` — Main app state machine (idle/loading/recording/processing/speaking), delegates hotkey events
- **Views/**
  - `MenuBarView.swift` — Menu structure: Hotkeys, Audio, Write in, Advanced
  - `OnboardingWindow.swift` — About window with permission checks, TTS install, version display, update checker
  - `HotkeyRecordingWindow.swift` — Hotkey capture UI

## Hotkey Detection

Uses `CGEvent.tapCreate` listening for `keyDown`, `keyUp`, and `flagsChanged` events. Modifier-only hotkeys (e.g., Shift+Ctrl) detected via `flagsChanged`. fn/Globe key uses `.maskSecondaryFn`.

`HotkeyConfig.matchesModifiers()` does **strict matching** — all modifiers in `ModifierKey.allCases` must match exactly.

## Hotkey Modes

- **Toggle** (default): Press to start, press again to stop
- **Push-to-Talk**: Hold to record, release to stop
- **Read Aloud**: Press to read selected text via TTS
- **Language Toggle**: Press to cycle between languages

Default hotkeys: Toggle = Shift+Ctrl, PTT = Cmd+Shift, TTS = Cmd+Alt, Language = Cmd+Ctrl.

## Config

Persisted at `~/Library/Application Support/Dikta/config.json`.

Key fields: `hotkeys` (toggle, push_to_talk, text_to_speech, language_toggle), `whisper_model`, `language`, `mic_distance`, `mute_sounds`, `mute_notifications`.

## Menu Structure

```
Dikta
├── Stop Recording / Stop Speaking / Processing...
├── History >
├── Hotkeys >
│   ├── Set Record Hotkey...
│   ├── Set Push-to-Talk Hotkey...
│   ├── Set Read Aloud Hotkey...
│   └── Set Language Toggle Hotkey...
├── Audio >
│   ├── Mute Sounds
│   ├── Mute Notifications
│   └── Mic Distance: Close / Normal / Far
├── Write in: (language) >
│   ├── English
│   ├── Svenska
│   └── Bahasa Indonesia
├── Debrief >
│   ├── Debrief mode
│   ├── Source >
│   │   ├── Microphone
│   │   └── Microphone + system audio (one-time consent notice on first selection)
│   ├── Load audio file…
│   ├── Engine >
│   │   ├── Auto
│   │   ├── Apple Intelligence (macOS 26)
│   │   ├── Ollama (local)
│   │   └── Heuristic
│   └── Open Dikta folder
├── Advanced >
│   ├── Engine: Whisper / Parakeet Redux / Parakeet v3 (Recommended) / Parakeet Ultra
│   ├── Whisper Model: Small / Medium (KB-Whisper Small hidden — auto-selected for Svenska, see below;
│   │   disabled while a Parakeet engine is active — see Transcription Engine below)
│   └── Voice: (Kokoro voices)
├── About
└── Quit
```

## Swedish Auto-Select (KB-Whisper)

Whenever the active language (`ConfigService.language`) is Svenska, the transcription
engine loads KB-Whisper Small instead of the user's chosen Whisper Model preference —
its Swedish WER is far better than the general models', but it must never be used for
any other language, where its WER is far worse. This is computed by
`MenuBarViewModel.effectiveModel(for:)` and is separate from the persisted preference
(`ConfigService.whisperModel`): picking a different model in the Whisper Model submenu
while Svenska is active updates the preference but keeps KB-Whisper loaded, and the
submenu shows a disabled row explaining this. Switching away from Svenska reloads back
to the preference automatically. KB-Whisper Small is never offered as a manual choice
(`WhisperModel.isUserSelectable == false`).

## Transcription Engine

Dictation transcribes through one of two backends, both conforming to the `TranscriptionEngine`
protocol (`Services/TranscriptionEngine.swift`) so `MenuBarViewModel` depends on that abstraction
rather than on either backend directly:

- **`Transcriber`** — WhisperKit-backed. The only kind before this feature, and the only one the
  Whisper Model submenu applies to.
- **`ParakeetEngine`** — FluidAudio-backed. One instance transcribes one fixed variant; switching
  variants means swapping which `ParakeetEngine` instance is active, not reloading one instance.
  `ParakeetEngine` never talks to FluidAudio's `AsrModels`/`AsrManager` directly — it goes through
  its own `ParakeetBackend` seam, so tests substitute `FakeParakeetBackend` and never download or
  load a real model under XCTest.

**Kinds** (`Models/TranscriptionEngineKind.swift`, `TranscriptionEngineKind: String, CaseIterable`):
`.whisper` (default), `.parakeetRedux` (`"parakeet-redux"`), `.parakeetV3` (`"parakeet-v3"`),
`.parakeetUltra` (`"parakeet-ultra"`). `usesWhisperModelSubmenu` is `true` only for `.whisper` — the
Whisper Model submenu is disabled while any Parakeet kind is active, since each Parakeet variant is
its own fixed model with no size choice.

**Factory.** `MenuBarViewModel` holds one `engineFactory: (TranscriptionEngineKind, WhisperModel) ->
any TranscriptionEngine` — the single seam both the startup engine and every later
`setEngine(_:)` call go through. Production builds resolve it to `Transcriber(model:)` for
`.whisper` and `ParakeetEngine(kind:)` for the three Parakeet kinds; tests inject a fake factory so
no real model ever loads under XCTest. `setEngine(_:)` builds the new engine, loads it, and only
persists the switch and drops the old engine once the new one reports `isReady`; on failure the
previous (already-loaded) engine is restored and the kind is not persisted — never falls back to a
different kind than the one that was already working. Switching away from Parakeet back to Whisper
while Svenska is the active language re-applies the existing KB-Whisper auto-select rule (see above);
none of the three Parakeet variants beat KB-Whisper on Swedish (see
`docs/review-2026-09/parakeet-bench.md`), so that rule is unchanged by this feature.

**Config key.** Persisted as `engine` in `AppConfig`/`config.json`, decoded from
`TranscriptionEngineKind.rawValue` (e.g. `"parakeet-v3"`). A config saved without an `engine` key, or
with a raw value this build doesn't recognize, falls back to `.whisper` rather than failing to
decode.

**Model cache location.** FluidAudio downloads and caches Parakeet models under
`~/Library/Application Support/FluidAudio/Models/<repo>/` — a sibling of Dikta's own
`~/Library/Application Support/Dikta/config.json`, on the same volume WhisperKit's models and the
free-disk-space check (`Transcriber.defaultFreeDiskSpace`) already use, so both engines agree on
what "enough free space" means.

**macOS 15 floor.** Adding the FluidAudio dependency raised the deployment target from 14.2 to 15.0
(`Package.swift` `platforms`, and `MACOSX_DEPLOYMENT_TARGET` in `Dikta.xcodeproj/project.pbxproj`) —
FluidAudio requires it. This is a floor for the whole app, not only the Parakeet engine.

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

## Shadow Participant (experimental)

A third Debrief source, `DebriefSource.joinMeetingAsParticipant`: Dikta joins a Meet/Teams/Zoom link as a
guest, records the call, and leaves when the hotkey stops it. Off by default; the source only appears in
Debrief → Source (plus the `Shadow host` and `Notetaker name` items) when `DIKTA_EXPERIMENTAL_SHADOW=1` or the
UserDefaults key `experimentalShadowParticipant` is true (`ShadowParticipantFlag`). With the flag off the menu
is the v1.5 menu, and a saved `debrief_source` of this case is ignored (`MenuBarViewModel.isShadowMode`).

Config: `shadow_host` (`wkWebView` | `chrome`, default `wkWebView`), `shadow_display_name` (default
`Dikta · notes (<macOS full name>)`), `shadow_notice_shown` (one-time consent notice). All decode with defaults.

Pieces (`Dikta/Services/Shadow/`):
- `ShadowHost` — browser-backed guest (`WKWebViewShadowHost` off-screen web view, `ChromeShadowHost` installed
  Chromium over CDP). Reports `ShadowEvent`s (join state, active speaker, roster) and `audioProcessIDs`.
- `ShadowPlatform` / `ShadowJoinDriver` — URL table, selectors, join flow. Only Meet has selectors.
- `ShadowSpeakerPoller` + `SpeakerTimelineRecorder` — active speaker to `speakers.jsonl` in the session folder;
  `SpeakerAttributor` names the Them track from it (Debrief/).
- `ShadowDependencies` — the seams `MenuBarViewModel` uses (flag, host factory, tap factory, meeting sheet,
  clipboard); tests replace all of them.

Flow (`MenuBarViewModel.startShadowRecording` / `stopShadowRecording`): hotkey → meeting sheet (clipboard
pre-fill, consent notice with the notetaker name on first use) → host joins, `appState = .recording` at once so
the hotkey can cancel a join → on `.admitted`: session folder, two writers, live session, tap targeted at
`host.audioProcessIDs`, then the mic → stop: host leaves, tap and mic stop, writers close, `runLiveDebrief`
exactly as a call recording. `muteAll()` is never called; push-to-talk is ignored. Stopping before admission or a
`.failed` state returns to idle with no session folder and no debrief.

## macOS Permissions

- **Microphone** — for recording (entitlement: `com.apple.security.device.audio-input`)
- **Accessibility** — for global hotkeys and auto-paste
- **System Audio Recording Only** — for the debrief "Microphone + system audio" source (CoreAudio process tap, deployment target 14.2+). This is an audio-only TCC prompt; it lands under Privacy & Security → "System Audio Recording Only", separate from Screen Recording. macOS shows **no** recording indicator while a tap runs — Dikta's icon/sounds and the one-time in-app consent notice are the only signal the user gets, so the user is responsible for telling call participants. If the permission is missing, the tap still starts and delivers exact zeros, so `MenuBarViewModel` watches the Them track and warns once (`silentSystemAudioMessage`) after `silentSystemAudioWarningSeconds` of digital silence; any non-zero sample switches the watchdog off for the rest of the call. The app is not sandboxed (hardened runtime only), so this requires no entitlement changes.

## Text-to-Speech

Kokoro TTS is set up from the About window. Creates a Python venv at `~/Library/Application Support/Dikta/venv` and installs kokoro + dependencies.

## Release Build Notes

The re-signing step after bundling the Whisper model must pass `--entitlements` or they get stripped. This is handled in `scripts/build-release.sh`.
