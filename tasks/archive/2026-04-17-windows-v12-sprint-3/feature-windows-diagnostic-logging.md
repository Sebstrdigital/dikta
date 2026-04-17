# Feature: Windows Diagnostic Logging (F-6)

**Epic:** [Dikta Windows v1.2 — MVP Reliability & Polish](epic-windows-v12-mvp-reliability.md)

## 1. Introduction/Overview

The developer cannot test Dikta on Windows locally. When the external tester reports an issue, the developer has no way to see what happened — the current app only writes to `Debug.WriteLine` which is invisible in release builds. This Feature adds a file-based rolling logger gated behind a `DIAGNOSTICS` compile flag. Release builds shipped to tech-naive end users omit logging entirely (no privacy footprint, smaller binary). Developer / tester builds include logs the tester can zip and email when something misbehaves.

## 2. Goals

- Compile-flagged logging infrastructure that can be fully stripped from release builds
- 5-file × 1 MB rolling log at `%APPDATA%\Dikta\logs\`
- Instrumentation at key lifecycle points: startup, hotkey registration, recording start/stop, transcription duration, caught exceptions
- One-click access to the logs folder from the tray menu (tester-friendly) when the flag is enabled

## 3. User Stories

### US-001: Rolling file logger

**Description:** As a developer, I want a simple file-based logger so that I can trace what happened during a tester's session without shipping a third-party logging framework.

**Acceptance Criteria:**
- [ ] A `DiagnosticLogger` service writes log lines to `%APPDATA%\Dikta\logs\dikta-{n}.log` with rotation after 1 MB
- [ ] Up to 5 log files are retained; the oldest is deleted when the 6th rotation occurs
- [ ] Each line is formatted as `{UTC timestamp} {level} {message}` and is safe to write from multiple threads

### US-002: Compile-time enable / disable

**Description:** As a developer, I want to ship release builds without logging so that non-tech end users don't have log files accumulating on their machines.

**Acceptance Criteria:**
- [ ] All logger calls are wrapped in `#if DIAGNOSTICS` or routed through a no-op stub when the flag is off
- [ ] A release build with `DIAGNOSTICS` undefined produces no `logs/` directory and no log writes
- [ ] A build with `<DefineConstants>DIAGNOSTICS</DefineConstants>` in csproj emits full logs

### US-003: Instrumentation at key points

**Description:** As a developer, I want the logs to cover the lifecycle events that matter so that a tester's log export tells me what actually happened.

**Acceptance Criteria:**
- [ ] Startup logs include: app version, OS version, .NET runtime, model path, whether model file exists
- [ ] Hotkey registration logs success with the bound combo, or failure with the Win32 error code
- [ ] Recording start / stop log the timestamp and the audio file path
- [ ] Transcription logs the language, audio duration, transcription duration, and output character count
- [ ] All three unhandled exception handlers (from F-1) also log the full exception before the crash notification

### US-004: Tray menu "Open logs folder"

**Description:** As a tester, I want a one-click way to open the logs folder so that I can zip and email the logs without hunting through AppData.

**Acceptance Criteria:**
- [ ] When built with `DIAGNOSTICS`, the tray right-click menu shows an "Open logs folder" item
- [ ] Clicking it opens Explorer at `%APPDATA%\Dikta\logs\`
- [ ] When built without `DIAGNOSTICS`, the menu item is absent

## 4. Functional Requirements

- FR-1: `DiagnosticLogger` is a static class (or singleton) with methods `Info`, `Warning`, `Error`, and `Exception`. Each formats a line and appends to the current log file.
- FR-2: Rotation: before writing, check the current file size. If `>= 1 MB`, rotate: `dikta-4.log` → `dikta-5.log` (deleted if existed), ..., `dikta-0.log` → `dikta-1.log`, start fresh `dikta-0.log`.
- FR-3: Thread safety: use a single `StreamWriter` wrapped with `TextWriter.Synchronized`, or a `lock` around the append.
- FR-4: All logger methods are wrapped: `#if DIAGNOSTICS { ... } #endif` at the call sites, OR the logger itself is a partial class with a no-op implementation when the flag is off. Prefer the latter for cleaner call sites.
- FR-5: `App.OnStartup` (first instrumented point) logs: `Application.ResourceAssembly.GetName().Version`, `Environment.OSVersion`, `RuntimeInformation.FrameworkDescription`, the resolved model path from `ConfigService.ModelsDir`, and `File.Exists(modelPath)`.
- FR-6: `HotkeyManager.RegisterConfiguredHotkey` logs the combo + success, or `Marshal.GetLastWin32Error()` on failure.
- FR-7: `AudioRecorder.StartRecording` / `OnRecordingStopped` log with the temp file path.
- FR-8: `TranscriberService.TranscribeAsync` logs before / after with timing data.
- FR-9: The three exception handlers (from F-1) log full exception detail via `DiagnosticLogger.Exception` before showing the tray balloon.
- FR-10: `TrayIconManager` adds an "Open logs folder" menu item when the flag is on, calling `Process.Start("explorer.exe", logsPath)`.

## 5. Non-Goals (Out of Scope)

- Structured logging (JSON / Serilog / NLog) — hand-rolled text is sufficient
- Log-level filtering in config — all levels always logged
- Remote log shipping / telemetry
- Log compression / archival beyond the 5-file rolling window
- Logging of audio content or transcribed text (privacy: log only metadata like durations and lengths)
- Timestamp formatting configurability — hardcoded `yyyy-MM-ddTHH:mm:ss.fffZ`
- Runtime toggle for enable/disable (must recompile)

## 6. Design Considerations

- **Privacy:** Never log transcribed text or audio file contents. Log character counts and durations only. The audio file path is fine (it's in `%TEMP%` and already visible to anyone with file-system access).
- **No-op stub pattern:** Prefer compile-time method elimination via `[Conditional("DIAGNOSTICS")]` attribute on logger methods. Makes call sites clean without `#if`.

## 7. Technical Considerations

- **`[Conditional("DIAGNOSTICS")]`:** When the preprocessor symbol is not defined, the compiler eliminates the call at compile time. Works for `void` return methods and must be used on instance or static methods. Avoids `#if` noise at every call site.
- **StreamWriter lifecycle:** Keep open for the process lifetime; flush on each write. Dispose on `App.OnExit`. Alternative: open-append-close per write (simpler, safer, slightly slower).
- **Rotation under write contention:** A log write arriving mid-rotation could race. Serialize rotation + write under the same lock.
- **Log folder creation:** `Directory.CreateDirectory(logsPath)` on first write; no-op if exists.

## 8. Success Metrics

- Release build with `DIAGNOSTICS` off produces zero log files
- Tester's first session with `DIAGNOSTICS` on produces a readable log covering startup → hotkey → recording → transcription
- Developer can diagnose a tester-reported issue from a single log export without needing further questions

## 9. Open Questions

1. **Logger initialization order** — Logger must be up before the exception handlers, which are wired in `App.OnStartup`. Can the logger be initialized in `App` constructor, before any services? Likely yes.
2. **What to do if logs folder is on a locked disk?** — Fallback: skip logging entirely, print one `Debug.WriteLine`. Don't crash.
3. **Conditional tray menu item** — using `#if DIAGNOSTICS` around the `menu.Items.Add("Open logs folder", ...)` is cleanest. Confirm this aligns with the compile flag approach chosen in FR-4.
4. **Log level naming** — `Info`, `Warning`, `Error`, `Exception`. Should we add `Debug` for verbose spots? Recommend: no, keeps the API tight.
