# WhisperKit Drift — 0.9.4 → 1.1.0

Scout: sonnet, 2026-09-15. Read-only recon. Source facts via `gh api repos/argmaxinc/WhisperKit/releases` + repo checkout.

## Versions

Package.swift (`dikta-macos/Package.swift:13`): `.package(url: "https://github.com/argmaxinc/WhisperKit", "0.9.0"..<"0.10.0")`.

**Two conflicting lockfiles. Repo has drift, not one pinned version.**

| Track | File | Resolved |
|---|---|---|
| SPM CLI (`swift build`) | `dikta-macos/Package.resolved` | **0.9.4** — matches `.build/checkouts/WhisperKit` (tag v0.9.4, commit `defefaefe33`, 2024-11-07) |
| Xcode IDE / `xcodebuild` | `Dikta.xcodeproj/.../xcshareddata/swiftpm/Package.resolved` | **0.15.0** (rev `664e1b5a...`), added commit `fb8b220` 2026-03-14, untouched since |

Root cause: `project.pbxproj:715-722` own `XCRemoteSwiftPackageReference` for WhisperKit, `upToNextMajorVersion, minimumVersion 0.9.0` — no `<0.10.0` ceiling. Independent of Package.swift range. Xcode builds silently get newer WhisperKit than `swift build`. Release script (`scripts/build-release.sh:59`) uses `xcodebuild archive` → **shipped v1.2 binary likely ran WhisperKit 0.15.0, dev loop runs 0.9.4.** Likely unintentional. User decision, not silent fix.

Latest: **v1.1.0**, 2026-08-06. Repo renamed `argmaxinc/WhisperKit` → `argmaxinc/argmax-oss-swift` at v1.0.0 (2026-05-01). Old URL resolves via GitHub API redirect (verified API; raw git fetch UNVERIFIED). WhisperKit now one module in monorepo SDK with SpeakerKit (diarization) + TTSKit.

Gap 0.9.4 → 1.1.0: 15 releases, ~21 months.

## Changelog Summary

| Version | Date | Notable |
|---|---|---|
| v0.10.0 | 2024-12-20 | **Breaking**: `WhisperKit.sampleRate` → `Constants.defaultWindowSamples`; protocol-based encoder/decoder I/O types |
| v0.10.1/.2 | 2024-12-21 / 2025-01-16 | Pre-macOS 15 build fix, Xcode 15 support |
| v0.11.0 | 2025-02-22 | swift-transformers version flexibility; word-timestamp fixes |
| v0.12.0 | 2025-04-15 | Multi-channel audio merging default (was channel 0 only); `recommendedModels()` device table refresh |
| v0.13.0 | 2025-06-13 | Async VAD, `SegmentDiscoveryCallback`; deprecates free functions → utility classes (warnings only) |
| v0.13.1 | 2025-07-31 | Tokenizer / logit-filter fixes |
| v0.14.0 | 2025-09-20 | OpenAI-compatible local HTTP server (`whisperkit-cli serve`) |
| v0.14.1 | 2025-10-17 | Swift 6 prep, `Sendable` conformance |
| v0.15.0 | 2025-11-07 | **Semantic break**: `TranscriptionResult` struct → open class (reference semantics) |
| v0.16.0 | 2026-03-03 | TTSKit added (Qwen3-TTS on-device) |
| v0.17.0 | 2026-03-13 | SpeakerKit added (Pyannote diarization, RTTM export) |
| v0.18.0 | 2026-04-01 | SpeakerKit API around new `ModelManager` base class |
| v1.0.0 | 2026-05-01 | **Breaking**: repo/package renamed `argmax-oss-swift`; all deprecated APIs removed; Swift 6 concurrency; `TranscriptionCallback` stored vars need `?`; `supressTokens`→`suppressTokens` |
| v1.1.0 | 2026-08-06 | `.incremental` audio loading (70%+ peak-memory cut, long files); `AudioInputConfig`→`AudioInputOptions` deprecation |

Min OS unchanged: `.macOS(.v13)`. Dikta targets macOS 14 (`Package.swift:7`, `MACOSX_DEPLOYMENT_TARGET=14.0`) — fine. argmax-oss-swift `swift-tools-version 5.10` vs Dikta `5.9` — no block on Xcode 26.6. TTSKit macOS 15 requirement irrelevant (unused).

## API Drift Table

Verified Dikta call sites against `Sources/WhisperKit/Core/WhisperKit.swift` + `Configurations.swift` at tag `v1.1.0`.

| Dikta call site | Exists at v1.1.0? | Changed? | Migration note |
|---|---|---|---|
| `Transcriber.swift:28-34` `WhisperKit(modelFolder:verbose:prewarm:load:download:)` | Yes | No | Convenience init identical (`WhisperKit.swift:102-121`) |
| `Transcriber.swift:39-45` `WhisperKit(model:verbose:prewarm:load:download:)` | Yes | No | `model:` param unchanged |
| `Transcriber.swift:89` `whisperKit.transcribe(audioArray:decodeOptions:)` | Yes | No | Signature `transcribe(audioArray:decodeOptions:callback:segmentCallback:) -> [TranscriptionResult]` (`WhisperKit.swift:987-1000`). Dikta already `.flatMap`s array (line 92) |
| `Transcriber.swift:79-85` `DecodingOptions(language:temperatureFallbackCount:compressionRatioThreshold:logProbThreshold:noSpeechThreshold:)` | Yes | No | All 5 fields present. `supressTokens`→`suppressTokens` fix doesn't touch Dikta fields |
| `Transcriber.swift:92-121` `results.flatMap { $0.segments }`, `.noSpeechProb`, `.avgLogprob`, `.text` | Yes | Note | `TranscriptionResult` struct → open class at v0.15.0. Dikta only reads, never copies/mutates → unaffected |

**Zero breaking changes hit Dikta's usage across 0.9.4→1.1.0.** Breaking releases (v0.10.0, v1.0.0) hit custom protocol implementers + free-function callers. Dikta uses neither.

## Model Catalogue

`argmaxinc/whisperkit-coreml`, checked 2026-09-15. 27 top-level variants. Size/speed-relevant:

- `openai_whisper-large-v3-v20240930_turbo` / `_632MB` — newest large-v3 turbo, 632MB quantized
- `openai_whisper-large-v3_turbo` / `_954MB`
- `openai_whisper-large-v2_turbo` / `_955MB`
- `distil-whisper_distil-large-v3` / `_594MB`, `distil-whisper_distil-large-v3_turbo` / `_600MB`
- Standard tiny/base/small/medium/large-v2/large-v3, some `.en` + quantized-MB variants

Per-variant layout (HF tree API, `openai_whisper-small/`): `AudioEncoder.mlmodelc/`, `MelSpectrogram.mlmodelc/`, `TextDecoder.mlmodelc/`, `config.json`, `generation_config.json`.

**Non-Argmax HF repos loadable.** `recommendedRemoteModels(from repo:)`, `fetchModelSupportConfig(from repo:)`, convenience init `modelRepo:` default `"argmaxinc/whisperkit-coreml"` — accept any HF repo id (`WhisperKit.swift:168-193`). Needs same folder layout.

Swedish: KBLab `kb-whisper-{tiny,base,small,medium,large}` (Riksdag/radio fine-tune). **No official CoreML.** Only ct2/ONNX/GGML/MLX. Community CoreML in WhisperKit layout, all UNVERIFIED quality/currency, none downloaded/tested:
`Leonidng/whisperkit-kb-whisper-small` (folder `KBLab_kb-whisper-small`, matches convention), `mickekringai/kb-whisper-coreml`, `neowelt/kb-whisper-coreml`, `jegeblad/kb-whisper-large-coreml`, `pappa1337/kb-whisper-{small,medium}-coreml`, `psvensk/KB_whisper_coreML`, `chrslrssn/kb-whisper-coreml`, `odens00volym/kb-whisper-coreml`.

## Upgrade Plan — Effort: S

1. Resolve lockfile drift first (Package.swift vs pbxproj). Pick one source of truth. Currently disagree by 6 minor versions.
2. `Package.swift:13` → `.package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.1.0")` (canonical post-rename URL, per v1.0.0 upgrade guide).
3. Same repo/version in `project.pbxproj` `XCRemoteSwiftPackageReference`. Replace stale 0.9.0-floor ref.
4. No code changes in `Transcriber.swift` / `WhisperModel.swift`. All 5 call sites verified unchanged.
5. Rebuild. Run one transcription to confirm model download/load (default repo unchanged).
6. Separate decision: swap `modelName` to turbo/distil variant, or trial community kb-whisper CoreML. Size/quality call, not part of bump.

Small because zero code migration. Pure dependency-pin hygiene.

## Unverified

- Old `argmaxinc/WhisperKit` URL rename-redirect works end-to-end for `swift package resolve` / `git fetch`. Only checked via `gh api`.
- Quality of any community kb-whisper CoreML repo. Not downloaded, not run.
- ~~`TranscriptionResult` outside `Transcriber.swift`~~ — orchestrator grep 2026-09-15: 0 other uses. Closed.

## Sources

- https://github.com/argmaxinc/WhisperKit/releases (via `gh api`, redirects to argmax-oss-swift)
- https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.0 … v0.10.0 (bodies fetched 2026-09-15)
- https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.0/Sources/WhisperKit/Core/WhisperKit.swift
- https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.0/Sources/WhisperKit/Core/Configurations.swift
- https://github.com/argmaxinc/argmax-oss-swift/blob/main/Package.swift
- https://huggingface.co/api/models/argmaxinc/whisperkit-coreml (tree, 2026-09-15)
- https://huggingface.co/api/models?search=kb-whisper (2026-09-15)
- jCodeMunch `local/dikta-8587f83b` (indexed 2026-09-15); local repo Package.swift, both Package.resolved, project.pbxproj, git log
