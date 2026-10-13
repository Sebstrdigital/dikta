# Read Aloud cue and About updates — BUILD outcome

## Candidate and disposition

Implementation and automated verification accepted after independent inspection with no required corrections. Starting revision: `facb802461566be98d54da1daf42543b33b03f94`. The task-owned source hashes are retained in `evidence/build/candidate.sha256`; the complete implementation diff, including the added About tests, is in `evidence/build/task.patch`. The commit containing this outcome is the source candidate; documentation added after testing does not change those verified source hashes.

The user requested **BUILD** of the saved plan. Commit/push of validated follow-ups is authorized. Stage only task-owned implementation, regression tests, architecture notes, this outcome, and the saved plan. Preserve unrelated `docs/TODO.md`, untracked workflow/evidence files, and all old artifacts. No tag, appcast, upload, release, installation/reload, app-stop, harness update, or artifact cleanup is authorized or performed.

This is an automated-validated source candidate, **not** a manually qualified release. The installed app and old v1.5.7 DMG are unchanged. Do not publish that DMG as containing these newer fixes; an eventual release must match its final source candidate.

## Implemented behavior

- Read Aloud keeps preparation feedback silent and retains the hourglass. The first owned, uncanceled playback-scheduled callback publishes the speaker phase before the dedicated start cue. The generating-phase guard prevents duplicate/chunk cues. Ownership and task-cancellation guards reject late/stale callbacks. Existing explicit-cancel stop feedback, natural completion cleanup, errors, voice/speed snapshots, and Stop Speaking remain intact.
- About always offers **Check for Updates…**, or **vX.Y available…** when the shared updater knows a pending version. Sparkle's KVO availability disables the action during an active session, and the controller rechecks availability before activation. Automatic Updates now says **Automatically check for new versions daily**. No new updater, timer, forced check, or consent/preference override was added.
- Added five pure About display/action regressions without constructing setup or a live updater. Updated Read Aloud expectations and added playback-stop coverage. Fake feedback observes phase-at-cue; fake TTS automatically schedules successful auto-completing reads while retaining explicit deferred/duplicate/stale callback control.

## Actual validation

All test invocations used `Dikta-UltraValidation` in **Release**, destination `platform=macOS`, manual Developer ID signing, team `UUM29335B4`, and `ENABLE_TESTABILITY=YES`. Exact invocation arguments and full unfiltered output are retained at the start of each local log. Commands follow [the plan](plan.md#validation-commands-and-safety) and `docs/validation.md`. Each paired `.exit` file records the true xcodebuild exit.

| Gate | Result | Local evidence under `evidence/build/` |
|---|---|---|
| Fresh effective-host isolation | 1 executed, 0 failures; exit 0 | `isolation.log`, `isolation.exit` |
| Fresh integrated baseline | 730 executed, 11 skipped, 0 failures; exit 0 | `baseline.log`, `baseline.exit` |
| Read Aloud RED | 32 executed, 1 skipped, 15 intended failed assertions; exit 65 | `cue-red.log`, `cue-red.exit` |
| Read Aloud GREEN | 32 executed, 1 skipped, 0 failures; exit 0 | `cue-green.log`, `cue-green.exit` |
| About RED | 5 executed, 10 intended failed assertions; exit 65 | `about-red.log`, `about-red.exit` |
| About + Read Aloud GREEN | 37 executed, 1 skipped, 0 failures; exit 0 | `about-green.log`, `about-green.exit` |
| Final focused candidate | 38 executed, 1 skipped, 0 failures; exit 0 | `final-focused-2.log`, `final-focused-2.exit` |
| Final integrated candidate | 736 executed, 11 skipped, 0 failures; exit 0 | `final-integrated-2.log`, `final-integrated-2.exit` |
| Deep/strict signature verification | Developer ID app, hardened runtime, expected team; exit 0 | `signature.log`, `signature.exit` |
| Whitespace/diff inspection | `git diff --check` passed; task-only source/test/doc diff inspected | `task.patch`, `candidate.sha256` |

The initial green runs and first final runs remain retained; the `-2` final logs cover the final test callback's weak ViewModel capture as well. The fresh isolation test proved both effective test-host paths: `DIKTA_CONFIG_FILE=/tmp/dikta-team-polish-validation/config/config.json` and `DIKTA_REAL_SESSIONS_DIR=/tmp/dikta-team-polish-validation/empty-real-sessions`. The config is synthetic and the session directory empty.

Integrated runs used only the existing four real-muter absence-test exclusions (Teams, Slack, WhatsApp, Uven). Those exclusions and the 11 actual skips remain coverage gaps, not a full-suite pass. No private sessions, clipboard/selection contents, real model qualification, real microphone/system capture, or live appcast test was used. These detailed logs/hash/diff files are retained locally, not published as release artifacts.

## Review

Independent inspection by `cue-about-integrated-review` approved the exact candidate with **no blockers or required corrections**. The reviewer inspected the complete task diff, relevant surrounding source, regression tests, signing and validation evidence. Lead inspection additionally reconciled task ownership and removed a strong test callback capture before final verification.

Nonblocking reviewer suggestion: qualify actual SwiftUI/KVO availability transitions in an authorized preview/session. Pure presentation tests are not proof of rendered UI or a live Sparkle session.

## Consolidated manual checklist — pending authorization

Use synthetic/public text and injected synthetic update state; do not access private selection, recordings, or live appcast data implicitly.

- Cold/slow and warm/progressive reads: hourglass during preparation; visually inspect speaker/cue ordering; one cue rather than per-chunk feedback; natural return to idle.
- Cancel during preparation and playback; verify no stale icon/start cue and retained stop behavior.
- About: manual link visible with automatic checks disabled, known-version label with synthetic state, daily copy and layout fit, existing preference preserved.
- Actual Sparkle availability/KVO: initial enabled state, disabled during a session, re-enabled afterward. A live network/update/install check needs separate authority.

Scheduling callbacks do not measure audible onset; publishing SwiftUI phase before cue invocation does not prove the menu-bar frame rendered first. No preview, installation, app stop, or live Sparkle check was performed.

**Next action:** authorize a narrowly isolated preview/manual qualification if these visual/audio paths need qualification before a separately authorized matching final release.
