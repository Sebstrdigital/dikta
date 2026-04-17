# Changelog

All notable changes to Dikta will be documented in this file.

- 2026-04-17: DiagnosticLogger (Windows) now correctly gated behind `[Conditional("DIAGNOSTICS")]` compile flag — release builds produce no log output

## [1.2] - 2026-03-31

### Features
- **Deterministic text formatter** — format dictated text with Cmd+Shift+F. Six-zone message extraction (greeting, opening pleasantry, body, closing pleasantry, sign-off, name) with automatic paragraph splitting and list detection
- **Embedding-based paragraph splitting (experimental)** — bundled MiniLM-L12-v2 (33MB CoreML model) detects semantic topic shifts in dictated messages using sentence embeddings and depth-score thresholding. Supplements heuristic transition-word detection for unmarked topic changes (e.g. work discussion → personal questions)
- **Language-aware model fallback** — embedding-based splitting used for English, Spanish, French, German, Portuguese, Italian, Dutch; heuristic-only fallback for Finnish, Norwegian, Danish, Indonesian, Swedish
- **Lazy model loading** — embedding model loads on first format hotkey press, not at app startup

### Fixes
- Greeting punctuation preserved — "Hello, Reino!" no longer becomes "Hello Reino,"
- Removed spurious markdown headings (## So, Some) from paragraph-split output
- FormatterTests.swift registered in Xcode test target — 215 tests now run (was 68)

### Tests
- 215 unit tests (129 formatter + 12 embedding splitter + 6 regression + 68 existing)

## [1.1] - 2026-03-27

### Features
- **12 languages** — added Spanish, French, German, Portuguese, Italian, Dutch, Finnish, Norwegian, and Danish alongside the existing English, Swedish, and Indonesian
- **Enable/disable languages** — each language in the Write In menu can be toggled on or off; only enabled languages appear in the hotkey carousel
- Language selection is a preference hint for Whisper — it improves accuracy when languages could be ambiguous (e.g. Norwegian vs Danish, Portuguese vs Spanish). Whisper always transcribes what it hears; the selector guides detection rather than restricting it.

## [1.0.2] - 2026-03-14

### Features
- Diagnostic logging feature flag — off by default, toggle in Advanced menu
- Auto-update toggle moved to About screen for better discoverability

### Fixes
- Sparkle XPC entitlements preserved during code signing — fixes "Update Error" when installing updates
- Appcast uses marketing version for version comparison — fixes "up to date" false positive
- Build script handles re-releases of same version tag

## [1.0.1] - 2026-03-14

### Fixes
- SparkleController init passes delegate via constructor (fixes build error with Sparkle 2.x)
- EdDSA public key set in Info.plist (replaces placeholder)

## [1.0] - 2026-03-14

### Features
- Auto-update via Sparkle 2.x — app checks for updates silently on launch; standard Sparkle dialog shown when new version is available
- "Check for Updates..." in Advanced menu — manual update check on demand
- "Automatically Check for Updates" toggle — opt out of launch-time checks
- Update Available badge — persistent "Update Available (vX.Y)" indicator at top of menu bar menu; disappears after install or skip
- Release pipeline automation — `build-release.sh` now generates `appcast.xml` with EdDSA signature, creates GitHub Release, and deploys to GitHub Pages in one command

## [0.6] - 2026-03-13

### Fixes
- Strip [BLANK_AUDIO] tokens before no_speech check — fixes false positive "No Speech" errors (11 confirmed false positives over 48h)
- Diagnostic file logger added for investigating transcription issues

## [0.5] - 2026-03-07

### Reliability
- Long-form transcription (30–120s) now works reliably — relaxed compressionRatioThreshold from 2.4 to 3.0
- Bluetooth headset retry with backoff (300/500/800ms) for HFP profile switching
- AVAudioConverter recreated on audio route changes mid-recording instead of silently dropping frames
- AVAudioConverter lifecycle fix — stored as instance property, explicitly released on stop to prevent memory leak
- Thread safety — audioConverter access synchronized with bufferLock across tap closure, config change handler, and stopRecording
- Segment-level diagnostic logging (text, avgLogprob, compressionRatio, noSpeechProb)
- Memory footprint logging before/after each transcription

### Features
- Mic Sensitivity replaces Mic Distance — simplified to Normal / Headset (removed Close preset)
- Smart segment filtering — valid text segments kept even when mixed with silence/empty segments
- Error notifications (No Speech, Transcription Timeout) always shown even when notifications are muted

### Fixes
- AVAudioConverter errors now logged instead of silently discarded
- Build script updated — Whisper model path moved out of iCloud-synced Documents folder

## [0.4] - 2026-02-26

### Features
- Menu bar language indicator — shows current language code (EN/SV/ID) next to the menu bar icon
- Start at Login toggle in Advanced menu
- Hotkey collision detection — warns when two modes share the same hotkey
- Silence auto-stop trims trailing silence before sending to Whisper for cleaner results

### Stability
- Audio feedback thread safety — engine health check now runs inside the lock-protected region
- TTS process lifecycle — checks `isRunning` before termination, reaps child processes, removes observers in `deinit`
- Safe Accessibility API casting — prevents crashes from unexpected CoreFoundation types
- Async Bluetooth audio route handling — non-blocking wait for HFP profile switch
- Audio buffer hard limit (5 minutes) — prevents unbounded memory growth on very long recordings
- HotkeyConfig `Hashable` conformance consistent with order-independent equality
- Atomic config file writes to prevent corruption on crash

### Improvements
- Model loading uses indeterminate spinner instead of fake percentage
- "No Speech" notification title changed from "Error" to "No Speech"
- Transcription timeout prevents stuck processing state
- LlamaSwift dependency removed (unused LLM pipeline cleanup)
- Unit tests for HotkeyConfig, AppConfig, and UpdateChecker (27 tests)

## [0.3] - 2026-02-26

### Features
- Mic Distance setting (Close / Normal / Far) — configurable speech detection sensitivity to fix "No Speech" with AirPods and headsets
- Language hotkey (Cmd+Ctrl) — cycle between languages without opening the menu
- Indonesian language support
- Menu restructured: Hotkeys, Audio, Write in, Advanced sections
- "Setup..." renamed to "About"

### Fixes
- Speech detection thresholds now dynamic instead of hardcoded (was causing false "No Speech" at normal distance)

## [0.2] - 2026-02-20

### Features
- Mute Notifications toggle in Advanced menu — suppresses routine notifications (Ready, Pasted, No Speech, etc.) while keeping error/important ones
- Mute Sounds and Mute Notifications are independent toggles

### Fixes
- AirPods Pro microphone not detected — AudioRecorder now retries when Bluetooth HFP profile switch causes a zero-sample-rate format
- AudioRecorder observes `AVAudioEngineConfigurationChange` during recording for better Bluetooth device handling
- TTS onboarding: green checkmark now only appears after the server is actually responding, not just after files are installed
- TTS error messages now distinguish "not set up" from "server still starting" when pressing the Read Aloud hotkey
- Accessibility and Microphone permission status now auto-updates in the onboarding window (polls every 5 seconds)
- Get Started button disabled while TTS installation is in progress

## [0.1] - 2026-02-19

Initial release (as "Dua Talk", renamed to "Dikta" in v0.2).

### Features
- Offline speech-to-text using WhisperKit (Small and Medium models)
- Menu bar app with global hotkey support
- Toggle mode and Push-to-Talk mode
- fn/Globe key support as hotkey modifier
- Auto-paste transcription to active app
- Text-to-Speech (Read Aloud) via Kokoro TTS
- Dictation history (last 5 items)
- Multi-language support (English, Swedish)
- Customizable hotkeys, Whisper model, TTS voice
- Onboarding setup screen with permission checks and version display
- Signed, notarized, and stapled DMG for distribution
