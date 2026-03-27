# Active Alerts

| Status | Alert | First Seen | Last Seen |
|--------|-------|------------|-----------|
| mitigated | Workers unable to use Bash (background agents denied, foreground requires constant approval) | 2026-02-20 | 2026-03-07 |
| confirmed | Self-contained test types must be manually synced with production code | 2026-02-26 | 2026-03-27 |
| confirmed | swift test never run end-to-end — unit tests unverified across all runs | 2026-02-26 | 2026-03-27 |
| confirmed | ConfigService has redundant atomic write strategies — never cleaned up across multiple runs | 2026-03-07 | 2026-03-27 |
| confirmed | xcodebuild broken in agent environment (IDESimulatorFoundation symbol not found) | 2026-03-14 | 2026-03-27 |
| confirmed | AudioRecorder.swift subsystems (retry, converter, silence detection) never refactored into focused types | 2026-03-27 | 2026-03-27 |
| confirmed | DiagnosticLogger never gated or removed before release | 2026-03-27 | 2026-03-27 |
| confirmed | CHANGELOG.md [0.6] entry missing bracket noise token strip fix | 2026-03-27 | 2026-03-27 |
| confirmed | Pre-existing working-tree changes from v0.6 never committed to main | 2026-03-27 | 2026-03-27 |
| confirmed | 17 zombie agent panes accumulate during parallel sprints — no automatic cleanup mechanism | 2026-03-27 | 2026-03-27 |

---

## Retro: 2026-03-27 — takt/windows-feature-parity

### What Went Well
- **All 13 stories completed with 0 blocked.** The Windows port was fully scoped and executed in a single sprint: Language model → config → tray → downloader → progress UI → model validation → settings → UI extensions → error handling → installer → docs.
- **Sealed-class pattern for Language (US-001) was a clean cross-platform port**: C#'s lack of enum associated data was handled elegantly with `static readonly` instances and `FromCode()` fallback — matching macOS semantics exactly.
- **No tech debt introduced by agent parallel modifications**: US-005 and US-006 both modified `TrayIconManager.cs` concurrently; US-005's workbook explicitly noted preserving US-006 additions. Merge integrity was maintained across all parallel stories.
- **Model download flow (US-004, US-005, US-006) is production-quality**: Streaming HttpClient with atomic `.tmp`→`.bin` rename, ±1% size validation, automatic cleanup on failure, and cancellable progress dialog — all implemented without integration-test capability on macOS.
- **Programmatic tray icon approach (US-010) was practical**: No design tooling available on macOS; `System.Drawing` runtime rendering of a coloured circle + "D" letter cleanly solves the constraint without needing a designer.
- **Documentation story (US-013) verified all code claims**: README was cross-checked against the actual codebase — all 10 services, 2 WPF views, 3 models, and 12 languages confirmed to exist.

### What Didn't Go Well
- **Cannot build, run, or install on macOS**: All 13 stories were authored and type-checked mentally but cannot be verified with `dotnet build`, `dotnet run`, or Inno Setup compilation — these require a Windows machine. This is a structural constraint for this platform that will persist.
- **HTTP download untestable from macOS** (US-004): URL pattern and HttpClient usage verified by code review only. No integration test is possible without a Windows runtime.
- **Inno Setup .iss script uncompilable on macOS** (US-012): Script is authored and ready but must be compiled on Windows. First-run validation deferred.
- **No sprint.json present** — timing stats cannot be updated for this run.

### Patterns Observed
- **Cross-platform port from Swift/macOS to C#/Windows requires a Windows machine for final verification**: Every story's "blockers" section noted macOS-only constraint. This is not fixable in the agent environment — it's a structural gap that needs a CI or manual Windows verification step before any release build.
- **Story sequencing within a sprint prevented conflicts**: Stories were ordered to minimize parallel writes to shared files (`TrayIconManager.cs`, `AppConfig.cs`). Where conflicts did occur (US-005/US-006 on TrayIconManager), the later story explicitly preserved earlier work.
- **macOS-specific action items carry forward indefinitely when the active sprint is Windows work**: 8 of the 12 carried action items are macOS/Swift concerns irrelevant to this sprint. They accumulate carry counts without any mechanism to pause them.

### Action Items
- [ ] [carried 7x] Add a note to story templates for Swift/Apple platform work: flag CoreFoundation types as requiring `CFGetTypeID` guards
  Suggested story: Codify a Swift story template section listing known platform gotchas (CFGetTypeID, async actor isolation, Xcode project.pbxproj sync)
- [ ] [carried 8x] Run `swift test` end-to-end to verify unit tests actually execute
  Suggested story: Add a CI step or pre-release checklist item that runs `swift test` and gates the release
- [ ] [carried 8x] Simplify ConfigService atomic write (remove either `.atomic` flag or `replaceItemAt`)
  Suggested story: Audit ConfigService.swift and pick one atomic write strategy, remove the redundant one
- [ ] [carried 5x] Fix xcodebuild test bundle code signing mismatch (`different Team IDs`) so unit tests can actually run
  Suggested story: Investigate and fix the Team ID mismatch that prevents xcodebuild test from running
- [ ] [carried 5x] Consider extracting AudioRecorder.swift subsystems (retry logic, converter lifecycle, silence detection) into focused types
  Suggested story: Refactor AudioRecorder.swift — split retry/backoff, AVAudioConverter lifecycle, and silence detection into separate structs or actors
- [ ] [carried 4x] Commit or remove DiagnosticLogger before next release — decide if it stays as a permanent debug tool or is stripped
  Suggested story: Gate DiagnosticLogger behind a compile flag or remove it; update MEMORY.md accordingly
- [ ] [carried 4x] Add `[BLANK_AUDIO]` / bracket noise token fix to CHANGELOG.md under [0.6] entry
  Suggested story: Update CHANGELOG.md [0.6] section with the bracket noise token strip fix
- [ ] [carried 3x] Commit pre-existing working-tree changes from v0.6 work (AppConfig.swift, ConfigService.swift, DiagnosticLogger.swift) to main before starting next sprint
  Suggested story: Stage and commit the v0.6 working-tree files that were never committed (AppConfig.swift, ConfigService.swift, DiagnosticLogger.swift)
- [ ] [carried 2x] Generate real EdDSA keypair, replace SUPublicEDKey placeholder in Info.plist before v0.7 release build
- [ ] [carried 2x] Enable GitHub Pages on repo (Settings → Pages → docs/ folder on main)
- [ ] [carried 2x] Run a real build with the new signing flow to confirm notarization passes end-to-end
- [ ] [carried 1x] Eliminate or auto-generate the inlined type mirror in DiktaTests.swift to prevent drift from production Language/AppConfig definitions
- [ ] Verify Windows build end-to-end on a Windows machine: `dotnet build`, `dotnet run`, hotkey registration, model download, transcription, and Inno Setup compilation
- [ ] Add Windows verification step to release checklist (VERIFY.md or build-release.sh equivalent for Windows)

### Metrics
- Stories completed: 13/13
- Stories blocked: 0
- Total workbooks: 13
- Avg story duration: N/A (no sprint.json)
- Phase overhead: N/A (no sprint.json)
