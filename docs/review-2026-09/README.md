# dikta-macos Review — 2026-09-15

Orchestrated review. 4 workers (Opus code review, Opus STT research, Sonnet WhisperKit scout, Haiku build grunt) + Opus skeptic pass on research claims. Internal planning artifact. Caveman.

| Report | Worker | What |
|---|---|---|
| [build-health.md](build-health.md) | grunt | Build/test on Xcode 26.6 / macOS 26.6.2 |
| [mac-code-review.md](mac-code-review.md) | heavy (opus) | Pipeline map, coupling, tech debt, tests, top 5 |
| [whisperkit-drift.md](whisperkit-drift.md) | scout | WhisperKit 0.9.4 → 1.1.0, API drift, model catalogue |
| [stt-landscape-2026-09.md](stt-landscape-2026-09.md) | heavy (opus) | On-device STT options May–Sep 2026, sv+en |

## Headline Findings

### 🔴 Release blocked since 2026-05-02
Commit `8696fbc` added `TeamsMuter/SlackMuter/WhatsAppMuter/UvenMuter.swift` on disk. Never registered in `project.pbxproj`. `MuterRegistry.swift:6-9` references them → `xcodebuild build` + `test` fail at module emit. `swift build` + `swift test` (68 tests) pass — SPM globs dir. `scripts/build-release.sh:59` uses `xcodebuild archive` → **no release possible for 4.5 months**. Last shipped: v1.2, appcast 2026-04-06. Mic-muter feature never shipped.

### 🔴 Two WhisperKit versions in repo
`Package.resolved` (SPM) → 0.9.4. `Dikta.xcodeproj/.../Package.resolved` (Xcode) → 0.15.0. `project.pbxproj:715-722` has own package ref, `upToNextMajor 0.9.0`, no ceiling. Dev loop and shipped binary run different WhisperKit. Upstream renamed → `argmaxinc/argmax-oss-swift` at v1.0.0 (2026-05-01). Latest v1.1.0 (2026-08-06). **Zero breaking changes hit Dikta's 5 call sites.** Upgrade effort: S.

### 🟠 Swedish accuracy poor, fixable without new dependency
Dikta offers `small`/`medium` OpenAI Whisper only. OpenAI `small` sv FLEURS WER 20.6%. KB-Whisper `small` 7.3%. Same size. WhisperKit loads any HF repo with correct layout (`modelRepo:` param). No official KB-Whisper CoreML — convert with `whisperkittools` or trial community repos (UNVERIFIED quality). `large-v3-turbo_632MB` (645.7 MB actual) vs medium 1529.7 MB vs small 486.5 MB. Better on English (measured). **Swedish WER for turbo UNVERIFIED** — 7.8 FLEURS figure is plain large-v3; turbo has 4-layer decoder.

### 🟠 Apple does Swedish offline — wrong class checked by most writeups
macOS 26 `SpeechTranscriber.supportedLocales` = 30, no sv. `DictationTranscriber.supportedLocales` = 54, incl. `sv-SE`. Researcher + skeptic both reproduced on this host: `say -v Alva` synthetic Swedish (only sv voice installed), 7.2s audio → ~0.35s, 1 word error (`ett test`→`en test`), punctuation included, zero bundle bytes. **n=1 synthetic. Offline/air-gapped NOT tested.** Risk confirmed + understated: inverse text normalization hits both languages — en "quarter past three"→`3:15`, "twenty five dollars"→`$25`; sv `den tredje mars`→`3 mars`, `tvåhundra kronor`→`200 kr`. Collides with Dikta formatter stage. Must measure before default.

### 🟡 Code health
No deprecations under Xcode 26. Zero TODO/FIXME. But:
- Model switch requires app restart (`MenuBarViewModel.swift:58`, `:370-377`). `Transcriber` built once, `modelName` is `let`.
- `medium` never bundled by release script → silent multi-GB download, no progress (`Transcriber.swift:39-45`, `build-release.sh:93`).
- Two model-naming schemes: download path passes bare `"small"`, bundled path `openai_whisper-small` (`Transcriber.swift:39` vs `:61`).
- Paste types char-by-char, `usleep(1000)` per char on MainActor (`ClipboardManager.swift:20-43`). ~0.5s stall per 500 chars.
- Test target hand-copies `AppConfig` (exec target not `@testable`). Copy drifted — missing `formatSelection`. Zero tests on `Transcriber`.
- Parakeet TDT v3 sv FLEURS 16.8% — worse than KB-Whisper small. Not a Swedish answer. English-only win.

## Status — first update shipped 2026-09-15

PR #13 `fix/review-2026-09` → main. 15 commits, skeptic-approved (opus, 3 rounds). 235 tests green under `swift test` + `xcodebuild test` (ad-hoc signing overrides).

| Item | Status |
|---|---|
| 1. Register Muter files, CI `xcodebuild` | ✅ 33c85b3, 0b117b6, 7ea0d1a |
| 2. WhisperKit → argmax-oss-swift 1.1.0, lockfiles agree | ✅ c358015 (needed explicit `.product(name:package:)` — SPM byName fails vs renamed pkg) |
| 3. `TranscriptionEngine` + `repo`/`variant` + live reload | ✅ 846dd6f, 3f5ec14, bd1bd81 (skeptic caught failed-reload regression → fallback to previous model) |
| 6a. Tests `@testable import`, `cleanSegments` tests, view-model tests | ✅ 0d467fe, e1cb0c1, 45843a0, f555dc9 |
| 4. Model swap + KB-Whisper tier | ⏳ update 2 |
| 5. `DictationTranscriber` experiment | ⏳ update 2 |
| 6b. `DiktaCore` target, paste off MainActor, `medium` download UX | ⏳ update 2 |

New follow-ups from skeptic: replace `isRunningUnderXCTest` guard in `MenuBarViewModel` with defaulted init param; align DiktaTests signing with app target (Manual/Developer ID vs Automatic). Note: `.claude/worktrees/` in dikta has 3 stale locked agent worktrees at 608b669 from earlier runs — cleanup candidate.

## Status — second update (branch `feat/update-2-models`, 2026-09-15)

Stacked on PR #13. Reports: [benchmark-2026-09-15.md](benchmark-2026-09-15.md), [apple-dictation-engine-spec.md](apple-dictation-engine-spec.md), [foundation-models-probe-2026-09-16.md](foundation-models-probe-2026-09-16.md) (blocked — `SensitiveContentAnalysisML`/`ModelManagerError 1013` fails every `LanguageModelSession.respond` call on this Mac before any formatting could be tested), [benchmark-2026-09-16-apple.md](benchmark-2026-09-16-apple.md) (Apple Dictation engine now driven by DiktaBench: sv 11.68% / en 11.18% WER, ~1.2s load).

| Item | Status |
|---|---|
| Benchmark harness `dikta-macos/bench/` (DiktaBench + FLEURS + jiwer) | ✅ |
| `large-v3-turbo` option + download progress + disk guard | ✅ |
| Apple `DictationTranscriber` engine | ❌ removed 2026-09-16 — decision: not shipping Apple STT (worse WER than turbo/KB-Whisper, no benefit over built-in macOS dictation; see [benchmark-2026-09-16-apple.md](benchmark-2026-09-16-apple.md)) |
| KB-Whisper sv tier | ⏸ **decision needed** — see below |
| `medium` download UX | ✅ (progress row covers it) |
| Paste off MainActor, `DiktaCore` target, XCTest guard → init param | ⏳ update 3 |

**Measured (FLEURS test, 20 clips/lang, this Mac):** small sv 18.5% / en 9.9%. turbo sv 10.1% / en 6.7%. **kb-whisper-small sv 3.5%** / en 54.2%.

Conclusion: turbo = solid default upgrade both languages. KB-Whisper = 3× better Swedish than turbo, useless for English → only viable as sv-gated tier. Blocker is provenance: only CoreML conversion is community upload `Leonidng/whisperkit-kb-whisper-small`. Options: (a) convert `KBLab/kb-whisper-small` + `-medium` ourselves with `whisperkittools`, publish under own HF org (~hours, python/torch/coremltools env); (b) ship community repo pinned to a revision hash; (c) skip. Apple DictationTranscriber sv 11.7% / en 11.2% WER vs turbo sv 10.1% / en 6.7%, KB-Whisper sv 3.5% — see [benchmark-2026-09-16-apple.md](benchmark-2026-09-16-apple.md).

## Proposed Order (original)

1. **Unblock release.** Register 4 Muter files in pbxproj. Add CI step: `xcodebuild build` (SPM alone hides this class of bug). Effort: XS.
2. **Unify WhisperKit pin → argmax-oss-swift 1.1.0** in Package.swift + pbxproj. Effort: S. No code changes.
3. **Model layer refactor**: `TranscriptionEngine` protocol, engine-qualified model ids (`repo` + `variant`), live `reload(modelName:)`. Effort: M. Prereq for 4+5.
4. **Model swap**: `medium` → `large-v3-turbo_632MB` (benchmark sv first — unmeasured); add Swedish tier (KB-Whisper small/medium via whisperkittools conversion). Gate KB-Whisper behind sv language selection — English regression unmeasured. Effort: M incl. conversion + benchmark.
5. **Experiment**: Apple `DictationTranscriber` as selectable engine. Benchmark vs KB-Whisper on real human sv + en audio, measure ITN vs formatter. Effort: M. Promote to default only on data.
6. **Hygiene**: `DiktaCore` library target, test `cleanSegments`, paste off MainActor, medium download UX.

## Skeptic Verdict on Research Claims

Opus skeptic, 2026-09-15. Verdict: **request_changes** → edits routed back to researcher, applied same day.

| Claim | Verdict |
|---|---|
| `SpeechTranscriber` 30 locales no sv; `DictationTranscriber` 54 incl. sv-SE | CONFIRMED (re-ran probe; offline unproven) |
| 7.2s sv audio → 1 word error, 0.37s | CONFIRMED reproducible, but `say -v Alva` TTS, n=1, not a quality signal |
| KB-Whisper small 7.3 vs OpenAI small 20.6 sv FLEURS | CONFIRMED (KBLab README; medium 6.6 vs 12.1, large 5.4) |
| large-v3-turbo_632MB exists, smaller than medium | CONFIRMED (645.7 MB vs 1529.7 MB) |
| Parakeet v3 sv FLEURS 16.8 | CONFIRMED (FluidAudio Benchmarks.md:38, M4 Pro, undated) |
| DictationTranscriber aggressive ITN | CONFIRMED + understated — 5/5 en samples normalized, sv too |

Corrections forced: "real audio" → synthetic; "numbers left as words in Swedish" REFUTED; turbo Swedish quality unmeasured; "0.9.x" vs Xcode lockfile 0.15.0 reconciled; "two majors behind" → one.

## Gaps / Not Done

- munin recall for dikta unavailable from takt cwd (auto-scoped). Prior decisions not loaded.
- dikta-windows not reviewed (out of scope per user).
- No audio benchmark run — recommendations rest on published WER + one synthetic sample.
- Community KB-Whisper CoreML repos not downloaded or tested.
