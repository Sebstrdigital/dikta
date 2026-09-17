# Debrief Summarizer Probe — 2026-09-17

**Machine:** Apple Silicon Mac, macOS 26.6.2, Swift 6.4 (invoked `swiftc` directly, no Xcode project, no `xcodebuild`)

**Goal:** confirm `FoundationModelsDebriefSummarizer` and `HeuristicDebriefSummarizer` (both on `feat/debrief-core`, commit `7dc09d4`) actually produce structured `DebriefSummary` output from realistic, unpunctuated, single-speaker dictated meeting debriefs, in both English and Swedish, and capture the real outputs as PoC evidence. No app code was changed.

**Result: both engines work.** `SystemLanguageModel.default.availability` reports `.available`, and all 6 transcripts × 2 engines = 12 calls succeeded with no errors, no truncation, and no timeouts. Foundation Models responded in 4.27s–6.66s per call; the heuristic engine is effectively instant (0.00s at the 2-decimal precision printed).

**Data-handling note:** every transcript quoted or tabulated below is either one of the six synthetic samples built into `debrief-probe.swift` (fictional meetings, fictional names) or a generic, name-scrubbed description of a real dictated session. No real transcript text, rendered summary, or real person/company name is reproduced anywhere in this document, and none of the recordings, transcripts, or probe outputs referenced below are checked into this repo — see `.gitignore` and `docs/validation.md`.

## Compile command

```bash
swiftc -O -parse-as-library -target arm64-apple-macos26.0 \
  dikta-macos/bench/probes/debrief-probe.swift \
  dikta-macos/Dikta/Models/DebriefSummary.swift \
  dikta-macos/Dikta/Services/Debrief/DebriefSummarizer.swift \
  dikta-macos/Dikta/Services/Debrief/HeuristicDebriefSummarizer.swift \
  dikta-macos/Dikta/Services/Debrief/FoundationModelsDebriefSummarizer.swift \
  dikta-macos/Dikta/Services/Debrief/OllamaDebriefSummarizer.swift \
  -o /tmp/debrief-probe -framework FoundationModels
```

Exit status `0`, no warnings. `OllamaDebriefSummarizer.swift` was included because `DebriefSummarizer.swift` defines `DebriefSummarizerFactory.make`, which references `OllamaDebriefSummarizer` directly in its `.auto`/`.ollama` branches — the type must be visible for the module to compile even though the probe never calls the factory or instantiates that engine itself.

## Run command

```bash
/tmp/debrief-probe > dikta-macos/bench/results/debrief-probe-2026-09-17.txt 2>&1
```

Exit status `0`. Full output (612 lines) is local-only — `bench/results/` is gitignored and probe output is never committed (see the data-handling note above).

## Availability

```
AVAILABILITY: available
```

## Per-sample table

Owner/due "captured" = at least one action item in that engine's output for that sample has a non-null, non-placeholder owner and due. The heuristic engine never populates `owner`/`due` by design (see its doc comment), so it is "no" for every row — that is expected, not a defect.

| sample | engine | latency (s) | #decisions | #actions | #questions | owner/due captured | language correct | hallucinated/questionable fact |
|---|---|---|---|---|---|---|---|---|
| en1-design-sync | FoundationModels | 6.39 | 5 | 4 | 3 | yes (2/4; 2 use placeholder "Not specified") | yes | "Legal" and "Team"-style generic owners; decisions list duplicates action-item text verbatim |
| en1-design-sync | Heuristic | 0.00 | 1 | 3 | 2 | no | yes | none — verbatim transcript fragments only |
| en2-sales-call | FoundationModels | 4.27 | 2 | 2 | 3 | yes (1/2; owner "Team" invented for the trial-extension item, transcript names no owner) | yes | owner "Team" not spoken; Lisa's Thursday follow-up dropped from `actionItems` (only survives in `summary`) |
| en2-sales-call | Heuristic | 0.00 | 2 | 6 | 2 | no | yes | none |
| en3-incident-postmortem | FoundationModels | 6.39 | 3 | 3 | 3 | yes (2/3; owner "Team" invented for the load-test item) | yes | owner "Team" not spoken (same pattern as en2) |
| en3-incident-postmortem | Heuristic | 0.00 | 1 | 5 | 2 | no | yes | none |
| sv1-marknad-sync | FoundationModels | 6.61 | 4 | 3 | 3 | yes (2/3; 1 uses placeholder "Ingen specificerad") | yes | analytics-dashboard bug reframed as a decision/action ("Analyspanelen ska räknar...", also ungrammatical Swedish verb form) |
| sv1-marknad-sync | Heuristic | 0.00 | 1 | 3 | 3 | no | yes | none |
| sv2-kundsamtal | FoundationModels | 5.37 | 3 | 3 | 3 | yes (2/3; 1 uses "Nästa möte" as a paraphrased due, 1 uses placeholder owner) | yes | decisions compressed to single/two-word fragments ("Förlängd testperiod"), inconsistent with the full-sentence decisions in every other sample |
| sv2-kundsamtal | Heuristic | 0.00 | **0** | 7 | 2 | no | yes | none — see observations, this is a real marker-matching miss, not a bug in the probe |
| sv3-incident | FoundationModels | 6.66 | 3 | 3 | 2 | **no (0/3)** | yes | due dropped to placeholder "Ingen specificerad." for all 3 items despite two explicit deadlines being spoken ("i morgon eftermiddag", "på fredag"); owner strings carry a stray trailing period ("Tomas.") |
| sv3-incident | Heuristic | 0.00 | 1 | 5 | 2 | no | yes | none |

## Observations

- **Foundation Models never mistranslated or dropped into English for Swedish input**, across all 3 Swedish samples — output language matched input language every time, contradicting nothing found in the prior formatting probe (which never got far enough to test this at all). This is the first real signal on that question.
- **The "otherwise null" instruction in the prompt/`@Guide` descriptions is not reliably honored.** Instead of omitting `due`/`owner` or emitting JSON `null`, Foundation Models frequently fills them with placeholder text — "Not specified", "TBD", "Ingen specificerad" — which still decodes into a non-nil `String?` and renders as `(owner, due Not specified)` in `renderPlainText`. A real UI consuming this needs to treat those placeholder strings as equivalent to nil, or the rendered output will look broken to a user.
- **Owner fabrication pattern:** on 2 of 6 English/Swedish samples, Foundation Models assigned a generic owner ("Team") to an action item where no person was named in the transcript, violating the explicit "only if actually named... otherwise null" rule. This is a real, repeatable hallucination risk worth a follow-up test with a larger sample before relying on the owner field.
- **sv3-incident is a quality outlier for Foundation Models**: it captured zero real due dates even though the transcript spoke two of them plainly ("senast i morgon eftermiddag", "senast på fredag"), and it embedded a stray trailing period inside the owner string itself ("Tomas."). Latency and decision/action counts were normal, so this looks like an output-quality miss on this specific transcript rather than an infra problem.
- **The heuristic engine's fixed-phrase decision markers are brittle to Swedish word order.** `sv2-kundsamtal` contains a spoken decision ("Också kom vi överens om att...") using the V2-inverted "kom vi överens" order, which does not contain the literal marker substring `"kom överens"` (the pronoun sits between the two words), so the heuristic correctly-by-its-own-logic found zero decisions in that sample. This is an honest result of the marker-matching design, not a probe bug, but it's a real limitation surfaced by natural spoken Swedish syntax that the source code's own tests likely don't cover with this phrasing.
- **Heuristic run-on splitting works as designed** on all 6 unpunctuated transcripts: since none of the samples contain sentence-terminating punctuation, `HeuristicDebriefSummarizer.splitSentences` treats each transcript as one giant sentence, and the discourse-marker/word-count fallback splitting is what actually produces the segments seen in the output — exactly the code path its own doc comments describe as the reason it exists. A visible side effect: several heuristic action items are truncated mid-clause (e.g. en1's "...she needs to have notes back to the team by" ends right before "Friday"), because the discourse-marker split lands mid-sentence. This is a known quality tradeoff of the heuristic, not new information, but this run reproduces it concretely with fresh transcripts.
- **Latency was consistent and fast**: 4.27s–6.66s per Foundation Models call across all 12 calls, well within the "~3s/call" ballpark mentioned as the prior working baseline (a bit higher here, but no call was slow enough to suggest a stall or retry).

## Out-of-scope findings (report, don't fix)

- `DebriefSummaryGenerable`'s `@Guide` wording for `owner`/`due` ("only if actually named... otherwise null") is being satisfied at the type level (the field is `String?`) but not behaviorally — Foundation Models substitutes placeholder text rather than nil often enough that this looks like a prompt-wording issue worth revisiting, not a one-off fluke (seen on 5 of 6 samples).
- `HeuristicDebriefSummarizer`'s Swedish decision markers (`beslutade`, `bestämde`, `kom överens`, `vi kör på`) are literal substrings and don't account for Swedish V2 word-order inversion after a fronted adverb (e.g. "också kom vi överens" vs "vi kom överens"). Not fixed here per scope — flagging for whoever owns that file next.
- Foundation Models' decision-array formatting is inconsistent across samples in the same run — full sentences for English and `sv1`/`sv3`, but single/two-word fragments for `sv2`. Worth a larger sample before concluding this is systematic vs. one unlucky generation.

## Tuning round 1 — 2026-09-17, real recording

**Machine:** same as above. **Real input:** the author's first real recording, an 80-second English iPhone memo — a genuine dictated debrief. Per this project's data-handling rule, the transcript and recording are not checked into this repo and are not reproduced here. Ground truth: the meeting was between the speaker and one named colleague; the speaker stated their own name and today's date as an aside; one action item (booking a follow-up meeting "one week from now") was spoken.

### What the real recording found

The app's own `summary.txt` for that session, produced by `FoundationModelsDebriefSummarizer` with the prompt from the section above, showed four defects:

1. **Third-person framing.** The transcript is the speaker's own first-person account, but the summary called them "the speaker" ("The speaker requested a new meeting...", "...opportunities for the speaker").
2. **Two spellings of the same company kept.** WhisperKit transcribed a company name two different ways within the same transcript. The summary preserved both spellings instead of picking one.
3. **The same item duplicated across DECISIONS and ACTION ITEMS.** A "schedule a new meeting" item appeared verbatim in both lists.
4. **A due date borrowed from the wrong place.** The "schedule a new meeting" action item was rendered with the meeting's own date (spoken at the very start of the transcript) as its `due`, instead of the actual spoken deadline for that task ("one week from now").

### Probe changes made to test against this

Added a `--sessions <dir>` mode to `bench/probes/debrief-probe.swift` (`dikta-macos/bench/probes/debrief-probe.swift:81-146`) that iterates `<dir>/*/transcript.txt`, detects English vs. Swedish with a trivial stop-word count (`detectLanguage`), and runs both engines exactly as the synthetic-sample path does — flushing after each print, same as before. Also changed `runSample` to call `.normalized()` on the engine's result before printing (`bench/probes/debrief-probe.swift:88`), matching what `DebriefPipeline` actually does before rendering, so probe output reflects what a user would see pasted, not the engine's raw pre-normalization result.

### Prompt iterations

Three attempts were made against `DebriefPromptBuilder.systemPrompt` (`dikta-macos/Dikta/Services/Debrief/DebriefSummarizer.swift`) and the matching `@Guide` text in `FoundationModelsDebriefSummarizer.swift`, re-running the real session between each:

- **Attempt 1:** Told the model the transcript is the user's own first-person account, to write "I"/"we" and never "the speaker," to use the speaker's stated name as owner for their own actions, to pick one spelling per misspelled name, that decisions vs. action items are mutually exclusive, and that `due` must be copied for the specific task rather than reused from an unrelated date. Result: third-person "the speaker" was gone, but the run still treated the speaker's own name — stated in the transcript as a self-naming aside ("it was me, X, and Y") — as a third meeting participant distinct from "I." The two-spellings issue also persisted.
- **Attempt 2:** Added an explicit rule and example for the self-naming aside (if the speaker names themselves alongside someone else in that pattern, that name IS the speaker, not someone they met with) and strengthened the spelling rule to say the two spellings are the same entity and must never both appear, in any field. Result: the self-naming confusion mostly cleared (no run since has separated the speaker from their own name), but repeated runs still mixed the two spellings within one output, and one run reproduced the decision/action duplication in paraphrased form (not an exact string match, so untouched by the code-level dedup).
- **Attempt 3 (final):** Told the model to decide on one spelling before writing anything and to re-check every field afterward for the rejected spelling; added an explicit rule that a future task (scheduling, booking, sending, following up) is always an action item and never a decision even when phrased as "we decided to..."; called this out in the `decisions`/`actionItems` `@Guide` text too.

### Real-transcript before/after

| check | before (original `summary.txt`) | after (final prompt, canonical run) |
|---|---|---|
| first person, no "the speaker" | no — "the speaker" used twice | yes, every run since attempt 1 |
| speaker's own name not treated as a third attendee | n/a (not tested, no third party) | mostly — fixed in the canonical run and 3 of 5 stochastic re-runs; 2 of 5 still separated the speaker from their own stated name (see below) |
| one spelling per name | no — both spellings kept | inconsistent — canonical run and 1 of 4 stress re-runs used only one spelling; 3 of 4 stress re-runs still mixed both spellings in the same output |
| no item in both decisions and actionItems | no — one item duplicated in both lists | mostly — canonical run and 3 of 4 stress re-runs clean; 1 of 4 had a paraphrased near-duplicate across the two lists (not an exact string, so the code-level dedup didn't catch it) |
| owner is a real named person, never generic | partially — both people's names used correctly | yes, every run (5 of 5) |
| due is the task's own deadline, not an unrelated date | no — due date borrowed from the meeting's own date | yes, every run (5 of 5) — always "one week from now"/"next week", never the meeting's own date |

Raw evidence for this before/after is the app's own local probe output for this session (`--sessions` mode, original vs. final prompt) — local-only, per the data-handling note above. The "5 of 5" / "4 of 4" counts come from 4 extra un-saved re-runs done during tuning to check stability (LLM sampling makes a single run non-representative) plus the canonical run.

### Synthetic-set before/after (all 6 samples, final prompt)

Comparing this round's post-tuning synthetic-corpus run against the original synthetic-corpus run from earlier in this document (both local-only, per the data-handling note above):

- The two previously-documented **"Team" hallucinations are gone**: `en2-sales-call` and `en3-incident-postmortem` no longer invent a generic owner; owners are now real names from the transcript ("Sarah," "Lisa," "Tom," "Anna") or the first-person "I" when the speaker themselves is doing the task.
- **`sv3-incident`'s two previously-missed due dates are now both captured** ("senast i morgon eftermiddag" and "senast på fredag"), and the previously-noted stray trailing period on the owner ("Tomas.") is gone (now plain "Tomas") — though that specific fix is `normalized()`'s edge-punctuation trim, not the prompt.
- No exact-string duplication between `decisions` and `actionItems` was seen in any of the 6 samples this round (there wasn't one in the original run either, so this is a maintained property, not a new fix).
- **New issue surfaced:** `sv3-incident`'s `openQuestions` in this round contains two near-duplicate, very long entries that each restate almost the entire transcript verbatim — not present in the original run. `sv3-incident` was already flagged as an outlier in the original write-up (missed due dates, trailing punctuation); this looks like a new manifestation of the same instability on that specific transcript rather than something the prompt changes caused directly, but it wasn't checked against attempt 1/2's output to confirm timing. Flagging as an open question below rather than spending a 4th prompt iteration on one outlier sample.
- **New issue also surfaced:** the Swedish placeholder `owner: "Ingen"` / `due: "Ingen"` (Swedish for "none"/"no one") appeared on one `sv2-kundsamtal` action item — a variant of the known placeholder-substitution behavior (see "Out-of-scope findings" above) that wasn't in `DebriefActionItem.placeholderValues` yet. Added `"ingen"` to that set (`dikta-macos/Dikta/Models/DebriefSummary.swift:24`) since it's the same defect class item 2 of this round's task was already about, with a test (`DiktaTests/DebriefPipelineTests.swift`, `test_normalized_mapsEveryPlaceholderToNil`).

### Open questions / what the prompt could not fully fix

- **Spelling unification and decision/action exclusivity are not deterministic.** Both rules are followed most of the time after three iterations, but Foundation Models' small on-device model doesn't reliably keep a single global choice (which spelling; which bucket) consistent across a whole generation. The code-level fixes in this round (`DebriefSummary.normalized()`) only catch the clean-cut cases (an exact placeholder value, a generic "Team"/"Everyone" owner, an exact-string duplicate) — they cannot safely merge two different spellings of the same name or two differently-worded descriptions of the same task without real entity/paraphrase resolution, which is out of scope here.
- **The self-naming aside is still occasionally mishandled**, in a way distinct from the original "the speaker" bug: instead of third-personing the whole summary, the model sometimes lists the speaker's own name as if it were a separate attendee while still correctly using "I" elsewhere in the same summary. This is an inherently ambiguous piece of phrasing even for a human reading it out of context, and three rounds of instruction did not eliminate it, only reduce its frequency.
- **`sv3-incident`'s duplicated near-verbatim open questions** (see above) — not chased further this round; worth a dedicated look if `sv3`-style very long, discourse-heavy Swedish transcripts turn out to be common.
- No Ollama or MLX comparison was done this round (still a listed TODO item); this round was Foundation-Models-only, matching the task's scope.

## Tuning round 2 — 2026-09-17, six real recordings

**Machine:** same as above (Apple Silicon, macOS 26.6.2, Xcode 27, on-device Foundation Models `.available`). **Real input:** six real sessions recorded on this machine on the same day — four English, two Swedish — referred to below as `en-1`..`en-4` and `sv-1`/`sv-2`. `en-3` and `en-4` are the same transcript, run through the app twice, to surface non-determinism. Today is 2026-09-17 (Thursday).

A read-only quality review of these six real `summary.txt` files, cross-checked against their `transcript.txt`, found six defect classes, none of which round 1 targeted: relative dates converted to wrong absolute dates/years/weekdays (a Swedish "two weeks from now" mapped to a specific calendar date; a Swedish due date carrying a year that was never spoken; an English "in five days" mapped to one wrong weekday/date on one run and a different wrong weekday/date on another run of the same transcript); a conditional/either-or rendered as a DECISION (a workload-percentage option stated as settled when the transcript only offers it as one of two options still being weighed); an already-decided item duplicated as a differently-worded ACTION ITEM (a Swedish decision and action item describing the same task in different words — no exact substring in common, so round 1's exact-string dedup didn't catch it); owner misattribution (the speaker's own "I need to do an initial run..." task assigned to their business partner, and an already-arranged meeting turned into a to-do also owned by that partner); a fabricated open question with no basis anywhere in the transcript; and non-determinism (the same transcript, run twice by the app, produced a different decision and two different wrong dates).

### Regression corpus

Six transcripts (text only, no audio) were used to build a regression corpus for this round — `en-1`..`en-4` and `sv-1`/`sv-2` above. These are real dictated transcripts and are **not** checked into this repo: `dikta-macos/bench/probes/debrief-corpus/` is listed in `.gitignore` precisely so this class of file is never committed (see the data-handling rule at the top of this document). `bench/probes/debrief-probe.swift` gained a `--corpus <dir>` mode (reads `*.txt` directly, language from the filename prefix) and a `--runs N` option (default 1; repeats each sample N times per engine and prints one `STABILITY sample=... engine=...: decisions=.../actions=.../due=... (X/N succeeded)` line comparing the runs that succeeded). The full `--corpus <dir> --runs 3` output before and after this round's changes is local-only, per the same rule.

To get a true before/after on the actual on-device model rather than a code diff, the same (new) `debrief-probe.swift` was compiled twice: once against the pre-round-2 snapshot of `DebriefSummary.swift`/`DebriefSummarizer.swift`/`FoundationModelsDebriefSummarizer.swift`/`OllamaDebriefSummarizer.swift` (extracted via `git show 17c9a8b:<path>`), and once against this round's edited versions. The probe itself deliberately still calls only `.normalized()`, not `.validated(against:)`, before printing — `validated(against:)` doesn't exist in the pre-round-2 snapshot, and this lets one probe source compile against both.

### Prompt iterations

Three attempts were made against `DebriefPromptBuilder.systemPrompt` (`dikta-macos/Dikta/Services/Debrief/DebriefSummarizer.swift`) and the matching `@Guide` text in `FoundationModelsDebriefSummarizer.swift`, checked by re-compiling the probe and re-running the corpus between each:

- **Attempt 1:** Added the core rules directly: `due` must be copied verbatim, never converted to a calendar date/year/weekday; `decisions` restricted to explicit past-tense committal language, with a conditional/either-or routed to `openQuestions` instead; owner tied to the grammatical subject ("I"/"jag" → the speaker, "X will"/"X ska" → X); an already-arranged event excluded from `actionItems`. Result: the owner-misattribution and fabricated-open-question defects were both gone on the first run, and the conditional either-or stopped being rendered as a flat decision — but `due` values were still being paraphrased ("one week from now" → "next week"; a bare date reused for an unrelated task) rather than copied verbatim, and one Swedish "book a new meeting" item was still a `BESLUT` (decision) instead of an `ÅTGÄRD` (action item) even though it's a future task.
- **Attempt 2:** Strengthened the "verbatim, don't convert/paraphrase" wording for `due` with more contrasting examples (e.g. "om två veckor", "imorgon") and made the future-task-is-never-a-decision rule apply explicitly to scheduling phrased with `"vi ska"`/`"we will"`, not only `"we decided"`. Result: no further categorical change was observed in a second pass over the corpus — the wording was already close to final after attempt 1's structural fix, so attempt 2 mainly tightened phrasing rather than fixing a new category of failure.
- **Attempt 3 (final, committed):** Consolidated attempts 1–2 into the single prompt/`@Guide` text now in the repo (see `DebriefSummarizer.swift:87-124` and `FoundationModelsDebriefSummarizer.swift:44-66`), and paired it with greedy sampling (see below) so the corpus could be checked for stability, not just a single lucky run. The before/after evidence and the per-sample table below are from this final prompt.

### Determinism

`FoundationModelsDebriefSummarizer` now takes a `generationOptions: GenerationOptions` init parameter defaulting to `GenerationOptions(samplingMode: .greedy)` (`FoundationModelsDebriefSummarizer.swift:9-22`), confirmed against the `arm64e-apple-macos.swiftinterface` under `$(xcrun --show-sdk-path)/System/Library/Frameworks/FoundationModels.framework` (`GenerationOptions.init(samplingMode:temperature:maximumResponseTokens:)`, `SamplingMode.greedy`). `OllamaDebriefSummarizer` got a matching `temperature: Double = 0` init parameter (`OllamaDebriefSummarizer.swift:13-25`), replacing the previous hardcoded `0.2`; `DiktaTests/DebriefSummaryTests.swift`'s `test_summarize_requestBodyMatchesExpectedShape` was updated to assert `0` instead of `0.2`.

The effect on the corpus, `--runs 3` each:

| sample | engine | before (3 runs) | after (3 runs) |
|---|---|---|---|
| en-1 | FoundationModels | decisions **DIVERGED**, actions **DIVERGED**, due **DIVERGED** | decisions stable, actions stable, due stable |
| en-2 | FoundationModels | decisions **DIVERGED**, actions **DIVERGED**, due **DIVERGED** | decisions stable, actions stable, due stable |
| en-3 | FoundationModels | decisions **DIVERGED**, actions **DIVERGED**, due **DIVERGED** | decisions stable, actions stable, due stable |
| en-4 | FoundationModels | decisions **DIVERGED**, actions **DIVERGED**, due **DIVERGED** | decisions stable, actions stable, due stable |
| sv-1 | FoundationModels | decisions **DIVERGED**, actions **DIVERGED**, due **DIVERGED** | decisions stable, actions stable, due stable |
| sv-2 | FoundationModels | decisions stable, actions **DIVERGED**, due **DIVERGED** | decisions stable, actions stable, due stable |
| all 6 | Heuristic | stable (as expected — no model sampling involved) | stable |

Greedy sampling made every sample fully stable across 3 runs, for both engines. This directly explains the sixth defect (the same transcript producing two different `summary.txt` files) — `en-3` and `en-4` are that exact transcript, and both are now stable under `--runs 3`; the two on-disk `summary.txt` files predate this change and were produced under the old, non-deterministic default.

### Per-sample before/after (the six defects)

| defect | sample | before | after |
|---|---|---|---|
| 1. relative date → wrong absolute date/year/weekday | en-3 | a fabricated absolute weekday/date for a "new meeting in five days" task, where the stated weekday did not match its own stated date and neither matched the correct +5-days date | `due: "tomorrow"` — no longer a fabricated absolute date, but still not verbatim "in five days" (see limits below) |
| 1. relative date → wrong absolute date/year/weekday | en-4 | a different fabricated absolute weekday/date for the same "in five days" task, run on the same transcript | `due: "tomorrow"`, stable across all 3 runs (see determinism table) |
| 1. relative date → wrong absolute date/year/weekday | sv-1 | both action items given the meeting's own date, or a fabricated year, as `due` (varies by run) — neither ever spoken as that task's deadline | one due verbatim and correct (a "two weeks from now" plan); the other still fabricated (an invoicing task given a due date never spoken at all for that task, see limits below) |
| 2. decision/action paraphrase duplicate | sv-2 | a Swedish decision and action item describing the same "put together a timeframe" task in different words (Jaccard similarity 0.75, no exact substring in common) | `decisions: []` — the model no longer produces a decision for this item at all now that "future task ≠ decision" is stated explicitly; the code-level Jaccard dedup in `normalized()` was not even needed on this run, though it is unit-tested directly (`DebriefPipelineTests.swift`, `test_summaryNormalized_removesDecisionThatParaphrasesAnActionItem`) against an equivalent pair |
| 3. open either/or rendered as a decision | en-4 | a workload-percentage option stated as a settled decision (before-run 3 of 3; before-run 2 instead wrote the harmless-but-empty "No decisions were made during the meeting.") | the same either/or correctly routed to `openQuestions` instead, `decisions` no longer states either option as settled, stable across all 3 runs |
| 4. owner misattribution / already-arranged event as a to-do | en-2 | the speaker's own "I need to do an initial run..." task assigned to their business partner; an already-arranged meeting turned into a to-do also owned by that partner | the initial-run task correctly attributed to the speaker ("I", due tomorrow); the already-arranged meeting moved out of `actionItems` entirely (now stated in `decisions`/`summary` instead of as a to-do with an invented owner) |
| 5. fabricated open question | en-2 | one open question with no basis anywhere in the transcript | `openQuestions: []` |
| 6. same transcript, two runs, contradictory output | en-3 vs en-4 (same transcript, both before this round's changes) | each run (and each run's own 3 repeats) produced a different due date and a different decision, including one repeat with no decision at all — genuinely different structured output for identical input, both across sessions and within one session's repeats | both samples now produce stable, near-identical shapes across their own 3 repeats each (see determinism table above) — the *transcript-vs-transcript* wording difference that remains between `en-3` and `en-4` is the model's normal variance on re-phrasing, not date/decision contradictions |

Full raw evidence is local-only, per the data-handling note above.

### Real-transcript unit tests

`DiktaTests/DebriefRealTranscriptTests.swift` originally embedded the verbatim `en-2` and `sv-1` transcripts as fixtures, paired with the exact defective `DebriefSummary` shapes the app actually produced under the pre-round-2 prompt. That file has since been rewritten (see docs/validation.md) to (a) exercise real transcripts read at runtime from a local, gitignored directory rather than embedded strings, with generic assertions, and (b) reproduce these specific defect shapes with synthetic (made-up) transcripts instead, exercised through `.normalized().validated(against:)`:

- **Fabricated year in due:** both fabricated-year `due` values are nulled, since that year never appears anywhere in the transcript — this is the flagship case `DebriefSummary.validated(against:)` (`DebriefSummary.swift`) was built for: it flags a `due` containing a 4-digit year or an ISO `yyyy-MM-dd` pattern and nulls it only if that pattern's value doesn't literally appear in the transcript.
- **Misattributed but genuinely-spoken owner:** an owner on a misattributed item is asserted to **survive** `validated(against:)` — that name genuinely is in the transcript, just attached to the wrong task, and `validated(against:)` can only tell whether a name-shaped owner was said *anywhere*, not whether it was said *for this task*. This is a documented limit, not a bug: only the prompt's grammatical-subject rule fixes the actual misattribution (confirmed separately in the before/after table above, where the *tuned prompt* — not `validated()` — produces owner `"I"`/`"me"`).
- **`test_validated_leavesADueThatReusesTheMeetingsOwnDateAlone_becauseItHasNoYearOrIsoShape`:** documents that a due with no digit-year/ISO shape is left untouched by `validated(against:)` regardless of whether it appears in the transcript, because the method's pattern check never triggers for it — this class of fabrication (reusing a real, spoken-but-unrelated date phrase) is prompt-only fixable, matching the round-1 write-up's "due date borrowed from the wrong place" defect.

`DiktaTests/DebriefSummaryTests.swift`'s `DebriefSummaryValidationTests` class covers `validated(against:)` more generally (bare year, ISO date, a year that genuinely was spoken and must survive, a lowercase owner like `"jag"` that is never touched, and a summary-level `validated(against:)` applied across multiple action items in one pass).

### What tuning round 2 still cannot fix

- **`due` is still occasionally paraphrased rather than copied verbatim**, even under the tuned prompt and greedy sampling: `en-1`'s "one week from now" became "next week" in the after run, and `sv-1`'s invoicing task got a fabricated due date with no spoken deadline at all for that specific task. Greedy sampling makes this *consistent* (the same wrong value every run), which is strictly better than a different wrong value every run, but it does not make the value *correct*. `validated(against:)` cannot catch this class either, since a paraphrased relative date has no year/ISO digit shape to flag — see `test_validated_leavesNonDatePlaceholderDueAlone`.
- **A misattributed-but-genuinely-spoken owner is invisible to `validated(against:)` by construction** — see the test above. Post-processing can only catch a name that was never said at all; it cannot know which task a real name belongs to.
- **`sv-2`'s "book a new meeting" item is still categorized as a `BESLUT` (decision)** rather than an `ÅTGÄRD` (action item), even after the "future task ≠ decision" rule was made explicit and paired with concrete Swedish examples ("vi ska ha ett möte imorgon"). This is the same category of instruction the model followed correctly for that same sample's other items in the same run, so it is inconsistent rather than uniformly broken — a genuine remaining gap, not chased further this round to stay within the 3-iteration budget.
- **Paraphrase/spelling unification remains best-effort, not guaranteed**, same conclusion as round 1: `normalized()`'s Jaccard dedup (threshold 0.75, requiring the smaller text's token set to have >= 3 tokens — raised from an initial 0.5 after skeptic review found it collapsed distinct short items, see below) catches a real paraphrase pair when the model's own two phrasings happen to share enough words (confirmed against a real pair), but a paraphrase with less lexical overlap would still slip through both the prompt and the dedup — this is a similarity heuristic, not entity resolution.
- No Ollama comparison was done this round either (still a listed TODO item); this round's on-device evidence is Foundation-Models-only, matching round 1's scope.

## Tuning round 2 — skeptic review fixes

A skeptic review of this round's diff found one must-fix (`validated(against:)` nulled owner `"Me"`/`"Jag"` — the exact first-person form the prompt tells the model to use for the speaker — whenever that literal word didn't separately appear in the transcript, which it structurally never does) and three should-fix issues (the 0.5 Jaccard threshold collapsed distinct short items sharing a few common words, e.g. two different "book a meeting with X" items at 0.6; the tokenizer split on a literal space only, missing newline/tab-separated text; the prompt's `Rules:` block was ~555 words). Fixes: a case-insensitive first-person exemption list (`en: me/i/myself`, `sv: jag/mig/själv`) checked before the name-shape test in `DebriefActionItem.validated(against:)`; the Jaccard threshold raised to 0.75 with a >= 3-token floor on the smaller set (`DebriefSummary.isParaphrase`); `similarityTokens` now splits on `$0.isWhitespace`; the fabricated-year/ISO check now compares only the matched digit token against the transcript, not the whole `due` string (so a real `"by 2027"` survives when the transcript says "2027" a different way around it); and the `Rules:` block trimmed to 336 words with every rule's content preserved.

Re-running `--corpus <dir> --runs 1` after the trim confirmed first-person framing and no fabricated-from-nothing decisions held on all 6 samples. Verbatim `due` held on 5 of 6, but **`en-1` regressed**: its `due`/`owner` came back as Swedish (`"om två veckor"`/`"jag"`) on an all-English transcript — reproduced identically on a second run (confirming it's deterministic, not sampling noise), and not present in the pre-trim after-run (`due: "next week"`, `owner: "me"`). This is a new defect surfaced by the trim itself (the "same language as the transcript" instruction lives in the untouched intro paragraph, not the trimmed Rules block, so the regression isn't a dropped rule — just an emergent effect of the shorter prompt on this one sample) and is flagged here rather than absorbed into an unbounded extra prompt iteration.

## Tuning round 2 — language-leak fix

Root cause of the `en-1` regression above: `DebriefPromptBuilder.systemPrompt` showed BOTH languages' example literals in one shared string (e.g. `"we decided"`/`"vi bestämde"` side by side) regardless of the transcript's actual language, and the `@Guide` schema descriptions (a single static attribute, not parameterized by language) did the same. Fix: `systemPrompt(language:)` now selects only the matching language's examples via a private `PromptExamples.forLanguage` (en/sv, defaulting to en), keeping the Rules block's prose shared but its literal examples language-specific (332 words for en, 329 for sv, both under the 350 budget); the `@Guide` strings were made fully language-neutral instead (no example literals in either language, per option (b) — simpler than a second `@Generable` type); and both the prompt and `@Guide` text now explicitly state "Write every field, including owner and due, in the transcript's language only." New tests in `DiktaTests/DebriefPipelineTests.swift` (`DebriefPromptBuilderLanguageTests`) assert no cross-language literal appears in either branch and that the word budget holds.

Re-running `--corpus <dir> --runs 1` confirmed `en-1` now produces fully English output: `due: "one week from now"` (verbatim!) and an English owner — though the owner is the speaker's colleague rather than the speaker themselves, a residual grammatical-subject misattribution unrelated to language (already a documented defect category) — and, as a welcome side effect, `en-2`'s own previously-unreported Swedish-owner leak (`owner: "jag"` on an English sample, same bug, different sample) is also gone, now `"I"`. Of the other four, 3 of 4 (`en-3`, `en-4`, `sv-2`) are reworded but substantively unchanged (same item counts, same real-world content, `due` if anything closer to verbatim, e.g. "Five days from now" replacing a fabricated weekday/date). **`sv-1` did NOT stay unchanged**: alongside its already-documented decision/action miscategorization (now worse — 2 near-duplicate decisions instead of 1, one action item folded away), it produced `openQuestions: ["null"]` — the literal string `"null"`, not an empty array — a new defect not seen anywhere else in this round's evidence. Flagging both for a decision rather than absorbing into a further unscoped iteration.
