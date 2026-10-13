# Format Selection removal — accepted implementation

## Lead acceptance

Implementation accepted after lead inspection and independent integrated review, including repair and narrow final documentation review. No blockers or nonblocking suggestions remain. Acceptance covers the uncommitted source candidate, not installed-app/live UX qualification or release.

Base HEAD: `beb490078cb3bd7ab7d7d71825e2cf24d140c63f`. Existing unrelated dirty source and evidence preserved. No commit, push, release, installation, app stop/launch, global-key/clipboard automation or private-data access was performed.

## Outcome

Removed the Format Selection hotkey/UI surface, persisted action, routing/callback and clipboard formatting implementation, seven exclusive formatter production files, two dedicated test files and their Xcode registrations. The menu exposes Record, Push-to-Talk and Read Aloud via the retained generic mode list. The former Cmd-Shift-F shortcut is not reserved by the retired feature and can be assigned to a surviving mode.

Legacy `hotkeys.format_selection` is ignored on decode, including malformed obsolete values, and dropped by a normal successful save. Regression covers omitted/valid/malformed values, fresh reload, preservation of custom Read Aloud binding/history/settings and second-save absence.

Shared SentenceEmbeddingService, MiniLM/vocabulary registrations, Debrief semantic dedupe, language inference, ReadAloudTextPreparer and general clipboard/hotkey behavior remain. Active documentation is reconciled; historical formatter documents are retained with retirement notes.

## Evidence / exact candidate

Original evidence: `evidence-2026-10-13-builder/`.
Repair evidence: `evidence-2026-10-13-repair/`.

- True task delta subtracting original dirty work: `evidence-2026-10-13-repair/task-delta-subtracting-starting-dirty.patch` (SHA256 `388039a308a666422a8d294773ae1d6e301e9535209785269fe7de821cf6e6d6`).
- Worktree identity: `evidence-2026-10-13-repair/final-candidate-worktree-hashes.txt`. Lead checked all 19 recorded entries before the final doc correction; all matched. After correction, only `docs/validation.md` differs: final SHA256 `48c4b6074c99defd2264d7a7402db6c931231a905e54db8635a0de489a85bb45`. Its only subsequent edit changes the documented Cmd-Shift-F proof from Read Aloud to a surviving mode, specifically Record. The independent reviewer approved that exact wording; unchanged code/test evidence was reused.
- The original builder's 'tracked hash manifest' contains index metadata, not worktree integrity hashes. Do not use it as current-source identity proof.
- Independent review findings and approval are retained in the parent conversation under `format-selection-integrated-review`: initial review required regression/docs/RED corrections; renewed review resolved code/test findings; final narrow review approved the documentation fix with no remaining findings.

## Actual checks

Signed Release `Dikta-UltraValidation`, manual Developer ID team `UUM29335B4`, test-only `ENABLE_TESTABILITY=YES`; effective TestHostIsolationTests verified config and empty synthetic sessions inside the host before sensitive runs. Exact commands/full logs/true exits are retained in evidence and docs/validation.md.

- Initial Release test build: exit 65 due to missing testability; corrected via test-only override, not product settings.
- Green pre-edit filtered baseline: 877 executed, 11 skipped, zero failures, exit 0.
- Initial migration/mode RED: 46 executed, 10 expected failures, exit 65.
- Initial affected GREEN: 86 executed, 1 skipped, zero failures, exit 0.
- Repair pre-edit isolation: 1 passed, exit 0.
- Genuine final shortcut RED in isolated pre-removal source fixture: 1 executed, intended assertion failure, exit 65. Old formatter intercepted Cmd-Shift-F before Record; expected `[.toggle]`, received `[]`. Fixture isolation passed first. Original Read Aloud routing did not prove this priority regression, so final regression targets Record while retaining the original Read Aloud routes.
- Repair focused GREEN: 15 executed, zero failures, exit 0.
- Final integrated filtered Release: 730 executed, 11 skipped, zero failures, exit 0 (`final-full-filtered-repair.log`). Reduction of 147 from baseline matches retirement of formatter-only suites. Shared config, isolation, clipboard, Read Aloud, embedding and Debrief suites executed positively.
- Hardened-runtime Developer ID Release signature retained in `final-signature-repair.txt`.
- Lead `git diff --check`: exit 0 after final wording correction.

No assurance-only code test rerun after the documentation-only correction; unchanged candidate code and integrated evidence were reused.

## Manual checks and honest gaps

Only the four documented Teams/Slack/WhatsApp/Uven real-muter absence exclusions were used; those and 11 actual real-session/engine/audio/Native Kokoro qualification skips are coverage gaps, not an unfiltered-suite pass.

User-performed manual checks, using synthetic text, remain outstanding:

1. Hotkeys menu/recorder offers only Record, Push-to-Talk and Read Aloud.
2. Cmd-Shift-F has no Dikta formatting/clipboard effect unless deliberately assigned to a surviving mode.
3. Generic hotkey recording/collision handling and Record/PTT/Read Aloud remain functional.
4. Read Aloud preparation/selection behavior and dictation/Debrief clipboard safety remain unchanged.
5. Fake-backed Debrief embedding coverage does not qualify live meeting/audio behavior.

No installed-app interaction was performed. Fixture and derived data remain retained at `/tmp/dikta-format-selection-red-fixture-20261013` and `/tmp/dikta-format-selection-red-deriveddata-20261013`; no cleanup authorized/performed.

Next action: review this accepted uncommitted candidate and authorize a separate isolated manual preview/installation if desired. Commit/release permissions are still absent. Deferred Read Aloud table-crash/Neovim work is unrelated and not fixed by this removal.
