# Active Alerts

| Status | Alert | First Seen | Last Seen |
|--------|-------|------------|-----------|
| mitigated | Workers unable to use Bash (background agents denied, foreground requires constant approval) | 2026-02-20 | 2026-03-07 |
| confirmed | Self-contained test types must be manually synced with production code | 2026-02-26 | 2026-03-27 |
| confirmed | swift test never run end-to-end — unit tests unverified across all runs | 2026-02-26 | 2026-03-27 |
| confirmed | ConfigService has redundant atomic write strategies — never cleaned up across multiple runs | 2026-03-07 | 2026-03-27 |
| confirmed | xcodebuild broken in agent environment (IDESimulatorFoundation symbol not found) | 2026-03-14 | 2026-03-27 |

---

## Retro: 2026-03-27 — takt/expanded-languages

### What Went Well
- **All 5 stories completed with no blocked stories.** The language expansion was well-scoped: US-001 (enum) → US-002 (config) → US-003 (carousel) → US-004 (menu) → US-005 (tests) flowed as a clean dependency chain.
- **US-005 grew the test suite from 27 to 68 tests (+41 new tests)** covering language metadata, carousel filtering, and AppConfig decoding — significant coverage increase in a single story.
- **Backward-compat persistence in US-002 was handled cleanly**: `decodeIfPresent` with a default of all-languages-enabled means existing user configs silently upgrade with no data loss.
- **No workarounds or tech debt introduced**: Each story was self-contained and surgical. US-003's `next(in:)` design (filtering to `enabledLanguages` at the call site in `MenuBarViewModel`) avoided scattering guard logic.

### What Didn't Go Well
- **xcodebuild broken in agent environment — third consecutive run**: `IDESimulatorFoundation` symbol-not-found error blocked compilation verification in US-002, US-003, and US-004. Agents fell back to `swiftc -typecheck` and manual code reading. This is now a confirmed recurring blocker.
- **Self-contained test types in US-005 required manual sync**: The inlined `Language` enum and `AppConfig` struct in `DiktaTests.swift` had to be extended manually to match production additions. Any future production change risks silent drift.
- **No sprint.json present** — timing stats cannot be updated for this run.

### Patterns Observed
- **xcodebuild is consistently unavailable in the agent environment**: This is the third run where agents cannot compile or run tests via xcodebuild. Typecheck-via-swiftc and code reading are the consistent fallback. The underlying cause (Team ID mismatch + IDESimulatorFoundation) is the same each time.
- **Test mirroring in DiktaTests.swift is a maintenance liability**: As the Language enum grows (3 → 12 cases across the sprint history), the inlined copy grows in lockstep. This was noted as `potential` two retros ago; US-005 confirms it as a structural pattern.
- **Feature sprints execute cleanly when stories are properly sequenced**: All 5 stories ran to completion in one pass. The dependency ordering (data model → config → logic → UI → tests) proved effective.

### Action Items
- [ ] [carried 6x] Add a note to story templates for Swift/Apple platform work: flag CoreFoundation types as requiring `CFGetTypeID` guards
  Suggested story: Codify a Swift story template section listing known platform gotchas (CFGetTypeID, async actor isolation, Xcode project.pbxproj sync)
- [ ] [carried 7x] Run `swift test` end-to-end to verify unit tests actually execute
  Suggested story: Add a CI step or pre-release checklist item that runs `swift test` and gates the release
- [ ] [carried 7x] Simplify ConfigService atomic write (remove either `.atomic` flag or `replaceItemAt`)
  Suggested story: Audit ConfigService.swift and pick one atomic write strategy, remove the redundant one
- [ ] [carried 4x] Fix xcodebuild test bundle code signing mismatch (`different Team IDs`) so unit tests can actually run
  Suggested story: Investigate and fix the Team ID mismatch that prevents xcodebuild test from running
- [ ] [carried 4x] Consider extracting AudioRecorder.swift subsystems (retry logic, converter lifecycle, silence detection) into focused types
- [ ] [carried 3x] Commit or remove DiagnosticLogger before next release — decide if it stays as a permanent debug tool or is stripped
  Suggested story: Gate DiagnosticLogger behind a compile flag or remove it; update MEMORY.md accordingly
- [ ] [carried 3x] Add `[BLANK_AUDIO]` / bracket noise token fix to CHANGELOG.md under [0.6] entry
  Suggested story: Update CHANGELOG.md [0.6] section with the bracket noise token strip fix
- [ ] [carried 2x] Commit pre-existing working-tree changes from v0.6 work (AppConfig.swift, ConfigService.swift, DiagnosticLogger.swift) to main before starting next sprint
- [ ] [carried 1x] Generate real EdDSA keypair, replace SUPublicEDKey placeholder in Info.plist before v0.7 release build
- [ ] [carried 1x] Enable GitHub Pages on repo (Settings → Pages → docs/ folder on main)
- [ ] [carried 1x] Run a real build with the new signing flow to confirm notarization passes end-to-end
- [ ] Eliminate or auto-generate the inlined type mirror in DiktaTests.swift to prevent drift from production Language/AppConfig definitions

### Metrics
- Stories completed: 5/5
- Stories blocked: 0
- Total workbooks: 5
- Avg story duration: N/A (no sprint.json)
- Phase overhead: N/A (no sprint.json)
- Test count: 27 → 68 (+41 new tests added in US-005)
