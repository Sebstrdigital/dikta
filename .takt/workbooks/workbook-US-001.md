# Workbook: US-001 - Always-on dual dictation hotkeys

## Summary

Refactored the hotkey system so that both Toggle and Push-to-Talk dictation hotkeys are always active simultaneously, eliminating the need to switch modes before dictating.

## Changes Made

### HotkeyManager.swift
- Replaced single `hotkeyConfig` + `hotkeyMode` + `isHotkeyActive` with dual configs: `toggleHotkeyConfig`/`isToggleHotkeyActive` and `pttHotkeyConfig`/`isPttHotkeyActive`
- Updated `updateConfig()` signature to `updateConfig(toggle:pushToTalk:)` accepting both configs
- Updated `HotkeyManagerDelegate` protocol: `hotkeyPressed()` -> `hotkeyPressed(mode:)`, `hotkeyReleased()` -> `hotkeyReleased(mode:)`
- `handleModifierEvent()`: checks toggle hotkey (trigger on press only, no release callback) and PTT hotkey (trigger on press AND release) independently, same pattern as existing TTS hotkey
- `handleKeyEvent()`: same dual-check pattern for key-based hotkeys

### MenuBarViewModel.swift
- Added `private var activeRecordingMode: HotkeyMode? = nil` to track which mode initiated a recording
- `hotkeyPressed(mode:)`: if idle, starts recording and sets activeRecordingMode; if recording and mode is toggle matching activeRecordingMode, stops recording; otherwise ignores
- `hotkeyReleased(mode:)`: only stops recording if mode is .pushToTalk AND activeRecordingMode is .pushToTalk
- `stopRecording()`: resets activeRecordingMode to nil
- `updateHotkeyConfig()`: passes both configs via `hotkeyManager.updateConfig(toggle:pushToTalk:)`
- Removed `setHotkeyMode()` method (no longer needed)
- Updated ready notification to show toggle hotkey instead of `configService.activeHotkey`

### MenuBarView.swift (SettingsMenu)
- Removed Toggle Mode / Push-to-Talk Mode radio buttons (the two Button actions with checkmarks)
- Kept the three hotkey configuration buttons and dividers

### Not Changed (deferred to US-004)
- `activeMode` in AppConfig and ConfigService remains but is no longer used for hotkey routing

## Acceptance Criteria Verification

1. **HotkeyManager tracks two independent configs with separate isActive state** -- PASS. `toggleHotkeyConfig`/`isToggleHotkeyActive` and `pttHotkeyConfig`/`isPttHotkeyActive` checked independently in `handleModifierEvent()` and `handleKeyEvent()`, same pattern as existing TTS hotkey.

2. **Delegate conveys mode via hotkeyPressed(mode:); ViewModel tracks activeRecordingMode** -- PASS. Protocol updated, ViewModel sets `activeRecordingMode` on start and only allows matching mode to stop.

3. **Settings menu no longer shows mode radio buttons; hotkey buttons remain** -- PASS. Removed the two mode selection buttons; three hotkey configuration buttons still present.

4. **swift build succeeds** -- PASS. Verified via `xcodebuild -project DuaTalk.xcodeproj -scheme DuaTalk -configuration Debug build` -> BUILD SUCCEEDED.
