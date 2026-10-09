# Dikta

A minimal, fully offline dictation app for macOS. Press a hotkey, speak, and your words are pasted instantly. No cloud services, no subscriptions.

Requires macOS 15 or later on Apple Silicon.

## Install

Download the latest DMG from [Releases](https://github.com/Sebstrdigital/dikta/releases), drag to Applications, and launch. The About window opens automatically and guides you through permissions.

## Features

- **Fully Offline** — speech-to-text runs locally on your Mac. No data ever leaves your device.
- **One automatic transcription experience** — NVIDIA Parakeet Ultra via FluidAudio handles dictation, imported audio, mic Debrief, and call Debrief without an engine, model, or language picker.
- **Menu Bar App** — sits quietly in your menu bar, always one hotkey away
- **Four Hotkey Modes** — Record (toggle), Push-to-Talk, Read Aloud, and Format Selection — all customizable
- **fn/Globe Key Support** — use the fn/Globe key as a hotkey modifier
- **Auto-paste** — transcription goes straight to your cursor via Cmd+V simulation
- **Silence Auto-Stop** — recording stops automatically after 10 seconds of silence
- **Formatting** — select pasted text and press the Format hotkey to turn a run-on dictation into paragraphs, greetings and lists, deterministically and offline
- **Call Debrief** — record a call (your mic plus the audio you hear), get a Me/Them transcript and a rolling summary with decisions, action items and open questions. Summaries come from Apple's on-device Foundation Models, a local Ollama model, or a built-in heuristic, never a cloud service.
- **Debrief mode** — the same summary pipeline for a single microphone recording or an audio file you drop in
- **Text-to-Speech** — select text and have it read aloud via Kokoro TTS (optional, installed separately)
- **History** — access your last 5 dictations from the menu bar
- **Automatic European-language transcription** — Ultra detects its language from audio without a hint. Formatting infers supported language behavior from the selected text; Debrief infers English or Swedish from its transcript and falls back to English when uncertain. Indonesian is not supported.
- **Mic Sensitivity** — tune speech detection sensitivity for Normal or Headset use
- **Launch at Login** — optionally start Dikta automatically when you log in
- **Auto-Update** — checks for updates via Sparkle; configure in the About screen

## Transcription

Dikta uses **Parakeet Ultra** (~615 MB) for every speech-to-text path. The model downloads on first use and remains in FluidAudio's cache. It supports automatic European-language transcription; there is no manual language hint. Mixed-language code-switching is best-effort: qualification found that short English contributions can disappear in otherwise Swedish takes. Benchmark numbers and methodology remain in `docs/review-2026-09/parakeet-bench.md`.

## Permissions

The About window checks these for you on first launch:

| Permission | Why | How |
|------------|-----|-----|
| **Microphone** | Record audio | Click "Grant" on the About screen |
| **Accessibility** | Global hotkeys (CGEventTap), auto-paste, and muting the mic in call apps while you dictate | System Settings > Privacy & Security > Accessibility |
| **System Audio Recording** | Call Debrief only: capture the audio you hear on a call | macOS prompts the first time you start a call recording |

Note: **Input Monitoring** is NOT required — Dikta uses CGEventTap which falls under Accessibility, not the separate Input Monitoring permission.

## Hotkeys

All hotkeys are customizable via **Hotkeys** in the menu bar. Collision detection warns you if two modes share the same hotkey.

| Mode | Default | Behavior |
|------|---------|----------|
| **Record** | Shift + Ctrl | Press to start, press again to stop |
| **Push-to-Talk** | Cmd + Shift | Hold to record, release to stop |
| **Read Aloud** | Cmd + Alt | Reads selected text aloud via TTS |
| **Format Selection** | Cmd + Shift + F | Reformats the selected text into paragraphs and lists |

While you dictate, Dikta mutes your microphone in Teams, Slack, WhatsApp, Google Meet and Uven if one of them is in a call, and unmutes it when you stop.

## Menu Structure

```
Dikta
├── Stop Recording / Stop Speaking / Processing... / Loading model...
├── History >
├── Hotkeys >
│   ├── Set Record Hotkey...
│   ├── Set Push-to-Talk Hotkey...
│   ├── Set Read Aloud Hotkey...
│   └── Set Format Selection Hotkey...
├── Audio >
│   ├── Mute Sounds
│   ├── Mute Notifications
│   └── Mic Sensitivity: Normal / Headset
├── Debrief >
│   ├── Debrief mode
│   ├── Source: Microphone / Microphone + system audio
│   ├── Load audio file…
│   ├── Engine: Auto / Foundation Models / Ollama / Heuristic
│   └── Open Dikta folder
├── Advanced >
│   ├── Start at Login
│   ├── Check for Updates...
│   ├── Diagnostic Logging
│   └── Voice: (Kokoro TTS voices)
├── About
└── Quit
```

## Call Debrief

Enable **Debrief → Debrief mode**, set **Source** to *Microphone + system audio*, and press the Record hotkey during a call. Dikta records two tracks (you and the other party), transcribes them in five-minute chunks while the call runs, and pastes a summary when you stop. Recordings, transcripts and summaries stay in `~/Documents/Dikta`; nothing is uploaded. macOS shows a System Audio Recording prompt the first time; if the other party's track comes back silent, Dikta warns you after 20 seconds.

## Mic Sensitivity

If you get "No Speech" errors with AirPods or Bluetooth headsets, switch to **Headset** under Audio > Mic Sensitivity:

| Setting | Use when | Thresholds |
|---------|----------|------------|
| **Normal** | Built-in mic, desk mic | Balanced |
| **Headset** | AirPods, Bluetooth headsets | Permissive |

## Text-to-Speech

Select text in any app and press the Read Aloud hotkey. Set up the TTS engine from the About window — it downloads Kokoro TTS into a local Python venv automatically. Requires Python 3 installed on your system.

## Building from Source

```bash
cd dikta-macos
swift build
.build/debug/Dikta
```

Or open in Xcode:

```bash
open dikta-macos/Dikta.xcodeproj
```

Run the tests through Xcode (the test host is the app bundle, which the model-loading tests need):

```bash
cd dikta-macos
xcodebuild test -project Dikta.xcodeproj -scheme Dikta -only-testing:DiktaTests -destination 'platform=macOS'
```

`swift test` also works and skips the tests that need the app bundle.

### Release Build

```bash
cd dikta-macos
./scripts/build-release.sh --no-publish   # DMG only, for a smoke test
./scripts/build-release.sh                # DMG + GitHub release + appcast
```

This runs the unit tests (and refuses to continue if any fail or none ran), archives, signs, notarizes with Apple, and produces a DMG at `build/Dikta.dmg`. Requires a Developer ID certificate and notarization credentials (see script header for setup).

### Benchmarks

`dikta-macos/bench/` holds a small harness that scores any Whisper or Parakeet model on 20 FLEURS clips per language:

```bash
cd dikta-macos/bench
./run.sh                                         # Whisper Small, sv + en
./run.sh parakeet v3 parakeet redux              # Parakeet variants
```

## Troubleshooting

**Hotkey not working** — Check that the app is listed in System Settings > Privacy & Security > Accessibility. Restart after granting.

**"No Speech" notifications** — Try switching to **Headset** in the Audio > Mic Sensitivity menu. Also ensure the correct input device is selected in System Settings > Sound > Input before recording.

**Text-to-speech not working** — Open the About window and click "Set Up" next to Text-to-Speech. Requires Python 3 (`/usr/bin/python3` or Homebrew).

**Model loading is slow** — Ultra downloads and Core ML may compile on first use; the menu shows download progress. Subsequent launches are fast because the model stays cached.

**Quality seems to drift during a long session** — Turn on **Advanced → Diagnostic Logging**; every take then logs which engine and model handled it, its confidence, and the app's memory use to `~/Library/Logs/Dikta/dikta-diagnostic.log`.

**Call Debrief's "Them" track is silent** — Grant System Audio Recording when prompted (System Settings > Privacy & Security > Screen & System Audio Recording) and restart the call recording.

**App won't start** — Clean and rebuild: `cd dikta-macos && rm -rf .build && swift build`

## Architecture

```
Hotkey → Recording → Parakeet Ultra → Auto-paste + History
                  └→ Call Debrief: two-track capture → chunked transcription → rolling summary
```

Key source files:

- `Models/AppConfig.swift` — Full config structure, persisted as JSON at `~/Library/Application Support/Dikta/config.json`
- `Models/TranscriptionEngineKind.swift` — Inactive compatibility values for legacy saved engine preferences
- `Models/HotkeyConfig.swift` — Modifier keys, hotkey matching, collision detection
- `Models/MicSensitivity.swift` — Speech detection sensitivity presets
- `Services/TranscriptionEngine.swift` / `Services/ParakeetEngine.swift` — Testable engine seam and the fixed Ultra implementation
- `Services/HotkeyManager.swift` — CGEventTap-based global hotkey detection
- `Services/ConfigService.swift` — Singleton config manager with atomic writes
- `Services/AudioRecorder.swift` — AVAudioEngine recording with silence auto-stop
- `Services/SystemAudioTapRecorder.swift` — Core Audio process tap for the call's far side
- `Services/Debrief/` — Chunked transcription, two-track merge, summarizers (Foundation Models, Ollama, heuristic), rolling summary
- `Formatter/` — Deterministic text formatter behind the Format hotkey
- `MicMuting/` — Mutes the mic in call apps while you dictate
- `ViewModels/MenuBarViewModel.swift` — Main app state machine (idle/loading/recording/processing/speaking)
- `Views/OnboardingWindow.swift` — About/setup screen with permissions, TTS install, launch at login

More detail in `docs/architecture.md`; test rules per area in `docs/validation.md`.

## Resources

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — Retained only by benchmark/probe tooling for comparisons
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet models as Core ML, in Swift
- [Parakeet TDT 0.6B](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) — NVIDIA model family used through FluidAudio
- [Kokoro TTS](https://github.com/hexgrad/kokoro) — Text-to-speech engine

## License

[MIT License](LICENSE)
