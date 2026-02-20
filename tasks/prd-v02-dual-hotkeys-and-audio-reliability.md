# PRD: Dua Talk v0.2 — Dual Hotkeys & Audio Reliability

## Introduction

Two changes for Dua Talk v0.2: (1) Remove the mutually exclusive hotkey mode selector and make both Toggle and Push-to-Talk hotkeys active simultaneously, and (2) fix audio feedback sounds silently dying after extended app runtime, plus add a mute option.

## Goals

- Both Toggle and Push-to-Talk hotkeys work simultaneously without requiring the user to pick a mode
- Audio feedback sounds remain reliable for the entire lifetime of the app, surviving audio device changes, sleep/wake, and `coreaudiod` resets
- Users can mute feedback sounds from the menu

## User Stories

### US-001: Always-on dual dictation hotkeys

**Description:** As a user, I want both my Toggle hotkey and Push-to-Talk hotkey to work at the same time so that I don't have to switch modes before dictating.

**Acceptance Criteria:**
- [ ] Both Toggle (default: Shift+Ctrl) and Push-to-Talk (default: Cmd+Shift) hotkeys are active simultaneously — pressing either one starts recording with its respective behavior (toggle = press to start/stop, PTT = hold to record)
- [ ] If already recording via one mode, pressing the other dictation hotkey is ignored — only the mode that started the recording can stop it
- [ ] The mode radio buttons ("Toggle Mode" / "Push-to-Talk Mode") are removed from the Settings menu; the three hotkey configuration buttons remain

### US-002: Resilient audio feedback engine

**Description:** As a user, I want recording start/stop sounds to keep working no matter how long the app has been running, so that I always get audible confirmation of my actions.

**Acceptance Criteria:**
- [ ] `AudioFeedback` observes `AVAudioEngineConfigurationChange` and automatically restarts the engine when macOS reconfigures audio (device changes, sleep/wake)
- [ ] Before each sound play, `audioEngine.isRunning` is checked; if stopped, the engine is restarted transparently
- [ ] Shared mutable state between the audio render thread and the main thread is synchronized (no data races on `isPlaying`, `samplesPlayed`, etc.)

### US-003: Mute feedback sounds

**Description:** As a user, I want to be able to mute the dictation feedback sounds from the menu, so I can use the app silently when I prefer.

**Acceptance Criteria:**
- [ ] A "Mute Sounds" toggle appears in the Advanced menu, persisted in config
- [ ] When muted, `beepOn()` and `beepOff()` return immediately without playing
- [ ] Default is unmuted (sounds on) for new installs and existing configs without the field

### US-004: Remove `activeMode` from config and clean up references

**Description:** As a developer, I want the `activeMode` field removed from the config model and all code paths that reference it, so there is no dead code around mode switching.

**Acceptance Criteria:**
- [ ] `activeMode` removed from `AppConfig`, `ConfigService.activeHotkeyMode`, and `ConfigService.activeHotkey`
- [ ] `HotkeyManager.updateConfig()` accepts both toggle and PTT configs instead of a single config + mode
- [ ] Old configs missing `activeMode` load without error (backward-compatible JSON decoding)

## Functional Requirements

- FR-1: `HotkeyManager` must track two independent dictation hotkey configs (`toggleConfig` + `pttConfig`) with separate `isActive` state for each, in addition to the existing TTS hotkey
- FR-2: In `handleModifierEvent()` and `handleKeyEvent()`, both dictation hotkeys must be checked independently (same pattern as existing TTS hotkey check)
- FR-3: `HotkeyManagerDelegate.hotkeyPressed()` must convey which mode triggered (toggle or PTT) — either via a parameter or separate delegate methods
- FR-4: `MenuBarViewModel` must track which mode initiated the current recording (`activeRecordingMode: HotkeyMode?`) and only allow that mode to stop it
- FR-5: `AudioFeedback` must observe `Notification.Name.AVAudioEngineConfigurationChange` on its engine and call `setupAudioEngine()` to rebuild when fired
- FR-6: `AudioFeedback.playBubble()` must check `audioEngine?.isRunning == true` before playing; if not running, call a restart method first
- FR-7: Shared audio state (`isPlaying`, `samplesPlayed`, `samplesToPlay`, `phase`, `startFrequency`, `endFrequency`, `attackSamples`, `decaySamples`) must be synchronized between the render thread callback and `playBubble()` — use `os_unfair_lock` or equivalent
- FR-8: Add `muteSounds: Bool` field to `AppConfig` (default `false`), persisted in JSON as `"mute_sounds"`
- FR-9: `beepOn()` and `beepOff()` must early-return when `muteSounds` is true (read from `ConfigService`)
- FR-10: `SettingsMenu` must remove the Toggle Mode / Push-to-Talk Mode radio buttons
- FR-11: `AdvancedMenu` must add a "Mute Sounds" toggle item with checkmark state
- FR-12: When the audio engine is restarted (FR-5/FR-6), log via `AppLogger.audio` so issues are diagnosable

## Non-Goals

- No enable/disable toggles per individual hotkey mode — both are always on
- No changes to TTS hotkey behavior — it continues working exactly as today
- No changes to the synthesized sound frequencies, durations, or waveforms
- No migration from procedural audio to sound files
- No consolidation of `AudioFeedback` and `AudioRecorder` into a shared `AVAudioEngine`
- No UI beyond a menu toggle for mute — no volume slider, no sound picker

## Technical Considerations

- `HotkeyManager` already demonstrates concurrent hotkey handling with the TTS hotkey — the dual dictation pattern follows the same approach
- The `AVAudioSourceNode` render callback runs on a real-time audio thread — synchronization must use `os_unfair_lock` (not `DispatchQueue` or `NSLock`) to avoid priority inversion
- `AppConfig` version should bump to 3 to reflect the schema change (removed `activeMode`, added `muteSounds`); JSON decoding must handle version 2 configs gracefully
- The `activeRecordingMode` tracking in `MenuBarViewModel` prevents conflicting stop signals — this is a small addition (~10 lines)

## Success Metrics

- Zero user-reported instances of feedback sounds stopping during extended sessions
- Users never need to think about "which mode am I in" — both hotkeys just work
- No regressions in hotkey detection reliability or recording quality

## Open Questions

None — scope is fully defined.
