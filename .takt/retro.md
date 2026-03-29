# Active Alerts

| Status | Alert | First Seen | Last Seen |
|--------|-------|------------|-----------|
| mitigated | Workers unable to use Bash (background agents denied, foreground requires constant approval) | 2026-02-20 | 2026-03-07 |
| mitigated | Self-contained test types must be manually synced with production code | 2026-02-26 | 2026-03-29 |
| confirmed | swift test never run end-to-end — unit tests unverified across all runs | 2026-02-26 | 2026-03-29 |
| confirmed | ConfigService has redundant atomic write strategies — never cleaned up across multiple runs | 2026-03-07 | 2026-03-29 |
| confirmed | xcodebuild broken in agent environment (IDESimulatorFoundation symbol not found) | 2026-03-14 | 2026-03-29 |
| confirmed | AudioRecorder.swift subsystems (retry, converter, silence detection) never refactored into focused types | 2026-03-27 | 2026-03-29 |
| confirmed | DiagnosticLogger never gated or removed before release | 2026-03-27 | 2026-03-29 |
| confirmed | CHANGELOG.md [0.6] entry missing bracket noise token strip fix | 2026-03-27 | 2026-03-29 |
| confirmed | Pre-existing working-tree changes from v0.6 never committed to main | 2026-03-27 | 2026-03-29 |
| confirmed | 17 zombie agent panes accumulate during parallel sprints — no automatic cleanup mechanism | 2026-03-27 | 2026-03-29 |
| potential | Test file inline-copy of production formatters is a permanent manual burden — no automation | 2026-03-29 | 2026-03-29 |

---

## Retro: 2026-03-29 — takt/deterministic-formatter-tdd

### What Went Well
- **All 4 stories completed with 0 blocked.** TDD hardening of the deterministic formatter ran sequentially with clean story-to-story handoff: paragraph splitting → delegation → sync → idempotency.
- **US-003 (sync) resolved the chronic inline-drift blocker**: A dedicated sync story was used to reconcile the inlined formatter copies in `FormatterTests.swift` with production, finding and fixing compressed single-line methods, renamed variables (`allCap` → `allCapitalized`), and missing named booleans. This is the most direct address of the alert yet.
- **US-002 removed 52 lines of duplicate logic**: `MessageFormatter.structureBody()` was deleted in favour of delegating to `StructuredTextFormatter` — a clean deduplication with no behaviour change.
- **US-004 (idempotency) had no blockers and no pre-existing failures**: The smallest story in the sprint completed cleanly with no carry-on issues.
- **Transition phrase tuning in US-001 was precise**: Added `"how about"`, `topicShiftPrefixes` guard ordering, long-text midpoint fallback, and ratio-gated bullet suppression — each decision directly tied to a failing acceptance criterion.

### What Didn't Go Well
- **US-001 still has one failing test (A16)**: Requires >= 3 paragraphs but only gets 2 — needs `"okay"` as a casual transition marker. Not in story AC, left as a known gap.
- **Pre-existing test failures (C03, C06, D06, D07, D17, D22) were present before this sprint and remain unchanged**: US-001's workbook flagged them as out-of-scope; no story addressed them.
- **The inline-copy pattern persists as structural debt**: US-001 and US-002 both required manually mirroring production code into `FormatterTests.swift`. US-003 cleaned up drift but the mechanism remains — every future formatter change still requires a manual dual-update.

### Patterns Observed
- **Sequential story chains (each depends on prior) are efficient for formatter work**: The 4-story chain ran without conflict because each story had a single clear dependency. No parallel-write collisions.
- **Dedicated sync stories are effective at clearing drift but don't prevent future drift**: US-003 found 4 concrete differences. A better fix would auto-generate or eliminate the inline copy.
- **TDD hardening sprints expose pre-existing failures clearly**: The formatter sprint surfaced exactly which tests were failing before the sprint vs. introduced by it. This is useful for scoping future work.

### Action Items
- [ ] [carried 8x] Add a note to story templates for Swift/Apple platform work: flag CoreFoundation types as requiring `CFGetTypeID` guards
  Suggested story: Codify a Swift story template section listing known platform gotchas (CFGetTypeID, async actor isolation, Xcode project.pbxproj sync)
- [ ] [carried 9x] Run `swift test` end-to-end to verify unit tests actually execute
  Suggested story: Add a CI step or pre-release checklist item that runs `swift test` and gates the release
- [ ] [carried 9x] Simplify ConfigService atomic write (remove either `.atomic` flag or `replaceItemAt`)
  Suggested story: Audit ConfigService.swift and pick one atomic write strategy, remove the redundant one
- [ ] [carried 6x] Fix xcodebuild test bundle code signing mismatch (`different Team IDs`) so unit tests can actually run
  Suggested story: Investigate and fix the Team ID mismatch that prevents xcodebuild test from running
- [ ] [carried 6x] Consider extracting AudioRecorder.swift subsystems (retry logic, converter lifecycle, silence detection) into focused types
  Suggested story: Refactor AudioRecorder.swift — split retry/backoff, AVAudioConverter lifecycle, and silence detection into separate structs or actors
- [ ] [carried 5x] Commit or remove DiagnosticLogger before next release — decide if it stays as a permanent debug tool or is stripped
  Suggested story: Gate DiagnosticLogger behind a compile flag or remove it; update MEMORY.md accordingly
- [ ] [carried 5x] Add `[BLANK_AUDIO]` / bracket noise token fix to CHANGELOG.md under [0.6] entry
  Suggested story: Update CHANGELOG.md [0.6] section with the bracket noise token strip fix
- [ ] [carried 4x] Commit pre-existing working-tree changes from v0.6 work (AppConfig.swift, ConfigService.swift, DiagnosticLogger.swift) to main before starting next sprint
  Suggested story: Stage and commit the v0.6 working-tree files that were never committed (AppConfig.swift, ConfigService.swift, DiagnosticLogger.swift)
- [ ] [carried 3x] Generate real EdDSA keypair, replace SUPublicEDKey placeholder in Info.plist before v0.7 release build
  Suggested story: Generate EdDSA keypair, insert SUPublicEDKey into Info.plist, verify Sparkle update signature end-to-end
- [ ] [carried 3x] Enable GitHub Pages on repo (Settings → Pages → docs/ folder on main)
  Suggested story: Enable GitHub Pages on the dikta repo pointing to docs/ on main
- [ ] [carried 3x] Run a real build with the new signing flow to confirm notarization passes end-to-end
  Suggested story: Run build-release.sh and confirm notarization completes without errors
- [ ] [carried 1x] Verify Windows build end-to-end on a Windows machine: `dotnet build`, `dotnet run`, hotkey registration, model download, transcription, and Inno Setup compilation
- [ ] [carried 1x] Add Windows verification step to release checklist (VERIFY.md or build-release.sh equivalent for Windows)
- [ ] Eliminate the inline-copy pattern in FormatterTests.swift — either refactor tests to import production types directly or generate the inline via a build script
  Suggested story: Refactor FormatterTests.swift to remove inlined StructuredTextFormatter and MessageFormatter structs, replacing with direct imports of production types

### Chronic Tech Debt
- [ ] [carried 9x] Run `swift test` end-to-end to verify unit tests actually execute
  Suggested story: Add a CI step or pre-release checklist item that runs `swift test` and gates the release
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.
- [ ] [carried 9x] Simplify ConfigService atomic write (remove either `.atomic` flag or `replaceItemAt`)
  Suggested story: Audit ConfigService.swift and pick one atomic write strategy, remove the redundant one
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.

### Metrics
- Stories completed: 4/4
- Stories blocked: 0
- Total workbooks: 4
- Avg story duration: 657s (large/US-001), 152s + 298s (medium/US-002, US-003), 354s (small/US-004)
- Phase overhead: N/A (retro start time not available)
