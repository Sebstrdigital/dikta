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
| confirmed | WithNoSpeechThreshold method name unverified — Whisper.net 1.9.0 may use different API | 2026-04-17 | 2026-04-17 |
| potential | Worker agents create files that already exist, clobbering prior sprint work — no existence check before write | 2026-04-17 | 2026-04-17 |

---

## Retro: 2026-04-17 — takt/windows-v12-sprint-4

### What Went Well
- **All 5 stories delivered, 0 blocked.** Polish sprint rolling up 13 deferred review suggestions into 5 targeted stories — all completed cleanly.
- **Zero blockers across all stories.** US-001 through US-005 all report no blockers encountered. Surgical, well-scoped stories continue to be a strength.
- **US-004 three-state mic probe is solid design.** NAudio MMDeviceEnumerator distinguishes hardware-absent from permission-denied with a COM fallback; grant button correctly hidden when no hardware present.
- **US-005 rename-to-.tmp.failed approach.** Cleaner than delete-on-success — preservation intent expressed at one site (top of next attempt), not scattered across failure/success paths.
- **US-003 OEM key round-trip complete.** FormatKey now covers all 10 OEM keys present in ParseKey; OemPipe/OemBackslash VK_OEM_5 identity handled correctly.

### What Didn't Go Well
- **Worker attempted to create DiagnosticLogger.cs as a stub, clobbering the Sprint 3 implementation.** US-001 workbook lists DiagnosticLogger.cs as a "new file" — but Sprint 3 already built the full implementation. Session agent caught the conflict and restored from main before commit. No production code was lost, but the incident required manual intervention.
- **Build verification still impossible in agent environment.** Fifth consecutive Windows sprint validated by code inspection only. No Windows hardware run.
- **Wave timing produces shared timestamps.** All 5 stories share startTime=1776426706 / endTime=1776426885 — individual per-story durations are not extractable from sprint-snapshot.

### Patterns Observed
- **Worker file-creation risk confirmed.** Worker for US-001 treated DiagnosticLogger.cs as a missing file and wrote a stub. Worker prompts have no existence check before `Write` — they rely on task description accuracy. This is a repeatable failure mode for any sprint that touches files created in a prior sprint.
- **Polish sprints are highly reliable.** Sprint 4 was unplanned (rolled up from review suggestions) and had 0 blockers, 0 rework. Small, well-specified polish stories are a sweet spot for autonomous agents.
- **HistoryService error handling pattern applies broadly.** US-001's swallow-and-log approach (try/catch IOException + JsonException, DiagnosticLogger.Warning, no rethrow) is the correct pattern for non-fatal persistence operations throughout the Windows codebase.
- **TrayIconManager.cs hotspot continues.** Sprint 4 US-002 touched it again (Dispose symmetry, balloon dispatch, safe model lookup). 10+ stories across 4 sprints. Cohesion review still warranted.

### Action Items
- [ ] [carried 13x] Add a note to story templates for Swift/Apple platform work: flag CoreFoundation types as requiring `CFGetTypeID` guards
  Suggested story: Codify a Swift story template section listing known platform gotchas (CFGetTypeID, async actor isolation, Xcode project.pbxproj sync)
- [ ] [carried 14x] Run `swift test` end-to-end to verify unit tests actually execute
  Suggested story: Add a CI step or pre-release checklist item that runs `swift test` and gates the release
- [ ] [carried 14x] Simplify ConfigService atomic write (remove either `.atomic` flag or `replaceItemAt`)
  Suggested story: Audit ConfigService.swift and pick one atomic write strategy, remove the redundant one
- [ ] [carried 11x] Fix xcodebuild test bundle code signing mismatch (`different Team IDs`) so unit tests can actually run
  Suggested story: Investigate and fix the Team ID mismatch that prevents xcodebuild test from running
- [ ] [carried 11x] Consider extracting AudioRecorder.swift subsystems (retry logic, converter lifecycle, silence detection) into focused types
  Suggested story: Refactor AudioRecorder.swift — split retry/backoff, AVAudioConverter lifecycle, and silence detection into separate structs or actors
- [ ] [carried 10x] Add `[BLANK_AUDIO]` / bracket noise token fix to CHANGELOG.md under [0.6] entry
  Suggested story: Update CHANGELOG.md [0.6] section with the bracket noise token strip fix
- [ ] [carried 9x] Commit pre-existing working-tree changes from v0.6 work (AppConfig.swift, ConfigService.swift, DiagnosticLogger.swift) to main before starting next sprint
  Suggested story: Stage and commit the v0.6 working-tree files that were never committed (AppConfig.swift, ConfigService.swift, DiagnosticLogger.swift)
- [ ] [carried 6x] Verify Windows build end-to-end on a Windows machine: `dotnet build`, `dotnet run`, hotkey registration, model download, transcription, and Inno Setup compilation
  Suggested story: Add a Windows smoke-test checklist to VERIFY.md or the release runbook; run it manually before every Windows release
- [ ] [carried 6x] Add Windows verification step to release checklist (VERIFY.md or build-release.sh equivalent for Windows)
  Suggested story: Create dikta-windows/RELEASE.md with build, smoke-test, and Inno Setup steps
- [ ] [carried 6x] Eliminate the inline-copy pattern in FormatterTests.swift — either refactor tests to import production types directly or generate the inline via a build script
  Suggested story: Refactor FormatterTests.swift to remove inlined StructuredTextFormatter and MessageFormatter structs, replacing with direct imports of production types
- [ ] [carried 3x] Verify `WithNoSpeechThreshold` is the correct Whisper.net 1.9.0 method name — US-010 notes it may be `WithNoSpeechProb` or similar
  Suggested story: On a Windows build machine, compile dikta-windows and confirm TranscriberService builds cleanly with the threshold wiring
- [ ] [takt finding] Add explicit file-existence check to worker prompts: "Do NOT create a file if it already exists — read it first and edit in place." Apply to all takt worker templates.
  Suggested story: Audit takt worker prompt templates and add a pre-write guard: check file existence before any Write call, prefer Edit over Write for existing files
- [ ] Review TrayIconManager.cs for cohesion — 10+ stories across 4 sprints have added to it; consider splitting responsibilities
  Suggested story: Audit TrayIconManager.cs, extract menu-building logic or DIAGNOSTICS-only items into a separate class if warranted

### Chronic Tech Debt
- [ ] [carried 14x] Run `swift test` end-to-end to verify unit tests actually execute
  Suggested story: Add a CI step or pre-release checklist item that runs `swift test` and gates the release
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.
- [ ] [carried 14x] Simplify ConfigService atomic write (remove either `.atomic` flag or `replaceItemAt`)
  Suggested story: Audit ConfigService.swift and pick one atomic write strategy, remove the redundant one
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.

### Metrics
- Stories completed: 5/5
- Stories blocked: 0
- Total workbooks: 5
- Sprint wall clock: 179s (1776426706 → 1776426885), 1 wave (all stories parallel)
- Per-story duration: unavailable — all stories share identical startTime/endTime in sprint-snapshot
- Timing stats: small updated (avg 225s, n=31); overhead updated (avg 1024s, n=5)
- Phase overhead: 1371s (gap between Sprint 3 endTime 1776425335 and Sprint 4 startTime 1776426706)
