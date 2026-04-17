# Feature: Windows Polish & Release Prep (F-4)

**Epic:** [Dikta Windows — Feature Parity & Release Readiness](epic-windows-feature-parity.md)

## 1. Introduction/Overview

With language support (F-1), model management (F-2), and settings UI (F-3) complete, the Windows app needs a final polish pass to be shippable as v1.0. This includes replacing the placeholder tray icon, creating an installer, hardening error handling for edge cases, updating the verification checklist, and adding Windows documentation.

## 2. Goals

- The app looks professional with a custom tray icon (not a generic system icon)
- Users can install via a standard Windows installer (.exe)
- Edge cases (mic unavailable, network down, corrupt config) are handled gracefully
- VERIFY.md is a comprehensive, up-to-date checklist covering all features
- README has clear Windows install and usage instructions

## 3. User Stories

### US-001: Custom tray icon and app identity

**Description:** As a user, I want Dikta to have its own icon in the system tray so that I can identify it among other tray apps.

**Acceptance Criteria:**
- [ ] The system tray shows a custom Dikta icon (not the generic application icon)
- [ ] The icon visually changes or indicates state when recording is active (e.g. color change or overlay)
- [ ] The tooltip on hover shows "Dikta" and the current language (e.g. "Dikta — English")

### US-002: Windows installer

**Description:** As a user, I want to install Dikta via a standard Windows installer so that I can set it up like any other app.

**Acceptance Criteria:**
- [ ] An Inno Setup installer (.exe) installs Dikta to Program Files, creates a Start Menu shortcut, and optionally adds to startup
- [ ] The installer bundles the .NET 8 runtime (or checks for it and prompts to install)
- [ ] Uninstall via Windows Settings removes all app files and the Start Menu entry

### US-003: Error handling and graceful degradation

**Description:** As a user, I want clear error messages when something goes wrong so that I know what to fix.

**Acceptance Criteria:**
- [ ] If no microphone is detected, a notification explains "No microphone found" when the hotkey is pressed
- [ ] If config.json is corrupt or unreadable, the app resets to defaults and notifies the user
- [ ] If a transcription fails (Whisper error), the app shows a tray notification and returns to idle state (not stuck in "processing")

### US-004: Updated VERIFY.md and documentation

**Description:** As the developer, I want a comprehensive verification checklist and README so that testing on a Windows machine is systematic and new users can get started.

**Acceptance Criteria:**
- [ ] VERIFY.md covers all features: hotkey, 12 languages, model download, settings window, history, error cases
- [ ] README includes Windows section with: prerequisites, install instructions, first-run walkthrough, and known limitations
- [ ] Each VERIFY.md item is specific enough that a tester can check it in under 2 minutes

## 4. Functional Requirements

- FR-1: A custom `.ico` file must be created for the tray icon, with at least 16x16, 32x32, and 48x48 sizes
- FR-2: The tray icon must reflect recording state — either a different icon variant or a visible change (recommended: normal icon for idle, highlighted/red variant for recording)
- FR-3: The `NotifyIcon.Text` tooltip must show "Dikta — {Language}" (e.g. "Dikta — English")
- FR-4: An Inno Setup script (`.iss`) must produce a self-contained installer that bundles the published app and .NET runtime
- FR-5: The installer must offer "Start at login" as an optional checkbox during install
- FR-6: `AudioRecorder.StartRecording()` must check for available audio input devices before starting and throw a descriptive exception if none found
- FR-7: `ConfigService.LoadConfig()` must catch JSON deserialization errors and fall back to defaults, logging the error
- FR-8: `TrayIconManager.OnHotkeyPressed()` must catch all exceptions from the transcription pipeline and show a tray notification balloon rather than silently failing
- FR-9: VERIFY.md must be rewritten to cover every user-facing feature with pass/fail checkboxes

## 5. Non-Goals (Out of Scope)

- Auto-update system (Sparkle equivalent) — separate epic
- Microsoft Store / MSIX publishing — Inno Setup is sufficient for v1.0
- Code signing certificate — can ship unsigned initially, SmartScreen warning is acceptable for v1.0
- CI/CD pipeline for Windows builds — nice-to-have but not blocking release
- Localized UI strings — English-only UI is fine
- Animated tray icon (e.g. pulsing during recording) — a static state change is sufficient

## 6. Design Considerations

- **Tray icon:** Should visually match the macOS Dikta icon style. A simple microphone or "D" glyph. Two variants: idle (monochrome/subtle) and recording (red/highlighted).
- **Installer UX:** Standard Inno Setup wizard: license → destination → options (Start at Login) → install → finish. Nothing unusual.

## 7. Technical Considerations

- **Icon format:** Windows tray icons require `.ico` files with multiple resolutions. Can be generated from a PNG source using tools like ImageMagick or online converters.
- **Inno Setup:** Free, well-documented, produces single-file installers. The `.iss` script references the `dotnet publish` output directory. Self-contained publish (`--self-contained true`) eliminates the .NET runtime dependency but increases size by ~60 MB.
- **Blind development:** The Inno Setup script and icon can be prepared on macOS. The actual build and packaging must happen on a Windows machine (or CI runner). The `.iss` script should be parameterized so paths are easy to adjust.
- **Error handling:** All error paths should use `NotifyIcon.ShowBalloonTip()` for user-visible errors rather than `MessageBox.Show()`, which blocks the thread.

## 8. Success Metrics

- Custom tray icon visible and distinguishable from other tray apps
- Installer produces a working installation on a clean Windows 10/11 machine
- No unhandled crashes in normal usage — all error paths show user-friendly notifications
- VERIFY.md can be completed by a tester in under 30 minutes

## 9. Open Questions

1. **Icon design** — Should we reuse the macOS icon assets or create Windows-specific ones? The macOS icon is designed for the menu bar; Windows tray has different conventions.
2. **Self-contained vs framework-dependent** — Self-contained publish adds ~60 MB but eliminates runtime dependency. Worth the size trade-off?
3. **Start at Login mechanism** — Registry key (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`) or Task Scheduler? Registry key is simpler and standard for tray apps.
