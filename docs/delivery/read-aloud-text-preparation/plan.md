# Read Aloud: speakable-text preparation

## Status and authority

Planning completed 2026-10-12 for the user's explicitly selected adapted Addy engineering workflow. The subsequent continuation request authorized implementation through verification and independent review. The lead has now accepted the uncommitted reviewer6 implementation candidate with no unresolved implementation blockers. Live listening remains unauthorized and pending; acceptance does not authorize installation, commit, release, private-data access, or application control.

Workflow: **DEFINE → PLAN → BUILD → VERIFY → REVIEW → SHIP**. Breakdown belongs to PLAN, not a seventh phase. The required automated gates and independent review are complete; SHIP is a handoff only. Earlier unchecked planning rows and builder-pending notes below are historical; the final lead outcome at the end is the authoritative execution status. Listening is an explicit remaining gap, not a passing check.

The adapted skill was inspected at `/Users/sebastianstrandberg/artifacts/pi-toolkit-execution-seam-20261011-115311/candidate/skills/addy-engineering/SKILL.md`, together with its Pi adaptations and relevant upstream specification/planning references. It is an isolated workflow candidate, not an installed skill in this session's advertised loadout. Before BUILD, use a fresh explicitly opted-in session and verify effective project/parent/global rules and tools as required by `AGENTS.override.md`; do not install/reload tooling, change global policy, or start another session automatically. Existing conversation and this plan carry the task; no additional Agreement ceremony is needed after an actual implementation request.

## DEFINE — objective and scope

Make selected agent output in terminals and browsers comfortable to listen to, including Markdown tables, lists, headings, emphasis, and fenced blocks. Remove recognizable presentation syntax while preserving substantive text, order, and meaningful punctuation. The user accepts table headers followed by row values left to right; no per-row header repetition or spoken block announcements are required.

### Acceptance criteria

1. Confirmed tables retain the header and every selected row/cell in reading order, without speaking structural pipes or delimiter rows.
2. Recognized lists, headings, matched emphasis, and paired code fences lose their presentation markers, not their contents.
3. Excess prose alignment whitespace is normalized; words never concatenate, and item/row/paragraph boundaries remain distinguishable in the prepared text.
4. Code content, shell pipes/options, identifiers, negative numbers, ranges, meaningful punctuation, and Unicode grapheme clusters are protected from blanket stripping.
5. Ambiguous/malformed/partial structures use conservative fallback. No omitted header, value, or context is invented; no body text is silently discarded.
6. Preparation is deterministic, offline, bounded, and side-effect-free. It does not access the clipboard, filesystem, models, network, audio, or processes, and never logs selected/prepared content.
7. An empty prepared result does not check/start the voice engine or emit accepted-speech cues. Existing cancellation, voice/speed snapshots, progressive playback, and native input guards remain intact.
8. Existing original-selection/clipboard semantics and unrelated dirty work remain unchanged.

### Explicit non-goals

- Push-to-talk startup/release race or screenshot-shortcut overlap.
- Changing stale-clipboard fallback or proving the reported unusual sound/crash.
- Reproducing the screenshot's exact character sequence.
- Raising/removing helper phoneme limits or adding adaptive phoneme-driven retries.
- Full CommonMark/GFM compliance, rich clipboard/HTML/DOM extraction, browser integrations, code interpretation, summarization, or an LLM-based cleanup pass.
- New settings, parser dependencies, telemetry, Windows changes, release, installation, or artifact cleanup.

Cleanup can reduce formatting noise; it is **not** a guarantee against pronunciation expansion or a fix for the crash.

## Current architecture and evidence

- `dikta-macos/Dikta/ViewModels/MenuBarViewModel.swift:1552–1606`: AX/copy selection, ownership and empty guards, availability, accepted cues, then speech dispatch. Voice/speed request capture occurs earlier and must stay there.
- `dikta-macos/Dikta/Services/TextToSpeechService.swift:34–145, 246–335`: exact-range chunk planning, bounded input, synthesis/lookahead/playback ownership. The chunker must remain a lossless range planner over **its input**.
- `dikta-macos/Dikta/Services/TextSelectionService.swift`: captures plain strings, not a browser DOM or structured table. Do not put cleanup here or in `ClipboardManager`.
- Existing `FormatterEngine` can load embeddings and its formatters rewrite prose. They are not the preparation engine for this task.
- XCTest lives in `dikta-macos/DiktaTests/`. The Xcode project explicitly lists source/test build files; new files require registration.

Baseline: HEAD `daa2e0a` plus existing unrelated dirty work, including ClipboardManager, MenuBarViewModel, their tests, language/isolation tests, validation scheme, and TODO. Preserve these edits; assess a task-owned delta rather than attributing the entire dirty diff to this feature.

Inspected evidence at `/tmp/dikta-speakable-investigation.ynWLbK/`:

| Evidence | Actual result |
|---|---|
| `isolation.log`, `isolation.exit` | Initial build failed, exit 65: Release module lacked `-enable-testing`; no tests ran. |
| `isolation-testable.log`, `.exit` | Corrected invocation with `ENABLE_TESTABILITY=YES`; exit 0, 1 isolation test passed. |
| `focused-testable.log`, `.exit` | Seven relevant TTS/selection classes; exit 0, 114 tests reported: 113 passed, 1 skipped. |
| Signature inspection | Release test app signed by Developer ID Application, team UUM29335B4, hardened runtime. |

The skip is explicit real-model/audio-output onset qualification. No actual synthesized listening acceptance occurred. This is a focused baseline, **not** a full-target pass. The full filtered target is still required before editing the shared ViewModel and for integrated acceptance under `docs/validation.md`.

## PLAN — design decisions

### Boundary and contract

Use a separate Foundation-only value type, provisionally `ReadAloudTextPreparer`, called once at the selection-to-speech seam **after ownership/raw-empty checks and before availability/cues**. Retain raw captured text unchanged and pass only the derived speech string to TTS. Direct TTS service calls remain literal; preparation belongs to the selected-text user path, not every synthesis caller.

Return a small explicit result distinguishing ready text, empty readable content, and unsupported bounded input. Use existing notification/error paths rather than adding a new UI state machine. Check the original selection's existing 256 KiB work bound before processing, so removing decoration cannot make an originally oversized selection bypass the input limit. Keep the prepared output within existing limits too; never truncate to fit.

The module owns structure recognition and textual rendering only. The existing chunker receives prepared text and continues preserving every scalar of that string. Keep native helper guards, source token limits, cancellation, lookahead, request capture, and playback unchanged.

### Recognition and rendering policy

Process blocks before inline markers. Protect confirmed code regions before interpreting headings, lists, or tables. Use bounded scanning, not a chain of broad or backtracking-heavy regular expressions. Preserve Unicode using Swift Character/String.Index operations; normalize line endings for parsing without splitting graphemes.

| Construct | Initial behavior |
|---|---|
| Ordinary prose | Trim exterior whitespace; collapse repeated horizontal whitespace; join soft-wrapped prose with spaces; preserve paragraph boundaries and existing sentence punctuation. |
| Table | Require credible selected header + dash/optional-colon delimiter row and consistent cell structure. Handle escaped pipes and protected code spans. Remove only structural delimiters; retain all values, including empty cell positions. Render nonempty cell content left to right with `; ` separators and row boundaries with newlines; preserve existing content punctuation. Never discard extra/malformed cells to mimic a renderer. |
| Partial table lacking header/delimiter | Do not invent headers or assume every pipe is structural. Preserve ambiguous pipes/content, with conservative whitespace normalization. This limitation is deliberate. |
| Unordered lists | Remove clear line-start formatting bullets outside protected code; keep item boundaries. Do not globally delete hyphens, asterisks, plus signs, or command flags. |
| Ordered/task lists | Preserve numbers and task-state markers; do not invent completion labels. Complex or ambiguous nesting/continuations fall back conservatively. |
| Headings/emphasis | Remove clearly matched presentation markers; preserve words. Do not strip shebangs, literal hashes, underscores inside identifiers, or unmatched delimiters. |
| Code fences | Recognize paired backtick/tilde fences with matching run rules. Remove fence lines and their language labels; preserve enclosed code, operators, punctuation, and line boundaries. No “code block” announcement. Unmatched/partial fences fall back conservatively. |
| Inline code | Recognize matching backtick runs; omit the wrapper while preserving/protecting interior content. Unmatched runs remain literal. |
| Unsupported controls/other syntax | Keep existing rejection guarantees. No broad invisible-Unicode deletion or arbitrary ANSI, HTML, links, strike-through, or box-table interpretation in this scope. Preserve unrecognized substantive text. |

Synthetic expected table rendering:

```text
Input:
| Setting | Value |
|---------|-------|
| Speed   | Normal |
| Voice   | Heart |

Prepared:
Setting; Value
Speed; Normal
Voice; Heart
```

This is a textual boundary policy, not proof of audible timing. Real synthetic listening must confirm that cell/row separation is understandable. If newline handling collapses rows audibly, refine only the preparer's boundary rendering and renew its tests; do not quietly redesign playback or promise exact pauses.

### Alternatives and dependency direction

A full Swift Markdown/cmark-gfm AST is more complete for Markdown but adds dependencies and does not reconstruct absent selection context or lost browser structure. A small recognizer is lower risk for this bounded first scope. If it becomes an ad hoc full parser or cannot handle the stated core cases without unsafe guessing, revisit the design instead of silently expanding it.

Dependency direction: selected-text orchestration → pure preparer → prepared string → existing TTS/chunker/native pipeline. No reverse dependency on ViewModel, clipboard, FormatterEngine, or runtime services.

### Mechanics

Use Direct or one Developer for the sequential slices; shared ViewModel/preparer changes do not benefit from parallel writers. Read the adapted execution mapping before delegation and use only existing granted tools. One final independent, inspection-only integrated review is proportionate because this feature deliberately transforms user content. Worker completion is not lead acceptance; do not call self-inspection independent review.

## Ordered breakdown — single execution checklist

Each BUILD slice uses RED → GREEN → REFACTOR with synthetic failing regression fixtures and a minimal working implementation. Run affected checks before edits and after each affected code change; do not wait until the end of a slice to discover regressions. No automatic per-slice commits or human checkpoints.

- [ ] **0. Establish execution readiness.** Fresh opted-in loadout, implementation authority, current dirty ownership, and the full filtered signed Release pre-edit baseline. Dependency: implementation request. Acceptance: required effective isolation test passes first; positive test counts and true exits; unrelated work preserved. Verify: commands below and current source/diff inspection. No production edit in this item.
- [ ] **1. Deliver the preparation boundary and whitespace path.** Add preparer/result and wire it into selected-text dispatch, with empty/oversize/no-op cases. Dependency: 0. Acceptance: fake TTS receives derived text; raw capture is unchanged; empty prepared input stops before assets/cues; bound/cancellation/snapshot tests pass. Likely files: new `Services/ReadAloudTextPreparer.swift`, new `DiktaTests/ReadAloudTextPreparerTests.swift`, ViewModel/read-aloud tests, `project.pbxproj`. Verify: new preparer, ViewModel, selection, and existing TTS suites.
- [ ] **2. Deliver protected-code and confirmed-table reading.** Address the highest-risk distinction between structural pipes and operators. Dependency: 1. Acceptance: header/rows/cells remain ordered; separator syntax disappears; escaped/literal/code pipes and malformed/partial tables are safe; fence contents are protected. Include synthetic code containing Markdown-looking lines. Likely files: preparer/tests, focused ViewModel fixture tests. Verify: new fixtures plus unchanged exact-range/Unicode/cancellation suites.
- [ ] **3. Deliver lists, headings, and conservative inline cleanup.** Dependency: 2's protection rules. Acceptance: decoration disappears only when recognized; numbering/state, code identifiers, negative values, shebangs, unmatched markers, and partial selections retain meaning. Verify: pure-output fixtures, mixed browser/terminal examples, end-to-end fake dispatch, repeated preparation consistency where applicable.
- [ ] **4. Verify the integrated candidate.** Dependency: 1–3. Acceptance: focused and full filtered signed Release gates pass; raw/normalized bounds and failure paths covered; architecture docs describe current behavior; no real models/devices in unit tests. Perform the authorized synthetic listening checklist below, or report it as pending. Likely supporting docs: `docs/architecture.md` and this record. Verify exact integrated source, counts/exits/logs, and Developer ID signature.
- [ ] **5. Independent review and lead acceptance.** Dependency: 4. Review complete task-owned diff, fixtures, preservation claims, complexity, resource bounds, untrusted-input handling, cancellation, and evidence. Repair blocking findings within later implementation authority and rerun affected checks/review. Acceptance: no unresolved blockers; honest manual/coverage gaps; unrelated edits excluded from candidate attribution.
- [ ] **6. SHIP handoff, not release.** Dependency: 5. Record candidate identity, actual/reused checks, review disposition, manual results, limitations, and one next action. Commit/push/merge/install/publish/delete remain separately authorized actions.

The numbered items are tasks within the six-phase workflow, not additional workflow phases.

## Verification commands and prerequisites

Run from the repository root. These are commands for future authorized BUILD/VERIFY, **not executed as part of writing this plan**. `docs/validation.md` remains the quality authority. Reuse unchanged focused evidence, but do not substitute it for the outstanding full-target pre-edit gate.

The current scheme injects `/tmp/dikta-team-polish-validation/config/config.json` and `/tmp/dikta-team-polish-validation/empty-real-sessions`; its isolation test hardcodes those paths. They were verified synthetic during discovery. Recheck ownership and synthetic/empty status before reuse; do not overwrite another task's fixtures or relax the isolation assertions. All ViewModel unit tests must inject fake engine, recorder, feedback, and muter dependencies. Keep real-model qualification opt-ins unset. If a test would touch installed/private assets or devices, resolve that boundary before running it; no implicit permission to stop Dikta or other apps.

```bash
EVIDENCE=$(mktemp -d /tmp/dikta-read-aloud-preparation.XXXXXX)
PACKAGE_CACHE=/Users/sebastianstrandberg/Library/Developer/Xcode/DerivedData/Dikta-ggsbbirijudkfshhkwtnljkbvhdg/SourcePackages
COMMON=(
  -project dikta-macos/Dikta.xcodeproj
  -scheme Dikta-UltraValidation -configuration Release
  -destination 'platform=macOS'
  -derivedDataPath "$EVIDENCE/DerivedData"
  -clonedSourcePackagesDirPath "$PACKAGE_CACHE"
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile
  ENABLE_TESTABILITY=YES CODE_SIGN_STYLE=Manual
  'CODE_SIGN_IDENTITY=Developer ID Application' DEVELOPMENT_TEAM=UUM29335B4
)

# First gate, before sensitive tests; inspect exit and positive executed count.
xcodebuild test "${COMMON[@]}" \
  -only-testing:DiktaTests/TestHostIsolationTests \
  > "$EVIDENCE/isolation.log" 2>&1
status=$?; printf '%s\n' "$status" > "$EVIDENCE/isolation.exit"
# Continue only after exit 0 AND a positive executed-test count with no failures.

# Required broad pre-edit and final integrated gate; isolated synthetic sessions.
xcodebuild test "${COMMON[@]}" -only-testing:DiktaTests \
  -skip-testing:DiktaTests/MicMutingTests/testTeamsMuterReturnsNilWhenTeamsNotRunning \
  -skip-testing:DiktaTests/MicMutingTests/testSlackMuterReturnsNilWhenSlackNotRunning \
  -skip-testing:DiktaTests/MicMutingTests/testWhatsAppMuterReturnsNilWhenWhatsAppNotRunning \
  -skip-testing:DiktaTests/MicMutingTests/testUvenMuterReturnsNilWhenUvenNotRunning \
  > "$EVIDENCE/integrated.log" 2>&1
status=$?; printf '%s\n' "$status" > "$EVIDENCE/integrated.exit"

# Affected focused gate after each code change; new class must actually exist/run.
xcodebuild test "${COMMON[@]}" \
  -only-testing:DiktaTests/ReadAloudTextPreparerTests \
  -only-testing:DiktaTests/MenuBarViewModelReadAloudTests \
  -only-testing:DiktaTests/TextSelectionServiceTests \
  -only-testing:DiktaTests/TextToSpeechCancellationTests \
  -only-testing:DiktaTests/NativeKokoroProtocolTests \
  -only-testing:DiktaTests/NativeKokoroLifecycleTests \
  -only-testing:DiktaTests/NativeKokoroRuntimeControlTests \
  -only-testing:DiktaTests/NativeKokoroPackagedTests \
  > "$EVIDENCE/focused.log" 2>&1
status=$?; printf '%s\n' "$status" > "$EVIDENCE/focused.exit"

codesign -dv --verbose=2 "$EVIDENCE/DerivedData/Build/Products/Release/Dikta.app" \
  > "$EVIDENCE/signature.log" 2>&1
```

Commands are separate gates, not a blind paste-and-continue script. Stop adding functionality to diagnose a red gate; do not run later sensitive commands after failed isolation. Keep each execution's full logs/exits separately instead of overwriting earlier evidence. Verify positive total and class-level counts; an absent/zero-test new class is not a pass. Report the broad run as **filtered**, with the four real-muter exclusions and actual skips listed. Do not add exclusions, use Debug/ad-hoc signing, or invoke `build-release.sh` as a test command. No new formatter/library changes are planned; if necessary scope changes affect additional areas, add their prescribed checks rather than narrowing the required bar.

## Synthetic coverage and manual acceptance

Unit matrix: plain/no-op text; empty/formatting-only input; raw and output size edges; CR/LF/CRLF/tabs; normal/aligned/empty-cell tables; escaped pipes; code pipes; malformed/partial tables; paired/unmatched/longer backtick and tilde fences; language labels; inline-code delimiters; nested/ordered/task lists; headings/emphasis; shell pipelines/options; identifiers; numeric ranges/negative values; combining accents/emoji/CJK/RTL/nonbreaking spaces; mixed prose/code; no loss/reordering; empty result before runtime; cancellation and captured voice/speed.

Listening is a separate, not-yet-authorized live-output gate. Before automated listening, obtain permission for the chosen synthetic fixtures, isolated validated assets/helper, and audio output; normal app startup may use installed assets, migrate data, or contact update/setup services. Do not infer safe startup from config/HOME alone. User-performed checks on a candidate are another option; installation remains separately authorized.

Consolidated manual checklist:
- [ ] Synthetic Markdown table: hear header, then rows left to right, without separator noise; cell and row boundaries are understandable.
- [ ] Synthetic terminal mixture: heading, list, prose, and fenced shell command; no unintended punctuation loss or spoken fence label.
- [ ] Synthetic browser selection: rendered table/list plain text remains readable; record any lost-structure limitation rather than claiming DOM recovery.
- [ ] Partial table/code selection: conservative fallback does not invent or discard text.
- [ ] Formatting-only selection: useful empty-content notification, no accepted-speech cue or generation.
- [ ] Longer prepared selection: progressive playback and explicit stop remain responsive; no claim that cleanup guarantees phoneme admission.

## Risks, open gates, and handoff

Main risks are false-positive formatting removal, incomplete selection context, lost browser structure, Unicode damage, excessive parsing work, and unclear audible boundaries. Mitigate with protected code, conservative fallback, explicit raw/output bounds, synthetic preservation fixtures, and authorized listening—not speculative reconstruction or a new model pipeline.

No unresolved core product question prevents the plan: the user's table order and no-block-announcement defaults are recorded. Rendering separators may be refined from synthetic listening evidence without broadening scope. Consequential new behaviors/dependencies or required-check changes still need a decision.

## Builder continuation — 2026-10-12 (awaiting lead acceptance)

The user subsequently authorized BUILD through verification/review in an opted-in adapted Addy session. The historical planning-status text above is retained as provenance; this section records builder execution only and does not claim lead acceptance.

- [x] 0. Execution readiness: captured HEAD `daa2e0ad41d61546f7ec9e84c22e2822665dc997` and all starting tracked/untracked state before edits. Rechecked the shared synthetic config and empty real-session directory. Signed Release isolation gate passed: 1 executed, 0 failures, exit 0. The filtered broad pre-edit gate passed: 846 executed, 11 skipped, 0 failures, exit 0; the four documented real-muter absence tests remained excluded.
- [x] 1–3. Added the pure Foundation-only `ReadAloudTextPreparer` and registered `ReadAloudTextPreparerTests` in the Xcode project. It bounds raw and rendered UTF-8 input, renders only confirmed tables/paired fences/matched inline formatting, and conservatively retains malformed structures and literal code punctuation/Unicode. The selected-text ViewModel seam retains raw selection and rejects empty prepared or unsupported input before availability, TTS, or accepted-speech cues. No TTS chunker, request snapshot, cancellation, or direct-TTS path was changed.
- [x] 4. Builder focused validation passed after the first source changes: 126 executed, 1 explicitly opt-in real-output qualification skipped, 0 failures, exit 0. The independent review then identified required parser defects; repaired-candidate validation is recorded below and remains awaiting renewed reviewer inspection.
- [ ] 5. Independent review and lead acceptance remain pending. Builder self-inspection found no blocking issue; it is not independent review.
- [ ] 6. SHIP/acceptance/release remain pending; no commit, installation, listening, release, or cleanup was performed.

Evidence: `docs/delivery/read-aloud-text-preparation/evidence/build-2026-10-12T050616/` contains the starting-state snapshots and points to the full `/tmp/dikta-read-aloud-baseline.*` logs/exits. The original planning manual listening checklist remains pending: live output/listening was explicitly not authorized.

### Review-repair continuation — 2026-10-12 (awaiting renewed independent review)

Independent review required conservative-parser corrections. Behavioral RED fixtures against the previously compiling implementation failed as intended (15 executed, 7 failures, exit 65): lone multiplication/marker loss, global shell escape decoding, inline-code whitespace loss, multi-run/table code-pipe handling, malformed-fence recognition, and soft-wrap boundaries. The preparer was replaced with bounded single-pass line/character recognition: it does not rescan unmatched fence suffixes, scan unmatched inline suffixes repeatedly, or repeatedly remove leading blank lines. It protects malformed/over-indented fences, honors exact inline code runs, limits table escape decoding to confirmed tables, preserves code whitespace, and joins only ordinary soft-wrapped prose.

Repair-focused checks: 131 executed, 1 explicit real-output qualification skip, 0 failures, exit 0 (`review-repair-focused3.log/.exit`). Final filtered signed Release target/signature check passed after the linear unmatched-suffix correction: 863 executed, 11 skipped, 0 failures, exit 0 (`review-repair-integrated2.log/.exit`); Developer ID signature is in `review-repair-signature2.log/.exit`. The corrected formatting-only ViewModel fixture uses marker-plus-whitespace (`"# \\n* "`), rather than treating lone `#` or `*` as formatting.

The current candidate still awaits renewed independent reviewer inspection and lead acceptance. Listening/manual checks, release, installation, commit, push, and cleanup remain unauthorized and unperformed.

### Second reviewer-repair continuation — 2026-10-12 (awaiting renewed independent review)

The second renewed review identified exact-preservation and work-bound defects. Exact behavioral RED fixtures failed against the compiling predecessor: 19 executed, 8 failures, exit 65 (`reviewer2-red.log/.exit`). The replacement tokenizer records every backtick/asterisk/underscore run once and reverse-indexes the next run of the same marker and length; it does not perform per-marker suffix scans or run-sized sliding windows. It retains unmatched/mismatched marker runs, recognizes only flanking-valid emphasis runs up to two markers, preserves ASCII-space/tab-only normalization without deleting NBSP, and protects complete invalid/over-indented fence regions verbatim. Confirmed table delimiter cells allow optional one end-colon only; interior/repeated colons fall back unchanged.

Focused repaired validation: 135 executed, 1 explicit real-output qualification skip, 0 failures, exit 0 (`reviewer2-focused.log/.exit`). Final filtered signed Release validation: 867 executed, 11 skipped, 0 failures, exit 0 (`reviewer2-integrated.log/.exit`); Developer ID signature is `reviewer2-signature.log/.exit`.

### Fourth reviewer-repair continuation — 2026-10-12 (pending final verification)

Fourth review added code-span ownership, escape-parity, valid-fence closer, and leading tab/mixed-indent regressions. The prior candidate failed behavioral RED: 25 executed, 9 failures, exit 65 (`reviewer4-red.log/.exit`). Code spans are paired before emphasis links and their interiors are excluded from emphasis pairing; escaped marker sequences use conservative literal fallback. A valid fence only closes with at most three leading spaces, while invalid/over-indented fallback pairing remains separate. Targeted preparer GREEN is 25 executed, 0 failures, exit 0 (`reviewer4-green2.log/.exit`). Focused/full signed Release validation, signature, and hash-verified complete delta are pending in the continuation evidence; no acceptance is claimed.

### Fifth reviewer-repair continuation — 2026-10-12 (final verification pending)

A confirmed-table escaped-presentation-marker parity fixture failed RED (26 executed, 1 failure, exit 65; `reviewer5-red.log/.exit`) and passed after the minimal table-cell conservative literal path (26 executed, 0 failures, exit 0; `reviewer5-green.log/.exit`). That path decodes only structural `\\|` while retaining escaped presentation markers and backslashes. Final focused/full filtered signed Release validation, signature, matched before/after hashes, and complete delta evidence are recorded by the final verification continuation; lead acceptance remains pending.

### Sixth reviewer-repair continuation — 2026-10-12

For a confirmed-table cell containing an escaped presentation marker, the agreed conservative exception is now whole trimmed-cell literal preservation: no whitespace normalization, inline-wrapper removal, or `\\|` decoding occurs in that cell. RED was 26 executed / 2 failures / exit 65 (`reviewer6-red.log/.exit`); focused fixture GREEN was 26 / 0 / exit 0 (`reviewer6-green.log/.exit`). Final Release/evidence continuation remains pending lead acceptance.

## Final lead outcome — 2026-10-12

- [x] 0. Execution readiness accepted: effective adapted Addy loadout and isolation checked; signed Release isolation 1/0 failures and filtered broad pre-edit baseline 846/11 skipped/0 failures, exits 0, before production edits.
- [x] 1–3. Preparation boundary, protected-code/table rendering, lists/headings/inline cleanup accepted against the agreed scope after regression repairs.
- [x] 4. Automated verification accepted on the exact reviewer6 candidate: regression 26/0 failures, focused 142/1 skipped/0 failures, filtered integrated 874/11 skipped/0 failures, all exit 0. Manual listening remains pending, as permitted by the plan's reporting alternative.
- [x] 5. Independent reviewer approved the exact integrated candidate with no remaining implementation blockers; lead inspected source, task delta, counts/exits, matched hashes, signature and preservation evidence and accepted it.
- [x] 6. SHIP handoff recorded; no release or installation performed.

Candidate: uncommitted worktree on HEAD `daa2e0ad41d61546f7ec9e84c22e2822665dc997`, identified by `evidence/build-2026-10-12T050616/reviewer6-complete-starting-to-current.patch` (SHA-256 `efb792eb20d9807960c2e1e4e6a96ebf30c16c6facf821b0a932fffcb52151e3`). Preparer SHA-256 `1adc93179a68195c78f98b2a52b79cf029c1d33789e6bd6da208163de3c46bf2`; preparer tests `1558bf9316b9dfeddae91804e8357e12e9eaa4b208974f2762bc997043d08386`. Before/after hashes matched across validation. This final task-record-only update follows review and does not alter the tested source; the patch retains the reviewed pre-handoff record.

Evidence: `reviewer6-integrity.txt`, before/after manifests, complete patch and final git-state in that evidence directory; full logs/exits in `/tmp/dikta-read-aloud-baseline.Lup1XJ/reviewer6-*-final.log/.exit`. Developer ID Application/team `UUM29335B4`, hardened runtime verified. Six initial unrelated dirty files compared byte-for-byte unchanged; the task ViewModel delta is isolated against its initial dirty snapshot. Independent approval is saved alongside this outcome in `evidence/build-2026-10-12T050616/final-review-disposition.md`.

Coverage gaps: four existing Teams/Slack/WhatsApp/Uven absence-test exclusions; 11 integrated skips (six isolated/private-session checks, onset qualification, two long-read qualifications, progressive qualification, short-service qualification). The focused skip is real-output onset qualification. No live model/audio or installed-app qualification occurred. A cell containing escaped presentation markers deliberately remains wholly literal after exterior ASCII trimming, including code wrappers/escapes/whitespace. Partial selection/absent browser structure cannot be reconstructed, and cleanup does not guarantee native phoneme admission or fix the excluded crash.

Next action: authorize a narrowly scoped synthetic listening run with isolated validated assets/helper and audio output, or perform the consolidated manual checklist above yourself on an explicitly authorized candidate setup. No installation or app-control permission is inferred.

## Follow-up: outer presentation wrappers — 2026-10-12 (pending independent review)

The accepted reviewer6 candidate remains historical accepted evidence. The user separately authorized this narrow follow-up: a single whole-selection valid outer fence labeled exactly `text` or `markdown` is treated as a presentation wrapper and its interior is rendered once. Recognition is deliberately nonrecursive: `md`, `mdown`, unlabeled, unknown, malformed, unmatched, and candidate nested wrappers are not added as wrappers. Inner genuine code fences remain protected by the existing code path. This does not address the separately unresolved table crash.

Builder RED/GREEN regression evidence and final isolated signed Release verification, matched source hashes, preview signature, and snapshot-to-final delta live in `evidence/wrapper-follow-up-2026-10-12T081024/`. The fresh local non-launched Developer ID Release preview is `Dikta.app` under `/Users/sebastianstrandberg/artifacts/dikta-read-aloud-wrapper-preview.GjWKOY/`, version 1.5.7 (build 1.5.7.2). It is a preview artifact only, not a release, installation, or listening qualification. Independent review and lead acceptance of this follow-up remain pending.

### Wrapper padding repair — 2026-10-12

Outer wrapper detection now permits only exterior ASCII-blank padding and recognizes exactly case-insensitive `text`/`markdown`; it rejects nonblank prefix/suffix and does not treat NBSP as padding. RED 29/2 failures (exit 65) and preparer GREEN 29/0 (exit 0) are retained in the wrapper follow-up evidence. Final signed Release verification, matched hashes, preview 1.5.7.3, and refreshed delta evidence are complete. Independent review approved the exact final follow-up candidate; lead accepted after checking current hashes, source, matched manifests and actual logs. Final source `2632209239cff323e2ef4b5553a2f6e5109606620a96c968dd2d6496ed32ebad`, tests `d28da40c4baaa8aa0b3cf51eb90a88947c801d885fcacb6d2f3a4930d0f23459`. Correct accepted-to-follow-up patch SHA-256 `9b9c5b7483cf00cb02197df264d062f7177f1813030adb6536a57cb82f5b87e7`.

Final checks: focused subset 138/1 skipped/0 failures (RuntimeControl omitted from subset but integrated 7/0), filtered integrated 877/11 skipped/0 failures, true exits 0; existing four muter exclusions unchanged. Full logs retained with byte-identical `.full.txt` copies and manifest, matched before/after hashes and independent disposition under `evidence/wrapper-follow-up-2026-10-12T081024/`. The earlier reviewer missing-log finding was withdrawn after explicit supplied-file inspection. This documentation-only handoff update follows review and does not change the tested source.

Current preview: `/Users/sebastianstrandberg/artifacts/dikta-read-aloud-wrapper-preview-1.5.7.3.F2RZcK/Dikta.app` (1.5.7, build 1.5.7.3), Developer ID Release with main/helper strict verification. Prior GjWKOY build 1.5.7.2 is superseded but preserved. Three standalone synthetic A/B/C `.txt` files beside the current app include outer wrapper characters and terminal newlines; test one file at a time with Select All in a plain-text editor. New wrapper listening remains pending user, and earlier table crash remains unresolved/out of scope. No app control/private data/live audio/install/commit/release occurred. Next action: user launch this preview and test those exact snippets.
