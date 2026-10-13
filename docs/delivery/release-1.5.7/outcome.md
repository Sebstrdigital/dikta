# Dikta v1.5.7 — Streamlined Hotkeys

## Accepted locally; publication on hold

### Source checkpoint authorization (2026-10-13)

In the follow-up session, the user explicitly authorized committing and pushing this accepted integrated candidate before the two additional fixes. Tag creation, appcast updates, GitHub release publication and asset upload remain on hold. This checkpoint does not authorize releasing the retained DMG after later source changes; the final release artifact must match the eventual release candidate.

Before staging, the lead confirmed that all 23 modified/deleted macOS paths match the retained accepted packaging source snapshot and that `origin/main` remains at the base HEAD below. Existing signed Release/package evidence is reused for unchanged code. The source checkpoint includes the integrated clipboard/Debrief changes, Format Selection removal, version/changelog/release notes and relevant documentation. Unrelated TODO additions, workflow files and old evidence remain outside the commit.

User subsequently confirmed: “I'm happy with that. That works good,” and explicitly asked to mark this work done and accepted. Local candidate acceptance is complete. The user did not enumerate individual manual checks, so this is user acceptance—not evidence that every manual scenario or skipped check was performed. Two additional small fixes are planned for a fresh session before a new release; their scope is not yet specified. No publication authority was granted.

User authorized preparation of the current integrated workspace (including existing clipboard/Debrief changes), signed/notarized packaging and local installation from the exact image intended for later GitHub upload. User separately confirmed quitting the identified running Dikta preview. No commit, tag, push, appcast update, GitHub release or upload was authorized/performed. The newly installed app remains closed for user testing.

- Installed app: `/Applications/Dikta.app`, version/build `1.5.7/1.5.7`.
- Base source HEAD: `beb490078cb3bd7ab7d7d71825e2cf24d140c63f`, integrated dirty source snapshot, not a committed release revision.
- Release title: **Dikta v1.5.7 — Streamlined Hotkeys**.
- Draft notes: `docs/releases/v1.5.7.md`; changelog and both project version configurations updated.
- Artifact root: `/Users/sebastianstrandberg/work/artifacts/dikta-release-1.5.7-20261013T024139Z/`.
- Exact release DMG: `Dikta-1.5.7.dmg` under that artifact root.
- SHA256: `938d8e1ff78062aeae07fc5279b78eef22a7b641f7fbcd5368c2c0494b7beefd`.

## Build and package evidence

Fresh source/package staging preserved the existing repository build artifacts. `KEEP_RELEASE_WORK_DIR=1` retained new staging. Script invocation was `build-release.sh --no-publish`, without skipping tests; exit 0. The integrated macOS source matched its SHA256 staging manifest before and after packaging. See `package-manifest.md`, `source-sha256.txt`, `final-tracked.diff`, `release-script-logs/`, and `publication-instructions.md` under the artifact root.

Actual new checks:

- Pre-bump and staged/bumped effective-host TestHostIsolationTests: each 1 executed, zero failures, exit 0.
- Signed Release filtered gate: 730 executed, 11 skipped, zero failures; only the four documented Teams/Slack/WhatsApp/Uven muter absence exclusions.
- Hardened-runtime Developer ID archive/export, signature/deep-strict verification and signed native helper/resources checks passed; no test bundle in packaged app.
- App notarization accepted: `69f988bd-3c1e-4f76-883a-ca59af9e5d34`.
- DMG notarization accepted: `fe940de3-4f66-4192-855f-e80f8e781358`.
- App/DMG stapler validation and DMG integrity verification passed.
- Initial DMG Gatekeeper open assessment without context returned exit 3 (`Insufficient Context`), not a pass. Lead repeated with `--context context:primary-signature`; accepted as Notarized Developer ID, exit 0.

Accepted Format Selection implementation/review evidence is reused from `docs/delivery/remove-format-selection/outcome.md`. Packaging the integrated workspace is not a claim of new independent code review of all pre-existing clipboard/Debrief changes.

## Installation evidence and rollback

Lead verified the preserved DMG SHA256, mounted that exact image read-only, compared its app's file contents/modes and symlink targets to the retained signed export, and checked signatures/Gatekeeper/stapling/version before installation.

The explicitly approved preview executable was reidentified at PID 682 by its exact path `/Users/sebastianstrandberg/artifacts/dikta-read-aloud-wrapper-preview-1.5.7.3.F2RZcK/Dikta.app/Contents/MacOS/Dikta`. Lead sent SIGTERM only to that verified PID and observed exit; no forced termination or unrelated application control occurred.

The prior `/Applications/Dikta.app` was moved intact to `previous-Applications-Dikta.app` under the artifact root. The candidate was copied from the mounted DMG to a fresh install staging path, verified, and moved to `/Applications/Dikta.app`. Installed app tree exactly matched the DMG app; installed deep/strict signature, Gatekeeper Notarized Developer ID assessment and stapler validation all passed. The task-owned image mount was detached successfully. No model caches, personal configs/sessions or user transcripts were inspected; no app launch/global keys/clipboard manual test occurred.

Receipts: `lead-installation.log`, `installation-receipt.json`, `installed-app-tree-manifest.json` under the artifact root. Installed app CDHash: `2c0367504bb139ac3af81494638aa8b6fb59a33d`, team `UUM29335B4`.

Rollback is available from the preserved previous app; do not automatically replace or launch it without current authority.

## User next action and publication hold

Local candidate is user-accepted. The following synthetic-content checklist remains for reference; individual scenario completion was not reported:

1. Hotkeys menu/recorder offers Record, Push-to-Talk and Read Aloud only.
2. Cmd-Shift-F has no retired formatter effect unless deliberately rebound.
3. Record/PTT/Read Aloud, selection preparation and generic hotkey/collision handling still behave as expected.
4. Debrief/multiline paste preserves clipboard safety and displays accurate requested/skipped-paste completion messages.

The 11 skipped tests and four exclusions remain coverage gaps. User accepted the local behavior, but did not supply scenario-by-scenario live audio/provider/clipboard/UX qualification; packaging/signature success does not close those specific coverage gaps.

If the user approves release later, upload **this exact retained DMG** after checking its SHA256. Do not rerun the build script's publication path: it rebuilds and may publish different bytes. Follow preserved publication instructions, establish a matching committed source/tag with separate authority, and preserve existing release/appcast items. No publication authority exists yet.
