# Workbook: US-002 - Resilient audio feedback engine

## Summary
Made `AudioFeedback` resilient to audio hardware changes and eliminated data races between the audio render thread and main thread.

## Changes Made

### File: `DuaTalk/DuaTalk/Services/AudioFeedback.swift`

**1. Thread synchronization with `os_unfair_lock`**
- Added `import os` for access to `os_unfair_lock` APIs.
- Introduced `private var lock = os_unfair_lock()` to protect shared mutable state.
- Shared state fields: `isPlaying`, `samplesPlayed`, `samplesToPlay`, `phase`, `startFrequency`, `endFrequency`, `attackSamples`, `decaySamples`.
- In the `AVAudioSourceNode` render callback: lock, copy all shared state to local variables, unlock, process the full frame buffer using locals, then lock again to write back only the mutated values (`isPlaying`, `samplesPlayed`, `phase`).
- In `playBubble()`: lock before writing all parameters, unlock after.

**2. Engine rebuild mechanism (`rebuildEngine()`)**
- Extracted engine setup into `rebuildEngine()` which handles full teardown (stop engine, disconnect/detach old source node, remove notification observer for old engine) followed by fresh creation of engine and source node.
- Both `init()` and `handleConfigurationChange` call `rebuildEngine()`.

**3. `AVAudioEngineConfigurationChange` observation**
- After building the engine in `rebuildEngine()`, registers for `AVAudioEngineConfigurationChange` on the new engine instance.
- `handleConfigurationChange(_:)` calls `rebuildEngine()` and logs via `AppLogger.audio.info`.
- Observer is properly removed for old engine instances during teardown and in `deinit`.

**4. Health check in `playBubble()`**
- Before the `guard isReady` check, if the engine exists but is not running, logs a warning and calls `rebuildEngine()` to transparently restart.

## Acceptance Criteria Verification

| # | Criterion | Status |
|---|-----------|--------|
| 1 | AudioFeedback observes AVAudioEngineConfigurationChange and rebuilds/restarts the engine | Met - `handleConfigurationChange` registered in `rebuildEngine()`, calls `rebuildEngine()` |
| 2 | playBubble() checks audioEngine.isRunning and restarts transparently; logged via AppLogger.audio | Met - health check at top of `playBubble()` with warning log |
| 3 | Shared mutable state synchronized using os_unfair_lock, no data races | Met - lock protects all shared state in both render callback and `playBubble()` |
| 4 | swift build succeeds | Met - `xcodebuild` BUILD SUCCEEDED |
