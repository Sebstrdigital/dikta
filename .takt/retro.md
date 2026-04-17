# Active Alerts

| Status | Alert | First Seen | Last Seen |
|--------|-------|------------|-----------|
| mitigated | Workers unable to use Bash (background agents denied, foreground requires constant approval) | 2026-02-20 | 2026-03-07 |
| mitigated | Self-contained test types must be manually synced with production code | 2026-02-26 | 2026-03-29 |
| confirmed | swift test never run end-to-end — unit tests unverified across all runs | 2026-02-26 | 2026-04-17 |
| confirmed | ConfigService has redundant atomic write strategies — never cleaned up across multiple runs | 2026-03-07 | 2026-04-17 |
| confirmed | xcodebuild broken in agent environment (IDESimulatorFoundation symbol not found) | 2026-03-14 | 2026-04-17 |
| confirmed | AudioRecorder.swift subsystems (retry, converter, silence detection) never refactored into focused types | 2026-03-27 | 2026-04-17 |
| confirmed | CHANGELOG.md [0.6] entry missing bracket noise token strip fix | 2026-03-27 | 2026-04-17 |
| confirmed | Pre-existing working-tree changes from v0.6 never committed to main | 2026-03-27 | 2026-04-17 |
| confirmed | 17 zombie agent panes accumulate during parallel sprints — no automatic cleanup mechanism | 2026-03-27 | 2026-04-17 |
| confirmed | Test file inline-copy of production formatters is a permanent manual burden — no automation | 2026-03-29 | 2026-04-17 |
| confirmed | Windows build never verified end-to-end on actual Windows hardware | 2026-04-17 | 2026-04-17 |
| potential | Account usage limit hit mid-sprint — spawned workers terminated, session agent completed remaining stories | 2026-04-17 | 2026-04-17 |
| mitigated | DiagnosticLogger never gated or removed before release | 2026-03-27 | 2026-04-17 |

---

## Retro: 2026-04-17 — takt/windows-v12-sprint-3

### What Went Well
- **All 8 stories delivered, 0 blocked.** Sprint covered F-5 (Hotkey Recording Window) and F-6 (Diagnostic Logging) across 3 waves.
- **HotkeyRecordingWindow is cleanly layered**: US-001 through US-004 build a coherent press-to-bind feature — OS-reserved blocklist (US-002), pre-save registration test (US-003), and SettingsWindow integration (US-004) all landed without blockers or merge conflicts.
- **Pre-save registration test reused existing API**: US-003 found `HotkeyManager.ReregisterHotkey` already present with the exact required signature — zero HotkeyManager changes needed. Good prior sprint design paying off.
- **Diagnostic logging design is solid**: US-005 created a clean static `DiagnosticLogger` with `[Conditional("DIAGNOSTICS")]` on all methods; US-006 documented the compile-flag usage in `DiktaWindows.csproj`; US-007 added lifecycle instrumentation with privacy-safe output (no transcribed text); US-008 added tray menu access behind `#if DIAGNOSTICS`. Four stories, zero blockers.
- **DiagnosticLogger gated correctly this sprint** — the long-standing action item about gating/removing the logger is now addressed for the Windows codebase.

### What Didn't Go Well
- **Build verification still impossible in agent environment**: All 8 stories validated by code inspection only. No Windows hardware run performed. This is the fourth consecutive Windows sprint without a real build.
- **SettingsWindow XAML removal of old controls is not verifiable**: US-004 removed the ListBox+ComboBox hotkey controls and replaced with TextBlock+Button — correct by inspection, but any XAML binding issues will only surface on a live build.
- **Wave timing continues to produce grouping artifacts**: Wave 1 = 111s, Wave 2 = 170s, Wave 3 = 175s — durations reflect wave parallelism, not individual story effort.

### Patterns Observed
- **F-5 (HotkeyRecordingWindow) is the first Windows feature where every story had zero blockers**: All prior sprints had at least one story with a partial blocker or trade-off. Clean dependency chain via `dependsOn` continues to work well.
- **Diagnostic logging completes a remote-debug loop**: With F-6 done, a tester can receive a DIAGNOSTICS build, reproduce an issue, and open the logs folder from the tray. This is a meaningful diagnostic capability added in one sprint.
- **TrayIconManager.cs is a recurring hotspot**: US-008 touched it again (Sprint 3); Sprint 2 US-005/US-006 touched it; Sprint 1 had 4 stories touch it. The file is accumulating feature additions and should eventually be reviewed for cohesion.
- **The no-build gap is compounding**: Four Windows sprints of code-inspection-only acceptance. Each sprint adds more surface area that has never been exercised.

### Action Items
- [ ] [carried 12x] Add a note to story templates for Swift/Apple platform work: flag CoreFoundation types as requiring `CFGetTypeID` guards
  Suggested story: Codify a Swift story template section listing known platform gotchas (CFGetTypeID, async actor isolation, Xcode project.pbxproj sync)
- [ ] [carried 13x] Run `swift test` end-to-end to verify unit tests actually execute
  Suggested story: Add a CI step or pre-release checklist item that runs `swift test` and gates the release
- [ ] [carried 13x] Simplify ConfigService atomic write (remove either `.atomic` flag or `replaceItemAt`)
  Suggested story: Audit ConfigService.swift and pick one atomic write strategy, remove the redundant one
- [ ] [carried 10x] Fix xcodebuild test bundle code signing mismatch (`different Team IDs`) so unit tests can actually run
  Suggested story: Investigate and fix the Team ID mismatch that prevents xcodebuild test from running
- [ ] [carried 10x] Consider extracting AudioRecorder.swift subsystems (retry logic, converter lifecycle, silence detection) into focused types
  Suggested story: Refactor AudioRecorder.swift — split retry/backoff, AVAudioConverter lifecycle, and silence detection into separate structs or actors
- [ ] [carried 9x] Add `[BLANK_AUDIO]` / bracket noise token fix to CHANGELOG.md under [0.6] entry
  Suggested story: Update CHANGELOG.md [0.6] section with the bracket noise token strip fix
- [ ] [carried 8x] Commit pre-existing working-tree changes from v0.6 work (AppConfig.swift, ConfigService.swift, DiagnosticLogger.swift) to main before starting next sprint
  Suggested story: Stage and commit the v0.6 working-tree files that were never committed (AppConfig.swift, ConfigService.swift, DiagnosticLogger.swift)
- [ ] [carried 5x] Verify Windows build end-to-end on a Windows machine: `dotnet build`, `dotnet run`, hotkey registration, model download, transcription, and Inno Setup compilation
  Suggested story: Add a Windows smoke-test checklist to VERIFY.md or the release runbook; run it manually before every Windows release
  Suggested story: Add a Windows smoke-test checklist to VERIFY.md or the release runbook; run it manually before every Windows release
- [ ] [carried 5x] Add Windows verification step to release checklist (VERIFY.md or build-release.sh equivalent for Windows)
  Suggested story: Create dikta-windows/RELEASE.md with build, smoke-test, and Inno Setup steps
- [ ] [carried 5x] Eliminate the inline-copy pattern in FormatterTests.swift — either refactor tests to import production types directly or generate the inline via a build script
  Suggested story: Refactor FormatterTests.swift to remove inlined StructuredTextFormatter and MessageFormatter structs, replacing with direct imports of production types
- [ ] [carried 2x] Verify `WithNoSpeechThreshold` is the correct Whisper.net 1.9.0 method name — US-010 notes it may be `WithNoSpeechProb` or similar
  Suggested story: On a Windows build machine, compile dikta-windows and confirm TranscriberService builds cleanly with the threshold wiring
- [ ] Review TrayIconManager.cs for cohesion — 9+ stories across 3 sprints have added to it; consider splitting responsibilities
  Suggested story: Audit TrayIconManager.cs, extract menu-building logic or DIAGNOSTICS-only items into a separate class if warranted

### Chronic Tech Debt
- [ ] [carried 13x] Run `swift test` end-to-end to verify unit tests actually execute
  Suggested story: Add a CI step or pre-release checklist item that runs `swift test` and gates the release
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.
- [ ] [carried 13x] Simplify ConfigService atomic write (remove either `.atomic` flag or `replaceItemAt`)
  Suggested story: Audit ConfigService.swift and pick one atomic write strategy, remove the redundant one
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.

### Metrics
- Stories completed: 8/8
- Stories blocked: 0
- Total workbooks: 8
- Sprint wall clock: 456s (1776424879 → 1776425335), 3 waves
- Wave durations: Wave 1 = 111s (US-001, US-005), Wave 2 = 170s (US-002, US-003, US-006, US-007), Wave 3 = 175s (US-004, US-008)
- Avg story duration: ~154s (wave-divided estimate)
- Timing stats: updated (medium: avg 266s, n=15; small: avg 262s, n=26)
- Phase overhead: unavailable — retro start timestamp not recorded in sprint-snapshot
