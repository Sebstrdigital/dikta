# Changelog

All notable changes to Dikta will be documented in this file.

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
