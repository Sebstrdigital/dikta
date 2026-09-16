# dikta-macos — Code Review (2026-09-15)

Scope: `dikta-macos` only. Read-only. No build run (separate worker).
Repo: `/Users/sebastianstrandberg/work/git/dikta`, branch `main`, last mac commit `8696fbc` (2026-05-02).
Toolchain on box: Xcode 26.6 (17F113), Swift 6.3.3, target arm64-apple-macosx26.0.
Deps: WhisperKit pinned `0.9.0..<0.10.0`, resolved **0.9.4** (`Package.resolved`). Sparkle 2.9.0, swift-transformers 0.1.8.

`grep -rn "TODO\|FIXME" dikta-macos/Dikta` → **0 hits**. Also 0 hits for `HACK`/`XXX`.

---

## Pipeline Map

Chain: config string → `Transcriber` → WhisperKit init → `loadModels()` → `transcribe(audioArray:decodeOptions:)` → segment filter → regex clean → paste.

**1. Model chosen (string, not enum)**
- Stored as `String`, not `WhisperModel`: `AppConfig.swift:9` `var whisperModel: String`, JSON key `whisper_model` (`AppConfig.swift:57`).
- Default `"small"` (`AppConfig.swift:80`).
- Decode migrates legacy ids: `base`/`base.en` → `small` (`AppConfig.swift:121-127`).
- Enum exists but only for UI: `WhisperModel.swift:4-21`, cases `.small` (:5), `.medium` (:6). Re-hydrated at render time `MenuBarView.swift:176-178` (`WhisperModel(rawValue:) ?? .small`).
- User picks from menu `MenuBarView.swift:200-213` → `MenuBarViewModel.setWhisperModel` (`:370-377`) → writes `ConfigService.whisperModel` (`ConfigService.swift:118-124`) → `save()`.

**2. Transcriber constructed — once**
- `MenuBarViewModel.swift:58`: `Transcriber(modelName: configService.whisperModel)`. Init-only. No reload path.
- `Transcriber.swift:12` `private let modelName: String` — immutable after init (`:14-16`, default `"small"`).

**3. Load — bundled first, else download**
- `MenuBarViewModel.initialize()` → `await transcriber.loadModel()` (`:105`); gates `appState`/hotkeys on `transcriber.isReady` (`:107-121`).
- `Transcriber.loadModel()` `:19-56`, re-entrancy guard `:20`.
- Bundled branch `:26-36`: `WhisperKit(modelFolder:verbose:false, prewarm:false, load:false, download:false)` then `wk.loadModels()`.
- Download branch `:39-47`: `WhisperKit(model: modelName, ... download: true)` then `wk.loadModels()`.
- Bundled path resolution `:59-63`: `Bundle.main.resourcePath + "/WhisperModels/openai_whisper-\(modelName)"`, `fileExists` check.
- Ship script bundles **small only**: `scripts/build-release.sh:93` `WHISPER_MODEL_NAME="openai_whisper-small"`, copied `:106-109`. Source dir `~/work/artifacts/huggingface/models/argmaxinc/whisperkit-coreml`.
- Failure path `:50-53` sets `errorMessage`, `isReady` stays false → single notification `MenuBarViewModel.swift:120`, app stuck in `.loading`.

**4. Cache**
- No app-managed cache. Download branch delegates entirely to WhisperKit default (HF repo `argmaxinc/whisperkit-coreml`, WhisperKit's own download dir). `AppPaths.swift` has **no** whisper entry; `modelsDir`/`llmModelPath` (`:14`,`:17`) point at a Gemma GGUF and are dead.

**5. Transcribe call**
- `MenuBarViewModel.processAudio` `:187-261`. Race between transcribe task and 60s sleep task (`:185`, `:208-218`), `group.next()!` at `:217`.
- `Transcriber.transcribe(_:language:micSensitivity:)` `:70-130`. Guards `:71-77`.
- Audio contract: 16 kHz mono Float32, converted in `AudioRecorder.swift:97-111` (`sampleRate = 16000` at `:30`).

**WhisperKit APIs / options actually used**

| Surface | Value | Cite |
|---|---|---|
| Init (bundled) | `modelFolder:`, `verbose:false`, `prewarm:false`, `load:false`, `download:false` | Transcriber.swift:28-34 |
| Init (remote) | `model: modelName`, `download:true` | :39-45 |
| Load | `wk.loadModels()` | :35, :46 |
| Transcribe | `transcribe(audioArray:decodeOptions:)` | :89 |
| `DecodingOptions.language` | forced from config, never nil in practice | :80, MenuBarViewModel.swift:210 |
| `temperatureFallbackCount` | 3 | :81 |
| `compressionRatioThreshold` | 3.0 | :82 |
| `logProbThreshold` | -1.5 normal / -2.0 headset | :83, MicSensitivity.swift:43-47 |
| `noSpeechThreshold` | 0.3 normal / 0.15 headset | :84, MicSensitivity.swift:25-29 |
| Segment fields read | `text`, `avgLogprob`, `compressionRatio`, `noSpeechProb` | :96-111 |

**Not used / not set:** `ModelComputeOptions` (compute units left at WhisperKit default — no ANE/GPU pinning), `chunkingStrategy` (no VAD chunking), `task` (defaults `.transcribe`), `usePrefillPrompt`, `promptTokens`/`prefixTokens`, `wordTimestamps`, `detectLanguage`, `concurrentWorkerCount`, `modelRepo`, progress/callback hooks, `withoutTimestamps`, `clipTimestamps`.

**6. Post-processing (app-side, not WhisperKit)**
- Flatten `results.flatMap { $0.segments }` `:92`.
- Per-segment `.info` log loop `:95-100`.
- Drop empty segments `:103`.
- Diagnostic line `:108-111`.
- Regex strip control tokens `<|...|>` and bracket noise `[BLANK_AUDIO]|[silence]|[no speech]` `:113-121`.
- Empty → `TranscriberError.noSpeechDetected` `:125-127`.
- Second, redundant silence check in caller `:226-239` (string list overlaps the regex already applied).

---

## Coupling & Extension Points

**No abstraction. WhisperKit is concrete.** No protocol, no `TranscriptionEngine`, no DI. `import WhisperKit` appears in exactly one file (`Transcriber.swift:2`) — that part is good containment — but `Transcriber` itself is a concrete type injected nowhere.

WhisperKit symbol leak is narrow: `WhisperKit` type (`:11`,`:28`,`:39`), `DecodingOptions` (`:79`), segment shape (`:96-111`). All inside `Transcriber.swift`.

**Call sites that change to add a second backend (e.g. KBLab `kb-whisper`, or non-Whisper):**

| # | File:line | What changes |
|---|---|---|
| 1 | `Transcriber.swift:1-131` | Whole type. Split into `protocol TranscriptionEngine { func load() async throws; func transcribe(_:language:sensitivity:) async throws -> String }` + `WhisperKitEngine`. |
| 2 | `Transcriber.swift:59-63` | Bundled-path scheme hardcodes `openai_whisper-` prefix. Must become per-engine. |
| 3 | `Transcriber.swift:39-45` | `model:` string handed to WhisperKit's default HF repo. A KBLab repo needs `modelRepo:`/`modelFolder:` — no plumbing exists. |
| 4 | `WhisperModel.swift:4-21` | Two-case enum with no repo/variant/backend metadata. Needs `repo`, `variant`, `engine`, `sizeBytes`. |
| 5 | `AppConfig.swift:9,57,80,121-127` | `whisperModel: String` is a bare id with no namespace. Needs engine-qualified id + a migration for existing configs. |
| 6 | `MenuBarView.swift:176-178,200-213` | `WhisperModel(rawValue:) ?? .small` and `allCases` picker — flat list, no grouping by family. |
| 7 | `MenuBarViewModel.swift:58` | Construction site; would take a factory. |
| 8 | `MenuBarViewModel.swift:370-377` | Switch handler; today only writes config + says "restart". |
| 9 | `MenuBarViewModel.swift:105-121` | Load/ready gating assumes one engine, one load. |
| 10 | `MenuBarViewModel.swift:210` | Passes `language.whisperCode` — Whisper-specific code space. |
| 11 | `MicSensitivity.swift:25-47` | `noSpeechThreshold`/`logProbThreshold` are Whisper decoder concepts, not portable. |
| 12 | `scripts/build-release.sh:92-109` | Bundles one hardcoded model dir. |

Verdict: **small blast radius (12 sites, ~1 file of real logic), but zero seams today.** Adding kb-whisper specifically is cheap-ish — it is still WhisperKit-compatible CoreML, so items 3, 4, 5 carry the weight. A non-Whisper backend needs the protocol first.

---

## Language Handling

- 12 languages: `Language.swift:5-16`. Raw values are ISO codes and double as Whisper codes: `whisperCode { rawValue }` `:41-43`.
- Swedish `= "sv"` `:6`. English `= "en"` `:5`. No special-casing of either in the transcription path.
- **Always forced, never auto-detected.** `MenuBarViewModel.swift:210` passes `language.whisperCode` unconditionally from `configService.language` (`:200`). `DecodingOptions.language` `Transcriber.swift:80`. `detectLanguage` is never set; the `language ?? "auto"` fallback at `Transcriber.swift:87` is unreachable from the app (only reachable via the `nil` default at `:70`).
- Selection is manual: carousel hotkey → `MenuBarViewModel.swift:329` `configService.language.next(in: enabled)`; per-language toggle `:337-359`.
- Default enabled set hardcoded `[.english, .swedish, .indonesian]` in three places: `AppConfig.swift:87`, `:95` (memberwise default), `:143` (decode fallback).
- Swedish-specific hardcoding, one spot: `Language.supportsEmbeddings` `:50-57` returns false for `.swedish` (plus `.indonesian`, `.finnish`, `.norwegian`, `.danish`) — gates formatter paragraph splitting, not transcription. Documented rationale at `:45-49` (MiniLM-L12-v2 coverage).
- Menu bar label shows `language.menuBarCode` (uppercased raw) `DiktaApp.swift:77`, `Language.swift:36-38`.
- Doc drift: `docs/architecture.md` Key Files says "Language.swift — Supported languages: English, Swedish, Indonesian". Actual = 12.

---

## Tech Debt

| Sev | file:line | Issue | Fix |
|---|---|---|---|
| HIGH | `MenuBarViewModel.swift:58` + `:370-377` | Model switch requires app restart. `Transcriber` built once with `modelName` as `let`; handler only writes config and notifies "Restart app to load new model." | Add `Transcriber.reload(modelName:)` — release `whisperKit`, reset `isReady`, reload; call from `setWhisperModel`. |
| HIGH | `Transcriber.swift:39-45`, `:59-63`, `build-release.sh:93` | `medium` is never bundled. Picking it → silent multi-GB HF download on next launch, no progress UI, no disk/network pre-check. App sits in `.loading` with one notification (`MenuBarViewModel.swift:120`) and no retry. | Progress reporting + explicit pre-flight (reachability, free space) + retry affordance. |
| HIGH | `ClipboardManager.swift:20-43`,`:46-50` ← `MenuBarViewModel.swift:268` | `pasteText` types char-by-char with `usleep(1000)` per char, called on MainActor. ~500-char dictation ≈ 0.5 s main-thread stall. Name lies: "paste" actually synthesizes keystrokes (`:47`). | Move synthesis off MainActor, or restore real pasteboard + single Cmd+V. |
| MED | `Transcriber.swift:5`,`:11`,`:89`,`:95-121`; `project.pbxproj:619,648,662,677` | `@MainActor` class owns non-Sendable `WhisperKit?`; segment log loop and regex clean run on MainActor. `SWIFT_VERSION = 5.0` while toolchain is Swift 6.3.3 — Swift 6 mode never attempted, so concurrency debt is unmeasured. | Move `Transcriber` to its own `actor`, keep only `@Published` mirrors on MainActor; then trial `SWIFT_STRICT_CONCURRENCY=complete`. |
| MED | `Transcriber.swift:39-45` vs `:61` | Two model-naming schemes: download passes bare `"small"` to WhisperKit's fuzzy variant match against its default repo; bundled path builds `openai_whisper-small`. No `modelRepo` pin, no exact-variant pin. A WhisperKit repo listing change silently shifts which weights load. | Single source of truth on `WhisperModel` (repo + exact variant); pass explicitly on both branches. |
| MED | `Transcriber.swift:79-85`, `:31`, `:42` | `DecodingOptions` omits `chunkingStrategy` (no VAD), `task`, `usePrefillPrompt`, `wordTimestamps`. No `ModelComputeOptions` → compute units at library default. `prewarm: false` → first transcription pays CoreML compile. | Set `chunkingStrategy: .vad` for long-form; pin compute units; prewarm on idle after load. |
| MED | `DiktaTests/DiktaTests.swift:5`, `:95-190` | Test file **re-declares** `AppConfig`/`HotkeyConfigs` as hand-copies because the exec target is not `@testable`-importable via SPM. Copy at `:110-138` is missing `formatSelection`, which production has (`AppConfig.swift:24`). Double has drifted; tests green while prod differs. | Extract models into a `DiktaCore` library target; delete the copies. |
| MED | `DiktaTests/` (all 4 files) | Zero coverage of `Transcriber`, WhisperKit init, `DecodingOptions`, segment filter, token-strip regex. | See Tests section. |
| MED | `MicMutingTests.swift:2` vs `DiktaTests.swift:5` | Inconsistent strategy: one file uses `@testable import Dikta`, the rest use copies. Only one can be right per build system. | Pick one after the library-target split. |
| LOW | `AppConfig.swift:128` | `llmModel` uses `decode`, not `decodeIfPresent`. A config missing `llm_model` throws → `ConfigService.swift:20` swallows to `?? .default`, silently wiping hotkeys + history. | `decodeIfPresent(...) ?? "gemma3"`. Same audit for `hotkeys`/`outputMode`/`history` (`:118-120`). |
| LOW | `AppPaths.swift:14`,`:17` | `modelsDir` + `llmModelPath` (Gemma GGUF) dead — zero references outside the file. Leftover from removed LLM cleanup pass (`OutputMode.swift:7`). | Delete. |
| LOW | `AppConfig.swift:10`,`:12`,`:81`,`:83`,`:130`; `ConfigService.swift:128-135` | `llmModel` + `customPrompt` persisted and exposed, never consumed. `defaultCustomPrompt` (`AppConfig.swift:68`) is dead prompt text. | Keep coding keys for back-compat decode; drop the accessors and default. |
| LOW | `Language.swift:60-64` | Computed `var next` is dead — every caller uses `next(in:)` (`MenuBarViewModel.swift:329`, tests). Contains `firstIndex(of: self)!`. | Delete. |
| LOW | `AppPaths.swift:7`,`:35`; `ConfigService.swift:15` | `.first!` on `urls(for:.applicationSupportDirectory)`. Launch-time crash if ever empty; `AppPaths.appSupport` is a `static let` so it traps inside lazy init. | `guard ... else { fatalError("...") }` with a diagnosable message, or `NSHomeDirectory()` fallback. |
| LOW | `Transcriber.swift:87`,`:93-100`,`:110`,`:123` | Transcribed user speech logged per-segment at `.info` to the unified log. `grep -rn "privacy:" Dikta` → **0 hits**, so no interpolation is explicitly annotated. | Mark text interpolations `privacy: .private`; drop the per-segment loop to `.debug`. |
| INFO | `Transcriber.swift:113-121` vs `MenuBarViewModel.swift:226-239` | Silence detection done twice, with two different vocabularies (regex vs literal list). Second pass can only fire on strings the first didn't strip. | Collapse to one place. |
| INFO | `CLAUDE.md` jCodeMunch block | `indexed_commit: c3185a3 / 2026-03-07` is stale; mac HEAD is `8696fbc` (2026-05-02). Index itself was rebuilt 2026-09-15. | Refresh the block. |

**Deprecated APIs under Xcode 26:** none found. Sweep for `NSUserNotification`, `openURL(`, `NSUnarchiver`, `@available`, `Deprecated` → 0 hits. App uses `UNUserNotificationCenter`, `MenuBarExtra`, `SMAppService`, `AVAudioEngine` — all current. The `as! AXUIElement` casts at `TextSelectionService.swift:24`,`:32` **are** guarded by `CFGetTypeID` checks at `:23`,`:31` — not a crash risk, correctly done.

---

## Tests

**Present** (4 files, 2193 lines):

| File | Covers |
|---|---|
| `FormatterTests.swift` (1053) | Formatter engine: body splitting, list detection, greeting/sign-off, edge cases, combined scenarios |
| `DiktaTests.swift` (683) | Hotkey modifier matching (9), `AppConfig` decode/migration (5), `UpdateChecker` version compare (11), `Language` metadata (26), language carousel (9), `enabledLanguages` decode (5) |
| `EmbeddingParagraphSplitterTests.swift` (324) | Embedding-based paragraph splitting |
| `MicMutingTests.swift` (133) | Muter registry |

`AppConfig` model-migration coverage is genuinely good: `test_decode_migratesBaseWhisperModel` (`:319`), `test_decode_migratesBaseEnWhisperModel` (`:331`), default `"small"` assertion (`:290`).

**Missing — the entire transcription/model layer:**
- No test names `Transcriber`, `TranscriberError`, `WhisperKit`, or `DecodingOptions` anywhere in `DiktaTests/`.
- Token-strip regex (`Transcriber.swift:118-119`) untested — this is precisely the no-speech bug surface the diagnostic logging was added for.
- Empty-segment filter (`:103`) untested.
- `TranscriberError` cases (`:133-148`) untested; `emptyAudio` / `modelNotLoaded` guards (`:71-77`) untested.
- `getBundledModelPath` naming scheme (`:61`) untested — silent breakage if the bundle layout changes in `build-release.sh`.
- 60 s timeout race (`MenuBarViewModel.swift:208-218`) untested.
- `MicSensitivity` threshold mapping (`MicSensitivity.swift:25-47`) untested.
- No `AudioRecorder` tests (converter, route-change recreation at `:141-158`).

Root blocker: the exec-target/SPM limitation documented at `DiktaTests/DiktaTests.swift:5`. It forces copy-paste doubles, which is why nothing with a real dependency gets tested.

---

## Top 5 Recommendations

1. **Extract `DiktaCore` library target; delete test doubles.** (high value / medium effort) Unblocks `@testable import` for the whole codebase, kills the drifted `AppConfig` copy at `DiktaTests.swift:95-190`, and is a prerequisite for 2 and 4.
2. **Make model switching live.** (high / low) Add `Transcriber.reload(modelName:)` and call it from `MenuBarViewModel.swift:370-377`. Removes the "Restart app" notification — the most visible UX wart in the model pipeline.
3. **Introduce `TranscriptionEngine` protocol + engine-qualified model ids.** (high / medium) Put `repo` + `variant` on `WhisperModel.swift:4-21` and plumb `modelRepo` into `Transcriber.swift:39-45`. This is the whole cost of adding KBLab `kb-whisper`, and it retires the two-naming-scheme bug (`:39` vs `:61`).
4. **Unit-test the post-processing path.** (high / low) Lift `:103` and `:113-121` into a pure `static func cleanSegments([TranscriptionSegment]) -> String`, test the token regex and empty-filter directly. Cheapest real coverage win available.
5. **Fix download UX for `medium` + un-block the paste path.** (medium / low) Progress + disk/network pre-check around `Transcriber.swift:39-45`; move `ClipboardManager.swift:20-43` keystroke synthesis off MainActor. Two independent user-visible stalls.

---

## Open Questions

1. `medium` is selectable but never shipped (`build-release.sh:93`). Intentional (download-on-demand tier) or an oversight? Changes whether rec 5 is a fix or a feature.
2. WhisperKit 0.9.4 is pinned `<0.10.0` and the repo sat idle 4 months. Is a 0.10+/1.x bump in scope, and does it change `DecodingOptions`/`chunkingStrategy` surface?
3. KBLab `kb-whisper` — CoreML-converted and WhisperKit-loadable, or would it need a second runtime? Determines whether rec 3 is sufficient.
4. `llmModel`/`customPrompt`/`llmModelPath` — is a local LLM cleanup pass coming back, or is this safe to delete? `OutputMode.swift:7` reads as a permanent decision.
5. Is the unified-log dictation content (`Transcriber.swift:93-100`) acceptable, or does it need `privacy: .private` before any wider distribution?
6. Swift 6 language mode: target for this cycle, or deliberately deferred?

## Out-of-Scope Findings

- `TextToSpeechService.swift:116`,`:132` `process.waitUntilExit()` and `:143` `usleep(500_000)` — blocking calls; isolation not audited (TTS, outside brief).
- `TextSelectionService.swift:55` `usleep(100000)` in the clipboard fallback path.
- `docs/architecture.md` understates `Language` (3 vs 12) and does not mention `MicSensitivity`, the formatter subsystem, or `MicMuting/`.
- `dikta-macos/build/Dikta.xcarchive/` is checked into the working tree — ~large binary artifacts in the repo path.
- `MenuBarViewModel.swift` at 662 lines is the largest non-test file; state machine, hotkey delegation, language carousel, TTS, and model config all live there.
- `MenuBarViewModel.swift:21` `static var isModelLoaded` — mutable global paired with a NotificationCenter post (`:112`); Swift 6 will flag it.

---

## jCodeMunch queries used (re-runnable)

```
resolve_repo(path="/Users/sebastianstrandberg/work/git/dikta/dikta-macos")
  → local/dikta-8587f83b (84 files, 2126 symbols, indexed 2026-09-15)

get_file_outline(repo="local/dikta-8587f83b", file_paths=[
  "dikta-macos/Dikta/Services/Transcriber.swift",
  "dikta-macos/Dikta/Models/WhisperModel.swift",
  "dikta-macos/Dikta/Models/Language.swift",
  "dikta-macos/Dikta/Models/AppPaths.swift",
  "dikta-macos/Dikta/Models/AppConfig.swift"])
```

Suggested follow-ups for the parent:
```
get_ranked_context(repo="local/dikta-8587f83b",
  query="Transcriber WhisperKit loadModel DecodingOptions transcribe", token_budget=4000)
get_ranked_context(repo="local/dikta-8587f83b",
  query="MenuBarViewModel processAudio transcription timeout appState", token_budget=4000)
find_references(repo="local/dikta-8587f83b", name="Transcriber")
```

Verification commands used (context-mode `ctx_execute`):
```
grep -rn "TODO\|FIXME" dikta-macos/Dikta            # 0
grep -rn "WhisperKit\|whisperKit" Dikta DiktaTests scripts
grep -rn "try!\|as! \|\.first!\|\.last!" Dikta --include='*.swift'
grep -rn "privacy:" Dikta --include='*.swift'       # 0
grep -n "SWIFT_VERSION\|SWIFT_STRICT_CONCURRENCY" Dikta.xcodeproj/project.pbxproj
```
