# Active Alerts

| Status | Alert | First Seen | Last Seen |
|--------|-------|------------|-----------|
| mitigated | Workers unable to use Bash (background agents denied, foreground requires constant approval) | 2026-02-20 | 2026-03-07 |
| mitigated | Self-contained test types must be manually synced with production code | 2026-02-26 | 2026-03-29 |
| confirmed | swift test never run end-to-end — unit tests unverified across all runs | 2026-02-26 | 2026-04-17 |
| confirmed | ConfigService has redundant atomic write strategies — never cleaned up across multiple runs | 2026-03-07 | 2026-04-17 |
| confirmed | xcodebuild broken in agent environment (IDESimulatorFoundation symbol not found) | 2026-03-14 | 2026-04-17 |
| confirmed | AudioRecorder.swift subsystems (retry, converter, silence detection) never refactored into focused types | 2026-03-27 | 2026-04-17 |
| confirmed | DiagnosticLogger never gated or removed before release | 2026-03-27 | 2026-04-17 |
| confirmed | CHANGELOG.md [0.6] entry missing bracket noise token strip fix | 2026-03-27 | 2026-04-17 |
| confirmed | Pre-existing working-tree changes from v0.6 never committed to main | 2026-03-27 | 2026-04-17 |
| confirmed | 17 zombie agent panes accumulate during parallel sprints — no automatic cleanup mechanism | 2026-03-27 | 2026-04-17 |
| confirmed | Test file inline-copy of production formatters is a permanent manual burden — no automation | 2026-03-29 | 2026-04-17 |
| confirmed | Windows build never verified end-to-end on actual Windows hardware | 2026-04-17 | 2026-04-17 |

---

## Retro: 2026-04-17 — takt/windows-v12-sprint-1

### What Went Well
- **All 11 stories completed, 0 blocked.** Sprint covered both F-1 (Reliability Hardening) and F-2 (Clipboard/Hotkey Polish) in a single run.
- **Windows/.NET work was exceptionally clean**: No blockers across any of US-001 through US-011. The .NET 8 target and well-scoped stories eliminated ambiguity.
- **Atomic write pattern applied consistently**: US-005 (ConfigService) and US-006 (HistoryService) both landed atomic `.tmp` + `File.Move` saves independently, with correct `.NET 8` primitives (`File.Move` with `overwrite: true` — US-006 notes correctly chose this over `File.Replace` which requires the destination to exist).
- **Careful code-review substituted for unavailable build**: Multiple stories (US-008, US-010) explicitly noted that `net8.0-windows` targets cannot build on macOS, and validated correctness via code inspection against VK constant tables and Win32 docs. This is the right call given the environment.
- **Thread-safety addressed systematically**: US-001 (factory caching with `_cachedModelPath` guard), US-011 (`_processingFlag` via `Interlocked.Exchange`), and US-003 (named Mutex + `DIKTASHOWONBOARDING` broadcast) each solved a distinct race condition class without overlap.
- **US-009 clipboard-idle wait eliminated a fragile fixed delay**: Replacing 50ms with a polling loop watching `GetClipboardSequenceNumber` is a correctness fix that scales to slow machines — good engineering decision captured in workbook.

### What Didn't Go Well
- **No Windows test suite exists**: Every story validated by code inspection only. US-010 explicitly notes "No test project exists for the Windows app." This is the single largest quality risk for the Windows port.
- **Build verification impossible in agent environment**: All 11 stories cite the macOS agent cannot compile `net8.0-windows` targets. Acceptance criteria pass-through relies entirely on code reading — functional correctness unverified until a human runs it on Windows.
- **Stories ran with identical startTime/endTime**: All 11 stories share startTime=1776414377, endTime=1776414759 (382s). The sprint orchestrator ran them in parallel waves rather than sequentially, making per-story duration meaningless as individual effort metrics.

### Patterns Observed
- **Windows/.NET stories complete faster and cleaner than macOS/Swift stories**: No merge conflicts, no build environment issues, no test infrastructure fights. The Windows codebase is younger and has fewer pre-existing complications.
- **File overlap is the main merge risk in Windows sprints**: US-011 workbook explicitly notes that `TrayIconManager.cs` had already been modified by US-001, US-002, US-005, and US-007 — the hotspot file for this sprint. Managing dependency order matters.
- **"Verified by code inspection" is a recurring acceptance pattern for Windows**: This is unavoidable given the environment, but it means real-device validation remains entirely manual and unchecklisted.

### Action Items
- [ ] [carried 10x] Add a note to story templates for Swift/Apple platform work: flag CoreFoundation types as requiring `CFGetTypeID` guards
  Suggested story: Codify a Swift story template section listing known platform gotchas (CFGetTypeID, async actor isolation, Xcode project.pbxproj sync)
- [ ] [carried 11x] Run `swift test` end-to-end to verify unit tests actually execute
  Suggested story: Add a CI step or pre-release checklist item that runs `swift test` and gates the release
- [ ] [carried 11x] Simplify ConfigService atomic write (remove either `.atomic` flag or `replaceItemAt`)
  Suggested story: Audit ConfigService.swift and pick one atomic write strategy, remove the redundant one
- [ ] [carried 8x] Fix xcodebuild test bundle code signing mismatch (`different Team IDs`) so unit tests can actually run
  Suggested story: Investigate and fix the Team ID mismatch that prevents xcodebuild test from running
- [ ] [carried 8x] Consider extracting AudioRecorder.swift subsystems (retry logic, converter lifecycle, silence detection) into focused types
  Suggested story: Refactor AudioRecorder.swift — split retry/backoff, AVAudioConverter lifecycle, and silence detection into separate structs or actors
- [ ] [carried 7x] Commit or remove DiagnosticLogger before next release — decide if it stays as a permanent debug tool or is stripped
  Suggested story: Gate DiagnosticLogger behind a compile flag or remove it; update MEMORY.md accordingly
- [ ] [carried 7x] Add `[BLANK_AUDIO]` / bracket noise token fix to CHANGELOG.md under [0.6] entry
  Suggested story: Update CHANGELOG.md [0.6] section with the bracket noise token strip fix
- [ ] [carried 6x] Commit pre-existing working-tree changes from v0.6 work (AppConfig.swift, ConfigService.swift, DiagnosticLogger.swift) to main before starting next sprint
  Suggested story: Stage and commit the v0.6 working-tree files that were never committed (AppConfig.swift, ConfigService.swift, DiagnosticLogger.swift)
- [ ] [carried 3x] Verify Windows build end-to-end on a Windows machine: `dotnet build`, `dotnet run`, hotkey registration, model download, transcription, and Inno Setup compilation
  Suggested story: Add a Windows smoke-test checklist to VERIFY.md or the release runbook; run it manually before every Windows release
- [ ] [carried 3x] Add Windows verification step to release checklist (VERIFY.md or build-release.sh equivalent for Windows)
  Suggested story: Create dikta-windows/RELEASE.md with build, smoke-test, and Inno Setup steps
- [ ] [carried 3x] Eliminate the inline-copy pattern in FormatterTests.swift — either refactor tests to import production types directly or generate the inline via a build script
  Suggested story: Refactor FormatterTests.swift to remove inlined StructuredTextFormatter and MessageFormatter structs, replacing with direct imports of production types

### Chronic Tech Debt
- [ ] [carried 11x] Run `swift test` end-to-end to verify unit tests actually execute
  Suggested story: Add a CI step or pre-release checklist item that runs `swift test` and gates the release
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.
- [ ] [carried 11x] Simplify ConfigService atomic write (remove either `.atomic` flag or `replaceItemAt`)
  Suggested story: Audit ConfigService.swift and pick one atomic write strategy, remove the redundant one
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.

### Metrics
- Stories completed: 11/11
- Stories blocked: 0
- Total workbooks: 11
- Story durations: all 382s (parallel wave execution — individual durations not meaningful)
- Avg story duration: 382s (medium, this run) → running avg 329s (medium, all runs); 382s (small, this run) → running avg 326s (small, all runs)
- Phase overhead: 1258s (retro start − last story endTime)
