# Feature: Windows Reliability Hardening (F-1)

**Epic:** [Dikta Windows v1.2 — MVP Reliability & Polish](epic-windows-v12-mvp-reliability.md)

## 1. Introduction/Overview

Dikta Windows v1.1 works on the happy path but has several correctness bugs that surface on real user hardware: the Whisper model is reloaded from disk (500 MB to 3 GB) on every transcription, initial hotkey registration fails silently if another app holds the binding, there is no single-instance guard, no unhandled exception handlers, config writes are not atomic, history load crashes on bad JSON, and the model download prompt shows the wrong size. This Feature fixes all P0/P1 correctness bugs in the core dictation pipeline so the external tester's first experience is a working, stable app.

## 2. Goals

- First transcription after app launch completes in under 3 seconds (model pre-loaded once)
- Hotkey registration failures are visible to the user (tray balloon or modal)
- Second app launch activates the existing instance's modal instead of starting a second process
- Unhandled exceptions are caught, logged, and surface a user-visible notification before exit
- Config and history files survive crashes mid-write without data loss
- Bad JSON in history does not crash the app at startup

## 3. User Stories

### US-001: Fast first transcription via WhisperFactory caching

**Description:** As a user, I want my first dictation after launching Dikta to complete quickly so that I don't think the app has frozen.

**Acceptance Criteria:**
- [ ] The Whisper model is loaded from disk exactly once per app session (or on model-change)
- [ ] First transcription after launch completes in under 3 seconds on a 2020+ CPU with the `small` model
- [ ] Subsequent transcriptions start with no model-load delay

### US-002: Startup hotkey failure is visible

**Description:** As a user, I want to know if the app's hotkey failed to register so that I don't sit pressing keys wondering why nothing happens.

**Acceptance Criteria:**
- [ ] If `RegisterHotKey` fails during app startup, a tray balloon appears within 2 seconds saying "Hotkey Ctrl+Shift+D is in use by another app. Open Settings to choose another."
- [ ] The tray icon remains visible so the user can open Settings from the right-click menu
- [ ] The balloon is dismissable and does not re-appear unless the app restarts

### US-003: Single-instance guard with modal activation

**Description:** As a user, I want Dikta to refuse to start twice so that I don't end up with two conflicting tray icons and broken hotkeys.

**Acceptance Criteria:**
- [ ] Launching Dikta a second time while an instance is already running does NOT create a second process
- [ ] The existing instance's Onboarding / About modal comes to the foreground in response to the second launch
- [ ] The Mutex is released cleanly on app exit so a later relaunch succeeds

### US-004: Unhandled exception handlers

**Description:** As a developer (remotely debugging via a friend's machine), I want unhandled exceptions to be caught and surfaced so that crashes don't vanish silently from the tray.

**Acceptance Criteria:**
- [ ] `DispatcherUnhandledException`, `AppDomain.CurrentDomain.UnhandledException`, and `TaskScheduler.UnobservedTaskException` are all wired on startup
- [ ] An unhandled exception shows a tray balloon "Dikta crashed: <message>. Please report this." before the process exits
- [ ] The exception detail is written to `%APPDATA%\Dikta\last-crash.log` (single file, overwrites each crash)

### US-005: Atomic config write

**Description:** As a user, I want my settings to survive a power loss or OS crash mid-save so that I don't lose my preferences.

**Acceptance Criteria:**
- [ ] `ConfigService.Save` writes to a `.tmp` sibling file then atomically replaces the target via `File.Replace`
- [ ] A simulated crash between the write and the replace leaves the previous valid config intact (verified via unit test or manual sequence)
- [ ] Save failures (disk full, permission denied) surface a tray balloon rather than silently losing the change

### US-006: History JSON resilience

**Description:** As a user, I want Dikta to start even if my history file is corrupt so that a single bad write does not brick the app.

**Acceptance Criteria:**
- [ ] `HistoryService.Load` catches JSON deserialization exceptions and resets to an empty history, logging the error
- [ ] `HistoryService.Save` holds the internal lock through the file write (not just the snapshot)
- [ ] History file is written atomically via the same `.tmp` + `File.Replace` pattern as config

### US-007: Correct model-size prompt

**Description:** As a user, I want the download prompt to tell me the true model size so that I'm not surprised by a 488 MB download after agreeing to 150 MB.

**Acceptance Criteria:**
- [ ] The first-run download prompt shows the actual size of the currently-selected model (small = ~488 MB)
- [ ] The size is sourced from `ModelDownloader.ExpectedModelSizes` (not a hardcoded constant)
- [ ] Values for medium (~1.5 GB) and large (~3 GB) display correctly when those sizes are selectable

## 4. Functional Requirements

- FR-1: `TranscriberService` must hold a single `WhisperFactory` instance for the lifetime of the configured model path; swap only when the model path changes (model-size change in Settings).
- FR-2: `HotkeyManager.RegisterConfiguredHotkey` must signal failure to the `TrayIconManager` via an event or callback; `TrayIconManager` shows the tray balloon.
- FR-3: `App.OnStartup` must acquire a named `Mutex` (name: `Global\Dikta-SingleInstance`); if already held, post a message to the existing instance and exit the new process without creating WPF windows.
- FR-4: The three exception handlers must log to `%APPDATA%\Dikta\last-crash.log` with UTC timestamp, exception type, message, and stack trace.
- FR-5: `ConfigService.Save` and `HistoryService.Save` must use `File.Replace(tmpPath, destPath, backupPath: null, ignoreMetadataErrors: true)` for atomic replacement on NTFS.
- FR-6: `HistoryService.Load` must catch `JsonException`, `FileNotFoundException`, and `UnauthorizedAccessException` and fall through to an empty-but-valid state.
- FR-7: `ModelDownloader.ExpectedModelSizes` must be exposed through a public read-only API consumed by the download prompt.

## 5. Non-Goals (Out of Scope)

- Automatic recovery from crash-log reports (remains manual for now)
- Telemetry of crashes to a remote service
- Structured logging beyond single crash file + diagnostic logs (F-6)
- Graceful handling of DISK FULL during Whisper model download (covered in F-3)
- Migration of existing malformed config files to a new schema

## 6. Design Considerations

- **Single-instance activation (Q5b):** When the second instance detects the Mutex is held, it should signal the first instance (named pipe or `SendMessage` with a custom `WM_APP+n`) to bring its Onboarding modal to the foreground. If the modal is closed, re-open it.
- **Crash notification UX:** Keep the tray balloon short. Do not show a dialog — the user may be away from the keyboard. Log the detail to disk.

## 7. Technical Considerations

- **WhisperFactory lifecycle:** `WhisperFactory.FromPath` loads the ggml model into memory via whisper.cpp native code. Keeping it alive for the process lifetime is the intended pattern per the Whisper.net release notes. Dispose only on app exit or model-path change.
- **Mutex scoping:** Use `Global\` prefix so the check spans user sessions on the same machine. Per-user would be `Local\`, but tray apps should be per-machine to avoid two instances fighting over the hotkey.
- **Atomic file replace:** `File.Replace` requires both source and destination to exist. On first-ever write where destination does not exist, fall back to `File.Move(tmpPath, destPath)`.
- **Crash log location:** `%APPDATA%\Dikta\last-crash.log` keeps crash info adjacent to config and history for easy tester export via "zip my Dikta folder".

## 8. Success Metrics

- Zero silent failure modes verified in QA checklist items 2, 4, 8, 9
- First-transcription latency measured under 3 seconds on tester machine
- Mutex single-instance verified: second launch does nothing except activate modal

## 9. Open Questions

1. **Named pipe vs `WM_APP` message for cross-instance modal activation** — Named pipe is more flexible but adds a listener thread; `WM_APP + n` via `PostMessage` to the existing HwndSource is simpler. Recommend the latter.
2. **Should `last-crash.log` be rotated?** Single file overwrite is simplest; rotation is only useful if crashes cluster. Start simple.
3. **WhisperFactory thread safety** — Confirm via Whisper.net source whether a single factory can safely create multiple processors across threads. The TrayIconManager serializes on the UI thread today, so this is not an immediate concern, but worth verifying.
