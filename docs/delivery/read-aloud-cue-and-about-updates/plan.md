# Read Aloud cue alignment and About update discoverability

## Status and restart entry

PLAN, BUILD, automated VERIFY, and REVIEW complete. The resumed user requested **BUILD**, authorizing execution of both agreed follow-ups under the saved boundaries. Fresh isolation/baseline, focused RED/GREEN, final signed Release gates, and independent inspection passed. See [outcome.md](outcome.md) for evidence, commit/push disposition, and the remaining manual qualification gaps. The original planning session authorized planning only; no Pi/harness update was performed during BUILD.

Source checkpoint: `facb802461566be98d54da1daf42543b33b03f94`, already committed and pushed to `origin/main`. The accepted installed v1.5.7 candidate and its retained DMG are unchanged. Preserve unrelated dirty `docs/TODO.md`, untracked workflow files, historical evidence and artifacts. Observe current state again after restart rather than assuming this checkpoint is still HEAD.

The user established a commit/push workflow for these follow-ups before tagging. Commit/push only completed, validated task-owned changes under that authority. **No tag, appcast change, release, upload, installation/reload, app stop or artifact cleanup** is authorized. Do not update/install Pi as part of this task.

## Objective and agreed behavior

### 1. Align the Read Aloud start cue with the speaker state

Keep the hourglass during selection, asset checks and initial speech generation. When the owned request receives its first playback-scheduled callback, transition to the speaker state and play the dedicated Read Aloud start cue together. Do not play that cue merely because the request was accepted.

Acceptance:
- No start cue during preparation/generation, including slow or cold startup.
- At the first valid playback callback, publish `.playbackScheduled` before invoking the start cue; the menu-bar speaker already maps to that phase.
- Exactly one start cue per request, even if a backend repeats the callback.
- Cancellation, failure or unavailable/empty selection before playback produces no start cue.
- Late callbacks from canceled/older requests cannot change the current request's phase or produce cues.
- Preserve request ownership, cancellation/Stop Speaking behavior, dedicated stop-cue conventions, error reporting and natural completion cleanup. In particular, retain the existing explicit-cancel stop cue for an accepted generating request; this tweak does not redesign stop feedback.
- Normal progressive playback produces one start cue, not one cue per chunk.

The existing callback means audio playback has been scheduled, **not measured audible onset**. Updating SwiftUI state before playing the cue does not alone prove the menu-bar frame has rendered; verify the visible ordering manually. Do not claim precise sample/frame synchronization or introduce arbitrary sleeps. If a visible lag remains, diagnose a proportionate rendering handoff instead of removing preparation feedback or redesigning audio scheduling without discussion.

Source evidence:
- `dikta-macos/Dikta/ViewModels/MenuBarViewModel.swift`: `performSpeakSelectedText` currently calls `audioFeedback.readAloudStart()` at accepted generation, before `ttsService.speak`; its playback callback later sets `.playbackScheduled`.
- `dikta-macos/Dikta/DiktaApp.swift`: menu-bar label uses an hourglass for all Read Aloud phases except `.playbackScheduled`, which uses `speaker.wave.2.fill`.
- `dikta-macos/Dikta/Services/TextToSpeechService.swift`: existing first-playback callback; reuse it rather than adding a new engine event.
- `dikta-macos/DiktaTests/MenuBarViewModelReadAloudTests.swift`, `FakeTextToSpeechService.swift`, `FakeAudioFeedback.swift`: existing controllable generation/playback and cue tests. Several current tests explicitly expect a start cue before synthesis and must be reconciled with the new contract, not simply removed.

### 2. Make update checking discoverable in About

Show an always-visible **“Check for Updates…”** link beside/beneath the installed version in the About/startup window. When the existing updater state reports a pending version, replace it with **“vX.Y available…”** (an actionable link into Sparkle's existing user-visible check/update flow). Change the Automatic Updates subtitle to **“Automatically check for new versions daily”**.

Acceptance:
- Manual check remains visible when no update is known and automatic checks are disabled.
- Known update version is shown using the existing shared `SparkleController` state.
- Manual activation uses the existing `checkForUpdates()` API; respect `updater.canCheckForUpdates` so an active updater session cannot be started again from the new control.
- No new forced startup check, custom timer, updater instance, network request on About appearance, or automatic preference override.
- Preserve Sparkle's user preference/consent and existing scheduled startup/daily behavior.
- No “up to date” claim based merely on an absent update badge.
- Keep the existing top-of-main-menu update indicator and Advanced action.

Source evidence:
- `dikta-macos/Dikta/Views/OnboardingWindow.swift`: header already conditionally shows an update link, but nothing when no update is known; Automatic Updates subtitle currently says “Check for new versions on launch”.
- `dikta-macos/Dikta/Services/SparkleController.swift`: one shared standard updater, started outside XCTest; exposes automatic-check preference, pending version and user-visible check action.
- `dikta-macos/Dikta/Views/MenuBarView.swift`: existing known-update item at the menu top and Advanced check action.
- `dikta-macos/Dikta/Resources/Info.plist`: feed/signing key configured; no custom scheduling interval or forced automatic-check default.
- Inspected local Sparkle `SPUUpdater.m` schedules a due check at startup based on the last check date; `SPUUpdaterSettings.m` defaults to 24 hours. This is source evidence, not proof of the user's installed preference or a live appcast check.

## Smallest implementation route

Use **Direct** delivery: two small serial changes, with fake-backed regression tests and one integrated signed Release verification. No new scheduler or mandatory worker ceremony.

1. Renew current Git/ownership observations and establish the required green signed Release baseline, proving effective-host isolation first. Inspect current relevant source/tests and `docs/validation.md`; do not modify code on an unexplained red baseline.
2. Read Aloud RED → GREEN: add/update focused tests for deferred start, phase-before-cue ordering, duplicate callback, failure/cancel before playback, and stale callback isolation; prove the intended failures, then move the cue into the owned first-playback transition with an idempotency guard. Update existing cue expectations and relevant behavior documentation.
3. About RED → GREEN where behavior is extracted: minimally expose a testable display/action state if necessary, cover unknown/known update and check-in-progress states without constructing a live updater or full setup window. Apply header/copy changes using existing styles. No UI framework or updater architecture rewrite. Static label/layout inspection is not a substitute for behavior tests, and model tests are not proof of rendered UI.
4. Run focused checks after each affected code change, then the integrated filtered signed Release target. Inspect the full task-owned diff and reconcile findings. Use independent inspection proportionately if state/ownership logic expands; do not label lead inspection independent review.
5. Report candidate identity, actual commands/counts/logs, manual gaps and review disposition. Commit/push only task-owned completed changes; no tag/publication. If live visual qualification needs a new preview/install or app stop, request that specific permission first rather than treating build authorization as installation permission.

## Validation commands and safety

Binding rules: `docs/validation.md` and repository `AGENTS.override.md`. Keep full unfiltered logs, true exits and positive executed counts. Use signed **Release**, never Debug or ad-hoc signing. Do not use `build-release.sh` as a test command.

Effective-host isolation first:
```bash
cd dikta-macos && xcodebuild test -project Dikta.xcodeproj -scheme Dikta-UltraValidation -only-testing:DiktaTests/TestHostIsolationTests -destination 'platform=macOS' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=UUM29335B4 ENABLE_TESTABILITY=YES
```
Verify both effective config and session paths are approved isolated/synthetic inputs; shell environment alone is not proof. The current scheme uses `/tmp/dikta-team-polish-validation/config/config.json` and `/tmp/dikta-team-polish-validation/empty-real-sessions`; re-inspect before testing.

Focused Read Aloud gate:
```bash
cd dikta-macos && xcodebuild test -project Dikta.xcodeproj -scheme Dikta-UltraValidation -only-testing:DiktaTests/MenuBarViewModelReadAloudTests -destination 'platform=macOS' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=UUM29335B4 ENABLE_TESTABILITY=YES
```
Add a focused filter for any new update-presentation regression class after discovering/registering it in the actual test target.

Integrated baseline and final gate:
```bash
cd dikta-macos && xcodebuild test -project Dikta.xcodeproj -scheme Dikta-UltraValidation -only-testing:DiktaTests -skip-testing:DiktaTests/MicMutingTests/testTeamsMuterReturnsNilWhenTeamsNotRunning -skip-testing:DiktaTests/MicMutingTests/testSlackMuterReturnsNilWhenSlackNotRunning -skip-testing:DiktaTests/MicMutingTests/testWhatsAppMuterReturnsNilWhenWhatsAppNotRunning -skip-testing:DiktaTests/MicMutingTests/testUvenMuterReturnsNilWhenUvenNotRunning -destination 'platform=macOS' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=UUM29335B4 ENABLE_TESTABILITY=YES
```

Inject fake transcription/TTS backends, selection/clipboard, recorder, audio feedback, system capture and muter registry. Do not load/download real models, fetch the appcast, touch microphone/system audio, inspect private selection/clipboard/recordings, or stop unrelated apps. Do not instantiate the full About setup view merely to test a label: its task prepares TTS and polls permissions. Four documented muter exclusions and any actual skips remain coverage gaps; no new exclusions or weakened checks.

Prior accepted checkpoint evidence: 730 executed, 11 skipped, zero failures with four exclusions; all 178 existing tracked macOS files matched packaging staging before commit. This is historical accepted evidence, not a fresh baseline for these behavior changes. No product tests were run during planning.

## Manual checklist (after authorized preview)

Use synthetic public text; keep live/private input boundaries explicit.
- Slow first read: hourglass during preparation, then speaker and start cue together without a conspicuous cue-leading-icon delay; natural finish returns idle.
- Warm read and progressive long read: one start cue, stable speaker state, no per-chunk cues.
- Cancel while preparing and while playing; no stale speaker transition/start cue after cancel. Test unavailable/empty input safely.
- About: manual link visible with no known update, existing Automatic Updates preference preserved, revised daily wording, and header layout fits.
- Known-update presentation can be checked with injected synthetic state; this is not live-feed or installation qualification. No live updater/install test unless separately authorized.

## Non-goals and final release boundary

No Read Aloud performance tuning, selection/Neovim/table fixes, cue sound redesign, updater badge-lifecycle redesign, forced checks on every launch, new update infrastructure, or unrelated TODO cleanup. The old retained DMG remains an accepted rollback/checkpoint artifact. After these fixes, the eventual final source/tag and release artifact must match; do not automatically upload the old DMG or rebuild/publish under this plan.
