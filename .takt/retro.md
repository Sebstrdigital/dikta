# Active Alerts

| Status | Alert | First Seen | Last Seen |
|--------|-------|------------|-----------|
| mitigated | Self-contained test types must be manually synced with production code | 2026-02-26 | 2026-03-29 |
| mitigated | swift test never run end-to-end — unit tests unverified across all runs | 2026-02-26 | 2026-09-28 |
| mitigated | ConfigService has redundant atomic write strategies — never cleaned up across multiple runs | 2026-03-07 | 2026-09-28 |
| confirmed | AudioRecorder.swift subsystems (retry, converter, silence detection) never refactored into focused types | 2026-03-27 | 2026-04-17 |
| confirmed | CHANGELOG.md [0.6] entry missing bracket noise token strip fix | 2026-03-27 | 2026-04-17 |
| confirmed | 17 zombie agent panes accumulate during parallel sprints — no automatic cleanup mechanism | 2026-03-27 | 2026-04-17 |
| confirmed | Test file inline-copy of production formatters is a permanent manual burden — no automation | 2026-03-29 | 2026-04-17 |
| confirmed | Windows build never verified end-to-end on actual Windows hardware | 2026-04-17 | 2026-04-17 |
| potential | Account usage limit hit mid-sprint — spawned workers terminated, session agent completed remaining stories | 2026-04-17 | 2026-04-17 |
| confirmed | WithNoSpeechThreshold method name unverified — Whisper.net 1.9.0 may use different API | 2026-04-17 | 2026-04-17 |
| potential | Worker agents create files that already exist, clobbering prior sprint work — no existence check before write | 2026-04-17 | 2026-04-17 |
| confirmed | Story templates never got a Swift/Apple platform-gotchas section (CFGetTypeID guards, actor isolation, pbxproj sync) — chronic, carried 14 sprints without resolution | 2026-02-26 | 2026-09-28 |
| potential | takt-run.js cuts multi-story-wave Workflow worktrees from the launch-time HEAD instead of the branch tip, blocking or duplicating stories that depend on an earlier wave's commits | 2026-09-28 | 2026-09-28 |
| potential | run.md documents `waves` as `[{wave, stories}]` but takt-run.js expects `[[ids]]` — schema mismatch between orchestrator docs and implementation | 2026-09-28 | 2026-09-28 |
| potential | Bench result files get force-added past .gitignore, caught only at the review gate (not verification) | 2026-09-28 | 2026-09-28 |

---

## Retro: 2026-09-28 — takt/parakeet-engine

### What Went Well
- **10/10 stories delivered** across two takt runs (US-001–US-010) plus one bug fix (BUG-001), with no story-level failures — every blocker this sprint traced back to orchestration tooling, not implementation.
- **Two chronic tech-debt items resolved in one sprint.** US-001 collapsed ConfigService's two atomic-write strategies into one (`write-to-temp` + `replaceItemAt`), and US-002 added a real enforcement gate to `build-release.sh` and CI that fails the build if `DiktaTests` didn't actually execute (zero-matched or non-zero exit). Both had been carried unresolved for 14 sprints.
- **The documented signed `xcodebuild test` invocation is now consistently reliable.** US-002, US-003, US-007, and US-008 each ran the full `DiktaTests` target for real (645–669 tests) using `CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=UUM29335B4`, with zero infrastructure failures — a marked change from the long-standing "xcodebuild broken in agent environment" pattern.
- **US-007's engine seam reused existing code instead of duplicating it.** `ParakeetEngine` calls `Transcriber.cleanSegments`/`.sanitizeAndDropEmpty`/`.sortMonotonic` directly rather than re-implementing sanitization, and US-008 got the Swedish KB-Whisper fallback "for free" by reusing `effectiveModel(for:)` instead of writing a new special case.
- **BUG-001 closed cleanly and fast** — a one-line docs sync (missing test class in `docs/validation.md`), verified by `grep`, finished in 12 seconds with no source touched.

### What Didn't Go Well
- **Run 1 blocked 4 of 10 stories (US-004, US-006, US-009, US-010)** because multi-story-wave Workflow worktrees were cut from the launch-time HEAD rather than the branch tip — a `takt-run.js`/Workflow isolation bug, not a story defect. A second run finished the four sequentially.
- **`run.md` and `takt-run.js` disagree on the `waves` shape**: the doc describes `[{wave, stories}]`, the code expects `[[ids]]`. This is very likely a contributing factor to (or at least masks debugging of) the worktree-HEAD bug above.
- **Commit history shows the wave-1/2 stories (US-001, US-002, US-003, US-005) each landed as two back-to-back commits** (e.g. `b0d9a5c`/`a7330ab` for US-001 — identical trees) — a visible artifact of recovering from the worktree bug, not real duplicate work. One side effect: **workbook files for US-001 and US-005 are missing from `.takt/workbooks/`** even though both stories are complete and committed (confirmed via `git log` and via US-004/US-007/US-008/US-010 workbooks that reference their output) — this retro could not cite either story's own decisions/blockers directly.
- **Verification cycles 1–2 re-opened BUG-001 on false positives** (an unregistered test file, a stale doc line) before landing on the real regression — a Swift 6 strict-concurrency break introduced by the tools-version 6.0 bump.
- **Review gate cycle 1 blocked on three issues that verification missed entirely**: a shared `TdtDecoderState` leaking context across takes, `appcast` `minimumSystemVersion` left at 14.0 against the new 15.0 target, and 12 bench result files force-added past `.gitignore`. All three were fixed in one commit (`37155f2`) and cycle 2 passed.
- **`swift build` (plain SPM, no `xcodebuild` scheme) now fails from Swift 6 strict-concurrency errors in at least 3 files** (`FormatterEngine.swift`, `bench/TimestampProbe/main.swift`, `RollingDebriefSummarizer.swift`) that predate this sprint — masked because the project's actual documented gate (`xcodebuild`) doesn't hit them. Confirmed pre-existing in US-004, US-006, and US-007's workbooks by reproducing with this sprint's own changes removed.

### Patterns Observed
- **Orchestration-tooling bugs, not implementation bugs, are now the primary blocker class.** Every one of this sprint's 10 stories succeeded on its own merits; the only blocking issue was the worktree/HEAD bug in the takt runner itself.
- **`DebriefRealTranscriptTests`'s environment-dependent failure surfaced independently in 4 workbooks** (US-003, US-007, US-008, US-010) as the same pre-existing, non-regression failure (a local `~/Documents/Dikta` session too short to yield a decision/action item). Worth the `XCTSkip` fix flagged below rather than re-diagnosing it every sprint.
- **`swift build`'s plain-SPM path is silently drifting from the project's real gate.** Three unrelated files now fail Swift 6 strict-concurrency checks only under `swift build`, not `xcodebuild` — a gap that will surface the moment anyone relies on `swift build`/`swift test` for fast iteration instead of the documented signed `xcodebuild` command.
- **Environment-coupled tests keep causing one-off flakes unrelated to the story at hand.** US-003 hit `MicMutingTests.testWhatsAppMuterReturnsNilWhenWhatsAppNotRunning` failing simply because WhatsApp happened to be running on the build machine — the same class of problem as the already-tracked `DebriefRealTranscriptTests` issue.

### Action Items
- [ ] Fix `takt-run.js`'s worktree creation to branch off the wave's actual HEAD at wave-start time, not a cached launch-time SHA.
  Suggested story: Patch the Workflow worktree-creation step so each wave's worktree is created from the current branch tip, not a stale launch-time reference.
- [ ] Reconcile `run.md`'s documented `waves` shape (`[{wave, stories}]`) with what `takt-run.js` actually expects (`[[ids]]`).
  Suggested story: Pick one shape and make the other match — either update `run.md`'s docs or fix `takt-run.js`'s parser.
- [ ] Guard bench result files from being force-added past `.gitignore` before they reach the review gate.
  Suggested story: Add a pre-commit or verification-phase check that rejects any staged file under `dikta-macos/bench/results` or `bench/data`, even if force-added.
- [ ] Add an `XCTSkip` guard to `DebriefRealTranscriptTests` when the local real session is too short to yield a decision/action item, instead of asserting on it (hit independently in US-003, US-007, US-008, US-010).
  Suggested story: Extend the existing "no local sessions found" skip path in `DebriefRealTranscriptTests` to also skip when the only available session(s) are too short.
- [ ] Add a startup fallback when a persisted Parakeet engine fails to load — today only the live `setEngine` failure path falls back to the previous engine; a corrupted/missing cached Parakeet model at app launch has no equivalent.
  Suggested story: Extend `MenuBarViewModel`'s startup engine resolution to catch a Parakeet load failure and fall back to Whisper, mirroring `setEngine`'s failure-restore behavior.
- [ ] Merge Parakeet's one-segment-per-word output into utterance-level segments before the Me/Them debrief interleave.
  Suggested story: Add a segment-merging pass between `ParakeetEngine.transcribeSegments` and the Me/Them interleave step that groups word-level segments back into sentence/utterance-level ones.
- [ ] Verify whether the macOS 15 deployment floor is required by FluidAudio generally or only by the Redux variant, and narrow the docs/release-notes claim if it's narrower than stated.
  Suggested story: Check FluidAudio's per-variant minimum-OS requirement (Redux vs v3/Ultra) and correct `docs/architecture.md` / the CHANGELOG if only Redux needs 15.0.
- [ ] Add a test asserting the old engine's unload/deinit path actually runs across a `setEngine` switch (review gate cycle 2 suggestion, not yet implemented).
  Suggested story: Add an unload counter to `FakeTranscriptionEngine`, switch engines twice via `setEngine` in a test, and assert the old engine's counter incremented.
- [ ] Make `MicMutingTests` independent of which chat apps happen to be running on the dev machine, and add Slack/Teams coverage (only WhatsApp is currently asserted).
  Suggested story: Inject a fake "is app running" check into the muter classes instead of relying on real `NSWorkspace`/`pgrep` state.
- [ ] [carried 4x] Verify `WithNoSpeechThreshold` is the correct Whisper.net 1.9.0 method name — US-010 (Windows sprint) notes it may be `WithNoSpeechProb` or similar.
  Suggested story: On a Windows build machine, compile dikta-windows and confirm TranscriberService builds cleanly with the threshold wiring.
- [ ] [carried 2x] [takt finding] Add explicit file-existence check to worker prompts: "Do NOT create a file if it already exists — read it first and edit in place." Apply to all takt worker templates.
  Suggested story: Audit takt worker prompt templates and add a pre-write guard: check file existence before any Write call, prefer Edit over Write for existing files.
- [ ] [carried 2x] Review TrayIconManager.cs for cohesion — 10+ stories across 4 Windows sprints have added to it; consider splitting responsibilities.
  Suggested story: Audit TrayIconManager.cs, extract menu-building logic or DIAGNOSTICS-only items into a separate class if warranted.

### Chronic Tech Debt
- [ ] [carried 14x] Add a note to story templates for Swift/Apple platform work: flag CoreFoundation types as requiring `CFGetTypeID` guards.
  Suggested story: Codify a Swift story template section listing known platform gotchas (CFGetTypeID, async actor isolation, Xcode project.pbxproj sync).
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.
- [ ] [carried 12x] Consider extracting AudioRecorder.swift subsystems (retry logic, converter lifecycle, silence detection) into focused types.
  Suggested story: Refactor AudioRecorder.swift — split retry/backoff, AVAudioConverter lifecycle, and silence detection into separate structs or actors.
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.
- [ ] [carried 11x] Add `[BLANK_AUDIO]` / bracket noise token fix to CHANGELOG.md under the [0.6] entry.
  Suggested story: Update CHANGELOG.md's [0.6] section with the bracket noise token strip fix.
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.
- [ ] [carried 7x] Verify Windows build end-to-end on a Windows machine: `dotnet build`, `dotnet run`, hotkey registration, model download, transcription, and Inno Setup compilation.
  Suggested story: Add a Windows smoke-test checklist to VERIFY.md or the release runbook; run it manually before every Windows release.
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.
- [ ] [carried 7x] Add a Windows verification step to the release checklist (VERIFY.md or a build-release.sh equivalent for Windows).
  Suggested story: Create dikta-windows/RELEASE.md with build, smoke-test, and Inno Setup steps.
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.
- [ ] [carried 7x] Eliminate the inline-copy pattern in FormatterTests.swift — either refactor tests to import production types directly or generate the inline copy via a build script.
  Suggested story: Refactor FormatterTests.swift to remove the inlined StructuredTextFormatter and MessageFormatter structs, replacing with direct imports of production types.
  This item should be included as a story in the next sprint, or explicitly dismissed with a reason.

### Metrics
- Stories completed: 10/10 (US-001–US-010, across two takt runs) + 1 bug fixed (BUG-001)
- Stories blocked: 0 permanently (4 temporarily blocked in run 1 by the worktree-HEAD bug; all 4 completed in run 2)
- Total workbooks processed: 9 (workbook-BUG-001, US-002, US-003, US-004, US-006, US-007, US-008, US-009, US-010 — US-001 and US-005 workbooks are missing despite both stories being complete, see "What Didn't Go Well")
- Avg story duration: 236s (small, n=34), 354s (medium, n=20), 674s (large, n=5)
- This sprint's own story durations: small 350.7s avg (US-001 409s, US-002 341s, US-005 302s); medium 616.6s avg (US-003 476s, US-004 836s, US-006 505s, US-009 243s, US-010 1023s); large 739s avg (US-007 728s, US-008 750s); BUG-001 12s
- Phase overhead: 7032s (from US-010's end at 1790580050 to retro start — covers BUG-001's fix, 3 verification cycles, review gate cycle 1 block + fix commit `37155f2`, and gate cycle 2)
- Timing stats: small updated (avg 236s, n=34); medium updated (avg 354s, n=20); large updated (avg 674s, n=5); overhead updated (avg 2025s, n=6)

---

## Retro: 2026-09-29 — dikta/takt/shadow-participant

### What Went Well
- All 6 stories (US-001..US-006) passed first attempt; the tap-target seam (US-001) and shared ShadowJoinDriver (US-002) let both WKWebView and Chrome hosts produce identical state sequences (workbook US-002).
- Real-browser tests (headless Chrome and WKWebView against a fixture) ran inside the suite, and BUG-002 found via them that an off-screen window parks getUserMedia (workbook BUG-002).
- Every fix worker validated with a targeted suite plus the full DiktaTests run; the same single unrelated failure was consistently identified (US-001..US-006, MF-1, MF-4).

### What Didn't Go Well
- Gate cycle 2 BLOCKED on MF-1: shadow tap PIDs never resolved to CoreAudio process objects, so the tap silently became a global unmuted one. Unit tests used fake process listers, so nothing exercised the real lookup; only a live spike and a heavy worker fixed it (commit 54a328c).
- MF-2 (targeted tap muting) has no test seam: CATapDescription is built inline, so muteBehavior is unasserted (workbook MF-2).
- US-002/US-003 shipped Meet selectors and speaker/participant CSS as unverified placeholders; Chrome audioProcessIDs is the launched PID only although Chrome audio comes from helper processes.
- Review took 3 gate cycles plus 2 verify-cycle bug fixes before PASS (13 suggestions remain).

### Patterns Observed
- Live-system behaviour (CoreAudio process objects, real Meet DOM, Chrome helper PIDs) was faked in tests and surfaced only at review or manual check; same class as the earlier Parakeet retro finding that fantasy inputs hide defects.
- DebriefRealTranscriptTests.test_heuristic_onRealTranscripts fails in every workbook; environmental (needs local real sessions), already in TODO as the XCTSkip item.
- Fixture fidelity issues (hidden Leave button matched admittedCSS, US-003) again show test fixtures drifting from real DOM behaviour.

### Tooling issues
- Run report `.takt/run-report.json` was absent, so verify/gate/fix/merge phase timing and overhead could not be computed. The gate-cycle-3 fix ran outside the workflow, so its worker has no workbook (MF-1 workbook records the earlier 12h backstop change only).
- Stories have no `attempts` field in sprint.json; retries counted as 1 per the retro rule.

### Project follow-ups
- Verify Meet join selectors, participant and active-speaker CSS against a live Google Meet call.
- Check Chrome host audio tap: Chrome audio comes from helper processes, but audioProcessIDs returns only the launched PID.
- Verify WKWebView host audio PID lookup (libproc plus responsibility PID filter) against real audio.
- Add a seam so a test can assert CATapDescription muteBehavior (.mutedWhenTapped for targeted, .unmuted for global).
- After the 10 s wait the shadow commits to the unmuted global tap for the whole call: keep polling in the background until a PID resolves, then build the targeted tap.
- Re-target the tap when the tapped process restarts (Chromium audio service, WebKit GPU process); currently Them goes silent.
- Add a timeout to CDP send/evaluate in ChromeShadowHost.
- TwoTrackMerger.isLabeledTranscript only recognises Me:/Them:, so a transcript of only named lines is treated as unlabeled and heuristic summaries keep "Name: " prefixes.
- Remove the orphaned doc comment above defaultOutputDevice() in SystemAudioTapRecorder.swift.
- Exercise the Chrome host speaker-poller path in a test (only the WKWebView path is covered).

### Metrics
- Stories: 6/6 passed, 0 blocked; retried on heavy: 0 (blocked after retry: 0)
- Total workbooks: 12 (6 stories, 2 BUG, 4 MF)
- Avg story duration: n/a (small), 260s (medium, n=4), 288s (large, n=2)
- Verify: n/a (run report missing)
- Gate: 3 cycles, duration n/a
- Fix workers: 6 workbooks (BUG-001, BUG-002, MF-1..MF-4) plus 1 outside-workflow heavy fix (54a328c), duration n/a
- Merge/commit agents: n/a
- Unattributed overhead: n/a
