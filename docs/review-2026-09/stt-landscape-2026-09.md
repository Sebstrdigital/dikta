# On-Device STT Landscape for Dikta — May→Sep 2026

Research date: 2026-09-15. Host: macOS 26.6.2 (25G83), Xcode 26.6, Swift 6.3.3, Apple Silicon.
Scope: offline STT for macOS menu-bar dictation. Swedish + English equal priority. Short utterances.

---

## TL;DR

1. **Dikta current Swedish accuracy is bad and fixable today.** Dikta offers only `small`/`medium` OpenAI Whisper. OpenAI `whisper-small` Swedish FLEURS WER = **20.6%**. KB-Whisper `small` = **7.3%**. Same size, ~3x fewer errors. Drop-in swap, WhisperKit stays.
2. **Apple Speech framework DOES do Swedish — but not via `SpeechTranscriber`.** Verified locally today: `SpeechTranscriber.supportedLocales` = 30 locales, **no Swedish**. `DictationTranscriber.supportedLocales` = 54 locales, **includes `sv-SE` and `id-ID`**. Ran Swedish audio end-to-end: worked, 7.2s audio in **0.37s**, 1 word error, punctuation + capitalization included. Zero bytes in app bundle. **Caveats: audio was `say -v Alva` synthetic TTS (only Swedish voice installed on this machine), n=1, 21 words. Offline / air-gapped operation was NOT tested — only the documented on-device claim plus a successful run after asset install.**
3. **Whisper is no longer the only Swift-native option.** FluidAudio (Apache/CC-BY, 2.8k stars, 18 releases since 2026-04-23) ships CoreML Parakeet TDT v3, Parakeet Unified, Nemotron streaming, SenseVoice, Paraformer. But Parakeet v3 Swedish FLEURS WER = **16.8%** — worse than KB-Whisper small. Parakeet is an English/Romance win, not a Swedish one.
4. **Best-of-both = per-language routing.** No single model is top-3 on both sv and en. Swedish wants KB-Whisper (or Apple dictation); English wants Parakeet Unified / large-v3-turbo / Apple `SpeechTranscriber`.
5. **Biggest risk item:** Apple `DictationTranscriber` applies aggressive inverse text normalization in **both** languages — English "quarter past three" → `3:15`, Swedish `den tredje mars` → `3 mars`, `tvåhundra kronor` → `200 kr`. This is a larger collision with Dikta's downstream formatter stage than a purely English quirk would be. Must be measured before committing.

---

## Timeline (May–Sep 2026)

| Date | What | Why it matters for Dikta | Source |
|---|---|---|---|
| 2026-01-29 | Qwen3-ASR 0.6B / 1.7B open-sourced, Apache-2.0, 52 languages incl. Swedish | Best open ASR accuracy measured by Argmax (11.86 WER on earnings22 vs 15.4 for large-v3-turbo). No CoreML/Swift path in OSS. | https://arxiv.org/html/2601.21337v1 · https://huggingface.co/Qwen/Qwen3-ASR-0.6B |
| 2026-02-04 | Mistral Voxtral Mini 4B Realtime, Apache-2.0, sub-500ms, 13 languages | **Swedish NOT in the 13.** Rules it out for Dikta. | https://developers.redhat.com/articles/2026/02/06/run-voxtral-mini-4b-realtime-vllm-red-hat-ai |
| 2026-05-01 | **WhisperKit → Argmax OSS SDK v1.0.0.** Repo renamed `argmaxinc/WhisperKit` → `argmaxinc/argmax-oss-swift`. Breaking. Swift 6 concurrency. Vendors swift-transformers. MIT. | Dikta's `Package.swift` pins 0.9.x (SPM resolves 0.9.4) while the Xcode lockfile resolves 0.15.0 — see `whisperkit-drift.md`. One major behind from the pin. Package URL and import changed. Migration required eventually regardless of model choice. | https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.0.0 |
| 2026-05 | NVIDIA `nemotron-asr-streaming-multilingual-0.6b` intermediate checkpoint | ~40 languages, cache-aware streaming RNNT, 560/1120/2240ms latency tiers. **No public HF repo — convert yourself, Linux+CUDA.** | https://raw.githubusercontent.com/FluidInference/FluidAudio/main/Documentation/ASR/NemotronMultilingual.md |
| 2026-05-04 | FluidAudio v0.14.4 — Parakeet v3 int4 encoder | Smaller on-disk multilingual option | https://github.com/FluidInference/FluidAudio/releases |
| 2026-06-04 | FluidAudio v0.15.0 — Nemotron 3.5 Streaming Multilingual 0.6B (40 locales, CoreML/ANE), SenseVoiceSmall CoreML, Paraformer-large CoreML, `DownloadUtils.enforceOffline` | `enforceOffline` is directly useful for Dikta's offline guarantee. Three new backends in one release. | https://github.com/FluidInference/FluidAudio/releases |
| 2026-06-13 | FluidAudio v0.15.3 — **Parakeet Unified 0.6B** (one checkpoint = offline batch + chunked streaming, English, with punctuation/caps) | Best measured English on-device number in this survey: 2.15% avg WER, 123x RTFx batch. | https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md |
| 2026-06-16 | FluidAudio v0.15.4 — per-token timings from streaming manager | Enables partial-result UI for push-to-talk | https://github.com/FluidInference/FluidAudio/releases |
| 2026-08-06 | **Argmax OSS SDK v1.1.0** — WhisperKit incremental audio loading (70%+ peak memory cut on 3h audio), promptTokens fixes | Memory win irrelevant for Dikta (short utterances). `promptTokens` fix is relevant for vocabulary biasing. | https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.0 |
| 2026-08-19 | FluidAudio v0.15.6 — `languageHint` on `SlidingWindowAsrConfig`; argmaxinc/whisperkit-coreml repo last updated | Language hint matters: Dikta already has a language toggle to feed it. | https://github.com/FluidInference/FluidAudio/releases |
| 2026-09-10 | FluidAudio v0.15.7 — decode-time custom vocabulary biasing (no CTC head), int8-linear Encoder_v2, `NemoTextProcessing` opt-out trait | Custom vocab without retraining. Opt-out trait keeps binary small for ASR-only apps like Dikta. | https://github.com/FluidInference/FluidAudio/releases |
| 2026-09-14 | `odens00volym/kb-whisper-coreml` published — KB-Whisper Large palettized to 1842MB for WhisperKit/ANE | **One day old.** First KB-Whisper that actually loads on ANE. Author states float16 KB-Whisper (1.27GB enc + 1.81GB dec) makes the ANE compiler "grind for an hour and produce nothing". | https://huggingface.co/odens00volym/kb-whisper-coreml |

Also relevant, dated before window but load-bearing:
- `nvidia/canary-1b-v2`, CC-BY-4.0, 25 European languages **incl. Swedish**, created 2025-08-04, last modified 2026-08-31. No CoreML conversion found. https://huggingface.co/nvidia/canary-1b-v2
- Argmax OpenBench Apple SpeechAnalyzer run `2025-12-30`; parakeet-v3 run `2025-12-12`; qwen3-asr-1.7b run `2026-08-04`. https://github.com/argmaxinc/OpenBench/blob/main/BENCHMARKS.md

---

## Candidate Matrix

WER sources differ per row — benchmark named in each cell. Do not cross-compare rows scored on different datasets.

| Engine / model | sv? | en? | Swedish WER | English WER | Disk | Latency class (M-series) | License | Swift path | Maturity / risk |
|---|---|---|---|---|---|---|---|---|---|
| **Apple `DictationTranscriber`** (`sv-SE`) | **YES** | YES | not published | not published | **0 MB in bundle** (OS asset) | measured 0.37s for 7.2s audio (~19x RT), warm | OS framework, free | `import Speech`, ~40 LOC | Framework GA in macOS 26. Risk: ITN too aggressive; Whisper-class quality unproven for sv; macOS 26+ only |
| **Apple `SpeechTranscriber`** | **NO** (verified) | YES | n/a | 17.0 earnings22-keywords no-kw (Argmax, run 2025-12-30) | 0 MB in bundle | measured 0.31s for 8s audio | OS framework, free | `import Speech` | Newer/better model than Dictation, but 30 locales only |
| **KB-Whisper large via WhisperKit** | **YES (best)** | degraded* | **5.4 FLEURS / 4.1 CommonVoice / 5.2 NST** (KBLab) | * see note | **1842 MB** | 1.7x real time on M1 Max ANE (repo author, 12.2 min sv radio) | Apache-2.0 | `modelRepo: "odens00volym/kb-whisper-coreml"`, `modelFolder: "KBLab_kb-whisper-large_1842MB"` | Repo 1 day old, single author, 0 downloads. First ANE load takes minutes. **Slower than turbo (32-layer decoder)** |
| **KB-Whisper small/medium via WhisperKit** | **YES** | degraded* | **7.3 / 6.6 FLEURS** (KBLab) | * | ~500MB / ~1.5GB equivalent | Whisper small/medium class — same as Dikta today | Apache-2.0 | **No maintained CoreML bundle.** Only `Leonidng/whisperkit-kb-whisper-small` (2026-03-08, 0 dl); `pappa1337/*-coreml` are encoder-only | **Convert yourself with whisperkittools.** Highest value/effort ratio in this table |
| Dikta today: OpenAI `whisper-small` | yes | yes | **20.6 FLEURS** (KBLab table) | — | ~500 MB | baseline | MIT (WhisperKit) | already integrated | Baseline. Swedish is the weak spot |
| Dikta today: OpenAI `whisper-medium` | yes | yes | **12.1 FLEURS** (KBLab table) | — | ~1.5 GB | baseline | MIT | already integrated | Baseline |
| **Whisper large-v3-turbo via WhisperKit** | yes | yes | **UNVERIFIED (#15)** — 7.8 FLEURS is plain large-v3; turbo has a 4-layer decoder and is not separately scored for sv | 15.4 earnings22 no-kw (Argmax) | **645.7 MB measured** (`openai_whisper-large-v3-v20240930_turbo_632MB`) | 7.5x real time on M1 Max (odens00volym) | MIT / Apache | already a WhisperKit repo folder | Safest single-model multilingual upgrade. Better than medium on en (measured), **sv unverified**, smaller than medium |
| **Parakeet TDT v3 (FluidAudio)** | yes | yes | **16.8 FLEURS, CER 5.0, RTFx 219** (FluidAudio, M4 Pro) | **5.4 FLEURS en-US / 2.5 LibriSpeech avg** | ~450–600 MB per encoder variant (int8/int4 avail) | ~110x RT batch | CC-BY-4.0 | `import FluidAudio`, `AsrModels.downloadAndLoad()` | Mature, 2.8k stars. **Swedish worse than KB-Whisper small.** No punctuation |
| **Parakeet Unified EN 0.6B** | **NO** | yes (best) | n/a | **2.15% avg / 1.68% aggregate LibriSpeech, 123x RTFx batch** (M5 Pro) | ~1.2 GB per encoder | 123x batch / 29x streaming | CC-BY-4.0 | FluidAudio | English-only. Punctuation + caps built in. int8 encoder fails on A16 (iOS only issue) |
| **Nemotron 3.5 Streaming Multilingual 0.6B** | UNVERIFIED | yes | **not published** | 8.96 FLEURS en (2.24s tier) | not distributed | 560/1120/2240 ms tiers, 130x RTFx | NVIDIA (check) | FluidAudio, **local path only** | **No HF repo.** Requires Linux+CUDA self-conversion. Swedish presence in the ~40 unconfirmed |
| **Nemotron Speech Streaming 0.6B (EN)** | no | yes | n/a | **2.58–2.71% LibriSpeech** across all three tiers | not stated | 560ms tier = 40.7x RTFx | NVIDIA | FluidAudio | English only |
| **SenseVoiceSmall (FluidAudio)** | no | yes | n/a | 3.22% fp16 / 3.25% int8 LibriSpeech | **447 MB fp16 / 225 MB int8** | ~400x RT | check FunASR | FluidAudio | Smallest good option but no Swedish |
| **Qwen3-ASR 0.6B / 1.7B** | **yes** (in Fleurs†† set) | yes | **not published per-language** | **11.86 earnings22 no-kw (1.7B, Argmax 2026-08-04)** — best in table | 1.88 GB (0.6B safetensors) | 92ms TTFT — **on vLLM/CUDA, not Mac** | **Apache-2.0** | **none in OSS.** Argmax Pro SDK only | Best accuracy, no open Apple path. Watch item |
| **NVIDIA Canary-1B v2** | **yes** (25 EU langs) | yes | not found | not found | 3.9 GB safetensors / 6.4 GB .nemo | unknown on Mac | CC-BY-4.0 | **no CoreML conversion found** | Too big + no Swift path |
| **Voxtral Mini 4B Realtime** | **NO** | yes | n/a | — | ~8 GB class | sub-500ms on GPU | Apache-2.0 | none | **Swedish absent. Excluded.** |
| whisper.cpp + CoreML | yes | yes | same weights as Whisper | same | same | ~2x slower than WhisperKit on Apple Silicon (secondary source) | MIT | C API, bridging | Regression vs current WhisperKit. No reason to switch |

\* **English regression on KB-Whisper is UNVERIFIED.** KBLab publishes Swedish WER only. The model is a Swedish fine-tune of Whisper; some English degradation is expected but not quantified anywhere found. Must be measured (see Experiment Plan).

---

## Apple SpeechAnalyzer Deep-Dive

All of this section was measured on this machine today, not read from docs.

### Swedish: supported, but only on the older of the two transcribers

```
SpeechTranscriber.supportedLocales   = 30  -> NO Swedish
  de-AT de-CH de-DE en-AU en-CA en-GB en-IE en-IN en-NZ en-SG en-US en-ZA
  es-CL es-ES es-MX es-US fr-BE fr-CA fr-CH fr-FR it-CH it-IT ja-JP ko-KR
  pt-BR pt-PT yue-CN zh-CN zh-HK zh-TW

DictationTranscriber.supportedLocales = 54 -> sv-SE PRESENT, id-ID PRESENT
  ar-SA ca-ES cs-CZ da-DK de-AT de-CH de-DE el-GR en-AU en-CA en-GB en-IE
  en-IN en-NZ en-SG en-US en-ZA es-CL es-ES es-MX es-US fi-FI fr-BE fr-CA
  fr-CH fr-FR he-IL hi-IN hr-HR hu-HU id-ID it-CH it-IT ja-JP ko-KR ms-MY
  nb-NO nl-BE nl-NL pl-PL pt-BR pt-PT ro-RO ru-RU sk-SK sv-SE th-TH tr-TR
  uk-UA vi-VN yue-CN zh-CN zh-HK zh-TW

SFSpeechRecognizer.supportedLocales() = 63 -> sv-SE present (legacy API)
```

All three of Dikta's languages (en, sv, id) are covered by `DictationTranscriber`. Only English is covered by `SpeechTranscriber`.

### Verified end-to-end Swedish run

Input: **`say -v Alva` synthetic TTS** — the only Swedish voice installed on this machine — "Hej, det här är ett test av diktering på svenska. Klockan är kvart över tre och jag skriver ett mejl till Sebastian." → 16 kHz mono WAV, 7.2s. **n=1, 21 words. Not human speech, not a benchmark.**

```
ASSET: install needed, downloading...
ASSET: installed
installed now: ["en-US", "sv-SE"]
elapsed=0.37s
RESULT: Hej, det här är en test av diktering på svenska. Klockan är kvart över
        tre och jag skriver ett mejl till Sebastian
```

- 1 word error out of 21: `ett test` → `en test`. WER ≈ 4.8% on this single synthetic sample (not a benchmark).
- Punctuation and capitalization emitted by the model.
- Asset installed on demand, ~seconds. After install the documented path is on-device. **Air-gapped operation was not tested.**

### Verified English comparison, same harness

```
SpeechTranscriber/en-US     elapsed=0.31s
  "Hey, this is a test of dictation in English."
  " It is a quarter past 3 and I am writing an email to Sebastian about the quarterly roadmap."

DictationTranscriber/en-US  elapsed=0.33s
  "Hey, this is a test of dictation in English. It is 3:15 and I am writing an
   email to Sebastian about the quarterly roadmap."
```

Both correct. **Note the ITN difference:** `SpeechTranscriber` gives "3"; `DictationTranscriber` rewrites "quarter past three" → "3:15". `DictationTranscriber` also returns the whole utterance as one result; `SpeechTranscriber` splits per sentence.

### Inverse text normalization hits both languages

`DictationTranscriber` rewrites spoken forms into typographic forms in Swedish as well as English. Samples:

| Language | Spoken | Emitted |
|---|---|---|
| sv-SE | `den tredje mars` | `3 mars` |
| sv-SE | `tvåhundra kronor` | `200 kr` |
| en-US | quarter past three | `3:15` |
| en-US | half past nine | `9:30` |
| en-US | March third | `March 3` |
| en-US | twenty five dollars | `$25` |
| en-US | thirty percent | `30%` |

This is a **larger formatter-collision risk than first written**. Dikta's downstream formatter stage cannot assume it receives spoken-form text in either language, and an earlier draft of this report wrongly stated that Swedish numbers are left as words. Currency, percentages, clock times and dates all arrive pre-normalized, and the normalization is not configurable through any option visible in the framework interface. Quantify the divergence before promoting Apple to default — see the ITN divergence metric in the Experiment Plan.

### Constraints

- **macOS 26+ only.** Dikta would need a WhisperKit fallback for older macOS, or bump minimum deployment target.
- **Not in the app bundle.** Assets are OS-managed via `AssetInventory`. Good: no 500MB–1.8GB download in Sparkle DMG. Bad: first-run requires network for the locale asset, and Dikta cannot pin a model version.
- **No model choice.** No quality/size tradeoff knob for the user. Dikta's `WhisperModel` enum has no analogue.
- **ITN is not configurable** as far as the interface shows. Downstream formatter must be tested against it.
- Sandboxing / App Store not a concern — Dikta ships via Sparkle.
- `AnalysisContext.ContextualStringsTag` and `SFCustomLanguageModelData` exist in the framework, so custom-vocabulary biasing is available. Not tested here.

### Integration code shape

```swift
import Speech
import AVFoundation

let locale = Locale(identifier: "sv-SE")           // or en-US, id-ID
let transcriber = DictationTranscriber(locale: locale, preset: .shortDictation)
// presets: .phrase .shortDictation .progressiveShortDictation
//          .longDictation .progressiveLongDictation .timeIndexedLongDictation
// SpeechTranscriber presets: .transcription .transcriptionWithAlternatives
//          .progressiveTranscription .timeIndexedProgressiveTranscription ...

if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await req.downloadAndInstall()             // one-time per locale
}

let analyzer = SpeechAnalyzer(modules: [transcriber])
_ = try await analyzer.analyzeSequence(from: audioFile)   // or .analyzeSequence(from: AsyncSequence of AnalyzerInput)
try await analyzer.finalizeAndFinishThroughEndOfInput()

for try await result in transcriber.results {
    let text = String(result.text.characters)      // result.text is AttributedString
}
```

For push-to-talk live streaming, feed `AnalyzerInput(buffer:)` from the existing tap instead of `AVAudioFile`, and use a `.progressive*` preset to get interim results.

Effort estimate: a new `SpeechAnalyzerEngine` alongside the existing WhisperKit engine, behind the same protocol. Roughly a day, plus a day on asset-state UI (not installed / downloading / ready) and formatter interaction.

---

## Ranked Recommendation

### #1 — Swap in better Whisper weights now; keep WhisperKit. (Low risk, big Swedish win)

Two changes to `WhisperModel.swift`, no architecture change:

- Replace `medium` with **`large-v3-turbo` (645.7 MB measured)**. Smaller than current medium (1529.7 MB measured), better on English (measured: 15.4 vs large-v3's own earnings22 baseline); **Swedish UNVERIFIED — see Unverified #15**. Already a published Argmax CoreML folder.
- Add a **Swedish-specific tier** backed by KB-Whisper. Preferred: convert `KBLab/kb-whisper-small` and `kb-whisper-medium` yourself with `whisperkittools` (Argmax's own tool, MIT). Fallback: point at `odens00volym/kb-whisper-coreml` large for a "best Swedish, slow" option — **but that repo is 1 day old, single author, 0 recorded downloads, and its quality and speed figures are self-reported from one sample. Treat as unvetted until you reproduce it.**

Rationale: Swedish goes from 20.6% → 7.3% FLEURS WER at the same model size. This is the single largest accuracy delta available and requires no new dependency. Dikta already has a language toggle to route on.

Caveat: KB-Whisper's English is unmeasured. Gate it behind the Swedish language selection, do not make it the default for all languages.

### #2 — Add Apple `DictationTranscriber` as the fast/zero-download path. (Medium risk, big UX win)

Verified working for Swedish, English and Indonesian, offline, ~20x real time, nothing in the DMG. Makes first-run instant instead of a 500MB download.

Ship it as a selectable engine, not a replacement. Two open questions gate promotion to default: real Swedish accuracy on human speech (not `say`), and whether its ITN fights the formatter stage.

### #3 — Migrate to Argmax OSS SDK v1.1.0, and watch FluidAudio. (Maintenance)

Dikta's dependency state is inconsistent and should be settled first. `Package.swift` pins 0.9.x and SPM resolves that to **0.9.4**, but the Xcode lockfile resolves **0.15.0** — see `whisperkit-drift.md`. Upstream is at `argmax-oss-swift` v1.1.0 with a breaking rename at v1.0.0 (2026-05-01), so the gap from the pinned version is **one major** (0.x → 1.x), not two. This migration is owed regardless. Do it while touching the model layer.

Do **not** switch to Parakeet for Swedish — 16.8% FLEURS is worse than KB-Whisper small. FluidAudio becomes interesting if Dikta ever wants English-only streaming partial results (Parakeet Unified, 2.15% WER with punctuation) or if `nemotron-asr-streaming-multilingual` gets a public HF repo with confirmed Swedish.

**Watch list:** Qwen3-ASR 0.6B (Apache-2.0, best measured accuracy, needs a CoreML conversion that nobody has published); Apple adding `sv` to `SpeechTranscriber` in a macOS 26.x point release.

---

## Experiment Plan

### Audio corpus (build once, reuse)

- **Swedish, real human:** 30–50 push-to-talk utterances recorded by the actual user on the actual mic, 5–60s each. Must include: code-switched English tech terms ("deploy en ny branch"), proper nouns, numbers and dates, filler words. This is the deciding dataset — synthetic `say` audio is not representative.
- **Swedish, public:** FLEURS `sv_se` test split (759 utterances, already used by FluidAudio's harness) for a comparable published number.
- **English, real human:** 30–50 equivalent utterances, same speaker, same mic.
- **English, public:** LibriSpeech test-clean subset, or FLEURS `en_us`.
- **Adversarial:** whispered speech, background music, 2m continuous, a 3-second one-word utterance (tests cold-start dominance).

### Configurations to measure

| # | Engine | Model | Languages |
|---|---|---|---|
| A | WhisperKit (baseline) | `openai_whisper-small` | sv, en |
| B | WhisperKit (baseline) | `openai_whisper-medium` | sv, en |
| C | WhisperKit | `openai_whisper-large-v3-v20240930_turbo_632MB` | sv, en |
| D | WhisperKit | `KBLab_kb-whisper-small` (self-converted) | sv, **en** |
| E | WhisperKit | `KBLab_kb-whisper-large_1842MB` | sv, **en** |
| F | Apple | `DictationTranscriber` | sv, en |
| G | Apple | `SpeechTranscriber` | en only |
| H | FluidAudio | Parakeet TDT v3 | sv, en |

D and E must be run on English too — that is the specific unverified claim this plan exists to settle.

### Metrics

- **WER**, computed with the same normalizer across all configs. Use FluidAudio's `TextNormalizer` or NeMo-compatible `text-processing-rs` so numbers are comparable to the published tables. Report aggregate (total errors ÷ total words), not mean-of-per-file, and say which.
- **Score punctuation separately.** Dikta has a downstream formatter, so a model that emits no punctuation (Parakeet TDT v3) is not penalized the same way. Run WER twice: punctuation-stripped and punctuation-preserved.
- **ITN divergence:** count utterances where the engine's number/date formatting differs from the reference. This is the `DictationTranscriber` "3:15" risk, quantified.
- **Latency, three numbers, all measured from hotkey release:**
  - cold (first utterance after app launch, model not in memory)
  - warm p50 and p95
  - time-to-first-partial, for progressive presets
  Cold-start is what users actually feel on a dictation app. Whisper large loads slowly; Apple's assets are OS-cached.
- **Disk + peak RAM** per config.
- **Formatter agreement:** run each raw transcript through Dikta's existing formatter stage and diff the final output. The best raw WER is not automatically the best end-to-end result.

### Method

Build a `dikta-bench` CLI target in the repo that takes an engine id + audio dir and emits JSON. Run it from `build-release.sh`-style release builds only (per project convention — no debug builds for testing). Keep the corpus out of git; store paths in a gitignored manifest.

Decision rule stated up front: adopt a new default only if it beats the incumbent on **both** Swedish WER and warm p95 latency, and does not regress English WER by more than 1pp absolute.

---

## Unverified Claims

Everything below is UNVERIFIED and must not be cited as fact.

1. **KB-Whisper English WER.** KBLab publishes Swedish only. English regression is plausible for a Swedish fine-tune but is not quantified in any source found. Configs D and E in the experiment plan exist to settle this.
2. **KB-Whisper small/medium have no maintained WhisperKit CoreML bundle.** `Leonidng/whisperkit-kb-whisper-small` (2026-03-08) has the right folder structure but 0 recorded downloads and no README; `pappa1337/kb-whisper-{small,medium}-coreml` ship encoder-only `.mlmodelc`. None were loaded or tested.
3. **`odens00volym/kb-whisper-coreml` quality and speed claims** (1.7x real time on M1 Max, better Swedish than large-v3-turbo) are the repo author's own, from a single 12.2-minute sample, published 2026-09-14. Not independently reproduced.
4. **Nemotron 3.5 Streaming Multilingual Swedish support.** FluidAudio documents "~40 languages (en, es, de, fr, it, pt, ar, ja, ko, zh-CN, ru, hi, vi, …)". Swedish is not named. `nvidia/nemotron-asr-streaming-multilingual-0.6b` returned no data from the HF API — consistent with FluidAudio's "local-path-only, no HuggingFace repo yet".
5. **Qwen3-ASR Swedish WER.** The tech report confirms `sv` is inside the `Fleurs††` evaluation set but publishes no per-language Swedish number. The report also states "30 languages" in §4.1 while the abstract says 52 — discrepancy unexplained.
6. **Qwen3-ASR on Apple Silicon.** All published efficiency figures (92ms TTFT, RTF 0.064) are vLLM + CUDA. No CoreML conversion or Mac benchmark found. Argmax benchmarked `qwen3-asr-1.7b` on M2 Ultra via the **Pro** (commercial) SDK, not the open SDK.
7. **whisper.cpp ~2x slower than WhisperKit on Apple Silicon** comes from secondary comparison sites (cactuscompute.com, vocai.net), not a primary benchmark. Treat as directional only.
8. **Whisper `small`/`medium` disk sizes (~500MB / ~1.5GB)** in `WhisperModel.swift` are Dikta's own descriptions. Measured from the Hugging Face API against `argmaxinc/whisperkit-coreml`: `openai_whisper-small` = **486.5 MB**, `openai_whisper-medium` = **1529.7 MB**, `openai_whisper-large-v3-v20240930_turbo_632MB` = **645.7 MB** actual (the folder name understates it). Dikta's in-app copy is therefore close for small and medium. Not verified by downloading and measuring on disk.
9. **Apple asset sizes and offline behaviour after install.** The install completed and transcription succeeded, but no air-gapped run was performed and asset size on disk was not measured.
10. **Apple Swedish accuracy on human speech.** The only Swedish test was `say -v Alva` synthetic audio, 21 words, one sample. Not a benchmark. Real WER is unknown.
11. **No macOS 26.x release note was found** stating whether Apple plans to add Swedish to `SpeechTranscriber`. Absence of evidence only.
12. **Voxtral language list** (13, no Swedish) comes from Red Hat Developer and secondary coverage, not Mistral's own model card.
13. **Canary-1B v2 Swedish WER and any Mac/CoreML path.** Neither found. Sizes are from the HF API; usability on Apple Silicon is unassessed.
14. **Parakeet v3 disk footprint** for a shipping app. The HF repo totals 3.59 GB across many precision variants; a real integration downloads a subset. Argmax's compressed Pro variant is `parakeet-v3_494MB`. Actual FluidAudio on-disk cost not measured.

15. **`large-v3-turbo` Swedish WER is not measured anywhere found.** The 7.8 FLEURS figure quoted in the matrix and in the KBLab comparison table is plain **`large-v3`**, not turbo. Turbo cuts the decoder from 32 layers to 4, and decoder capacity is exactly where a lower-resource language like Swedish is most likely to suffer. Recommendation #1 rests on turbo's measured English win plus its smaller footprint; its Swedish behaviour must be measured (config C in the Experiment Plan) before turbo replaces `medium` as the multilingual default.

---

## Sources

Primary, verified this session:

- Local probe, macOS 26.6.2 / Xcode 26.6, `Speech.framework`: `SpeechTranscriber.supportedLocales`, `DictationTranscriber.supportedLocales`, `SFSpeechRecognizer.supportedLocales()`, end-to-end sv-SE and en-US transcription. Interface read from `MacOSX.sdk/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/*.swiftinterface`.
- https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.0.0 (2026-05-01)
- https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.0 (2026-08-06)
- https://github.com/FluidInference/FluidAudio/releases (v0.13.7 → v0.15.7, 2026-04-23 → 2026-09-10)
- https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md
- https://raw.githubusercontent.com/FluidInference/FluidAudio/main/Documentation/ASR/NemotronMultilingual.md
- https://github.com/argmaxinc/OpenBench/blob/main/BENCHMARKS.md
- https://huggingface.co/KBLab/kb-whisper-large
- https://huggingface.co/odens00volym/kb-whisper-coreml (created 2026-09-14)
- https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml
- https://huggingface.co/argmaxinc/whisperkit-coreml
- https://huggingface.co/Qwen/Qwen3-ASR-0.6B
- https://huggingface.co/nvidia/canary-1b-v2
- https://arxiv.org/html/2601.21337v1 — Qwen3-ASR Technical Report, 2026-01-29
- HF model API metadata for sizes, licenses, created/lastModified dates

Secondary, used only where marked:

- https://developers.redhat.com/articles/2026/02/06/run-voxtral-mini-4b-realtime-vllm-red-hat-ai
- https://perspectives.nvidia.com/nemotron-speech/ (Canary 1B v2 / Parakeet TDT v3 / Nemotron 3.5 language coverage)
- https://cactuscompute.com/compare/argmax-vs-whisper-cpp
- https://developer.apple.com/documentation/speech/speechanalyzer (JS-rendered; API facts taken from the SDK interface instead)

Dikta context: `/Users/sebastianstrandberg/work/git/dikta/CLAUDE.md`, `docs/architecture.md`, `dikta-macos/Dikta/Models/WhisperModel.swift`.
