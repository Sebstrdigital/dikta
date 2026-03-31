# Active Alerts

| Status | Alert | First Seen | Last Seen |
|--------|-------|------------|-----------|
| mitigated | Workers unable to use Bash (background agents denied, foreground requires constant approval) | 2026-02-20 | 2026-03-07 |
| mitigated | Self-contained test types must be manually synced with production code | 2026-02-26 | 2026-03-29 |
| confirmed | swift test never run end-to-end — unit tests unverified across all runs | 2026-02-26 | 2026-03-31 |
| confirmed | ConfigService has redundant atomic write strategies — never cleaned up across multiple runs | 2026-03-07 | 2026-03-31 |
| confirmed | xcodebuild broken in agent environment (IDESimulatorFoundation symbol not found) | 2026-03-14 | 2026-03-31 |
| confirmed | AudioRecorder.swift subsystems (retry, converter, silence detection) never refactored into focused types | 2026-03-27 | 2026-03-31 |
| confirmed | DiagnosticLogger never gated or removed before release | 2026-03-27 | 2026-03-31 |
| confirmed | CHANGELOG.md [0.6] entry missing bracket noise token strip fix | 2026-03-27 | 2026-03-31 |
| confirmed | Pre-existing working-tree changes from v0.6 never committed to main | 2026-03-27 | 2026-03-31 |
| confirmed | 17 zombie agent panes accumulate during parallel sprints — no automatic cleanup mechanism | 2026-03-27 | 2026-03-31 |
| confirmed | Test file inline-copy of production formatters is a permanent manual burden — no automation | 2026-03-29 | 2026-03-31 |

---

## Retro: 2026-03-31 — takt/embedding-paragraph-splitting

### What Went Well
- **All 4 stories completed with 0 blocked, 0 failures.** Sequential dependency chain (US-001 → US-002 → US-003 → US-004) ran cleanly with no merge conflicts.
- **US-001 navigated a real toolchain obstacle without blocking**: The `torch.jit.trace` approach failed due to a coremltools 9/torch 2.11 incompatibility. The agent pivoted to `torch.export` + `ExportedProgram` (ATEN dialect), the documented path for torch 2.x — no human intervention needed.
- **Int8 quantisation brought the model well within budget**: FP32 ONNX was ~126 MB; int8 CoreML landed at 32.0 MB, leaving 8 MB of headroom against the 40 MB target.
- **Custom WordPiece tokenizer in Swift was a clean solution**: Reusing swift-transformers' BertTokenizer was correctly rejected (significant refactor required). The bespoke implementation covers lower-case, accent stripping, punctuation splitting, and WordPiece segmentation — sufficient for MiniLM-L12-v2 and contained entirely in `SentenceEmbeddingService.swift`.
- **US-003 integration design is future-proof**: Embedding splitter is an optional property (`nil` default) so all 203 existing tests remain heuristic-only without any test changes. Embedding breaks are unioned with heuristic boundaries, never replacing them — safe for unknown inputs.
- **US-004 language-aware fallback is conservative by design**: Swedish (and Nordic languages) excluded from embedding support; `supportsEmbeddings` flag on Language enum gates the path cleanly. Lazy loading via static cache on `FormatterEngine` defers first-load cost to first format hotkey press.

### What Didn't Go Well
- **US-003 hit a Swift access control issue**: The test stub `EmbeddingParagraphSplitter` needed to be `internal` (not `private`) because `StructuredTextFormatter.embeddingSplitter` is `internal`. Minor but required a rework.
- **Inline-copy burden persists**: US-003 notes explicitly flag that `FormatterTests.swift` inlines production types and any production changes must be mirrored. This sprint added another production type (`EmbeddingParagraphSplitter` protocol/stub) to the mirror surface.
- **Depth threshold uncalibrated**: US-002 notes that 0.15–0.20 range is a prototype estimate and the threshold needs validation against the full 203-test corpus. This was deferred as a known issue.
- **MiniLM multilingual coverage boundary unverified**: US-004 excluded Swedish/Nordic based on known MiniLM limitations, but exact language support was flagged as requiring testing.

### Patterns Observed
- **Complex infrastructure stories (large) take 6–10x longer than small formatter stories**: US-001 took 930s, US-002 took 436s vs. the small story avg of 236s. ML model conversion and service wiring carry inherent overhead.
- **Graceful degradation as a design pattern is maturing**: Three sprints in a row have used the nil-optional / fallback-to-heuristic pattern. It's becoming a convention in the formatter layer.
- **Inline-copy technical debt is compounding**: Each new production type added to `StructuredTextFormatter` expands the mirror surface in `FormatterTests.swift`. Now carried 3 sprints — escalating to confirmed alert status.

### Action Items
- [ ] [carried 10x] Add a note to story templates for Swift/Apple platform work: flag CoreFoundation types as requiring `CFGetTypeID` guards
  Suggested story: Codify a Swift story template section listing known platform gotchas (CFGetTypeID, async actor isolation, Xcode project.pbxproj sync)
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
- [ ] [carried 5x] Generate real EdDSA keypair, replace SUPublicEDKey placeholder in Info.plist before v0.7 release build
  Suggested story: Generate EdDSA keypair, insert SUPublicEDKey into Info.plist, verify Sparkle update signature end-to-end
- [ ] [carried 5x] Enable GitHub Pages on repo (Settings → Pages → docs/ folder on main)
  Suggested story: Enable GitHub Pages on the dikta repo pointing to docs/ on main
- [ ] [carried 5x] Run a real build with the new signing flow to confirm notarization passes end-to-end
  Suggested story: Run build-release.sh and confirm notarization completes without errors
- [ ] [carried 3x] Verify Windows build end-to-end on a Windows machine: `dotnet build`, `dotnet run`, hotkey registration, model download, transcription, and Inno Setup compilation
  Suggested story: Set up a Windows test environment and run Dikta Windows end-to-end smoke test
- [ ] [carried 3x] Add Windows verification step to release checklist (VERIFY.md or build-release.sh equivalent for Windows)
  Suggested story: Create VERIFY.md with a Windows smoke test checklist aligned with build-release.sh steps
- [ ] [carried 3x] Eliminate the inline-copy pattern in FormatterTests.swift — either refactor tests to import production types directly or generate the inline via a build script
  Suggested story: Refactor FormatterTests.swift to remove inlined StructuredTextFormatter and MessageFormatter structs, replacing with direct imports of production types
- [ ] Calibrate embedding depth threshold — validate 0.15–0.20 range against full 203-test formatter corpus
  Suggested story: Run EmbeddingParagraphSplitter against all 203 formatter test inputs, measure false-positive/negative rate, tune threshold
- [ ] Verify MiniLM multilingual coverage boundaries — test Swedish, Finnish, Norwegian, Danish against embedding splitter to confirm exclusion is correct
  Suggested story: Manually test 5–10 Nordic-language inputs through EmbeddingParagraphSplitter and document findings in a comment on supportsEmbeddings

### Chronic Tech Debt
- [ ] [carried 11x] Run `swift test` end-to-end to verify unit tests actually execute
  Suggested story: Add a CI step or pre-release checklist item that runs `swift test` and gates the release
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.
- [ ] [carried 11x] Simplify ConfigService atomic write (remove either `.atomic` flag or `replaceItemAt`)
  Suggested story: Audit ConfigService.swift and pick one atomic write strategy, remove the redundant one
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.

### Metrics
- Stories completed: 4/4
- Stories blocked: 0
- Total workbooks: 4
- Story durations: US-001 930s (large), US-002 436s (large), US-003 253s (medium), US-004 181s (medium)
- Avg story duration: 683s (large, this run) — running avg 652s (large, all runs); 217s (medium, this run) — running avg 286s (medium, all runs)
- Phase overhead: not available (retro start time not captured)
