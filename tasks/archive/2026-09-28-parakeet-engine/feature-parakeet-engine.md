# Feature: Parakeet Engine Switch (macOS v1.5)

Branch: `feat/parakeet-engine` (off `main` 4746cd7). Written 2026-09-28.

## 1. Overview

Dikta macOS transcribes only via WhisperKit (Whisper small / large-v3-turbo / KB-Whisper for Swedish). NVIDIA
Parakeet TDT 0.6B v3 and its 178 MB ternary variant "Parakeet Redux" (moondream, 2026-09-21) claim far faster
CPU/ANE inference at comparable English WER. FluidAudio (Swift, Apache 2.0, CoreML) ships all three Parakeet
builds — `.redux`, `.v3`, `.ultra` — as of v0.17.3 (2026-09-24), so no Python runtime is needed.

This feature adds Parakeet as a second `TranscriptionEngine` behind a user-visible Engine setting, so Sebastian
can compare engines in daily dictation without losing Whisper. Benchmarks land first so the recommendation in the
menu is evidence-based, not marketing.

Prior art: PR #16 removed an Apple Dictation engine and with it `TranscriptionEngineKind`,
`TranscriptionEngineFactory`, the Engine menu and `AppConfig.engine`. Same shape, new backend.

## 2. Goals

- Parakeet Redux, v3 and Ultra measured on the existing FLEURS sv+en bench next to turbo and KB-Whisper small.
- User can switch engine (Whisper / Parakeet Redux / Parakeet v3 / Parakeet Ultra) from the menu bar, live, no restart.
- Dictation and Call Debrief both work on the chosen engine.
- Swedish keeps KB-Whisper auto-select when engine is Whisper; explicit Parakeet choice is honoured for every language.
- Whisper stays the default. Existing configs decode unchanged.
- Deployment target moves to macOS 15 (Redux needs iOS 18 / macOS 15 CoreML ops).

## 3. User Stories

### US-001: Benchmark Parakeet variants on FLEURS sv+en
**Description:** As the maintainer, I want DiktaBench to run Parakeet Redux / v3 / Ultra on the same 20+20 FLEURS
clips as Whisper, so the engine menu's "Recommended" label and the Swedish rule rest on measured WER and speed.

**Acceptance Criteria:**
- [ ] `./run.sh parakeet redux` (also `parakeet v3`, `parakeet ultra`) transcribes both languages and scores them into
      the normal `bench/results/` report, labelled `parakeet-redux` / `parakeet-v3` / `parakeet-ultra`.
- [ ] Bench output records model load seconds and per-clip wall time like the Whisper path, with the compute-unit
      choice printed in the header line.
- [ ] A results table (WER sv / WER en / RTF / load time) for redux, v3, ultra, turbo and KB-Whisper small is written to
      `docs/review-2026-09/parakeet-bench.md`, with the run timestamps of the JSON summaries it came from.

### US-002: Parakeet transcription engine
**Description:** As a user, I want Dikta to transcribe with Parakeet so that dictation returns faster and the model
download is small.

**Acceptance Criteria:**
- [ ] With Parakeet selected and a model loaded, a dictation hotkey press → speak → release pastes the Parakeet transcript
      (punctuated and cased as the model emits it), and `TranscriberPostProcessingTests`-style cleanup still applies.
- [ ] Call Debrief with Parakeet selected produces timestamped segments per chunk (Me/Them merge works); the previous
      chunk's prompt text is accepted and ignored without error.
- [ ] Model download reports progress (0…1) and honours the free-disk-space guard; a failed load sets
      `errorMessage` and leaves `isReady == false`.
- [ ] Redux loads with `encoderComputeUnits: .cpuAndGPU` so first load is seconds, not the ~7-minute ANE compile.

### US-003: Engine setting and live switching
**Description:** As a user, I want an Engine submenu so that I can switch between Whisper and Parakeet variants and see
which one is active.

**Acceptance Criteria:**
- [ ] The menu bar shows `Engine: <name>` with rows Whisper, Parakeet Redux, Parakeet v3, Parakeet Ultra; the active
      row is checked and the "Whisper Model" submenu is only enabled when Whisper is the engine.
- [ ] Choosing a row reloads live with a loading indicator; on failure the app falls back to the previous engine and
      shows the error, and the persisted choice is unchanged.
- [ ] The choice persists in `config.json` (`engine` key) across restarts; configs without the key decode as Whisper.
- [ ] Verify by hand in the built app: switch Whisper → Redux → Whisper while dictating in English and Swedish.

### US-004: Swedish rule and engine-aware model selection
**Description:** As a Swedish/English user, I want KB-Whisper to keep winning for Swedish under Whisper, but my
explicit Parakeet choice to apply to every language, so that switching languages never silently changes engine.

**Acceptance Criteria:**
- [ ] Engine = Whisper: language Svenska → KB-Whisper small loads; other languages → the preferred Whisper model
      (existing `effectiveModel(for:)` behaviour, tests untouched).
- [ ] Engine = Parakeet *: language toggles (hotkey or menu) do not reload or change the engine; the Parakeet model
      is used for all 12 languages and the language hint is not sent (Parakeet auto-detects).
- [ ] Switching engine to Whisper while Svenska is active loads KB-Whisper, not the raw preference.

### US-005: Build, docs and release readiness
**Description:** As the maintainer, I want the release pipeline to still produce a signed, notarized DMG with the new
dependency, so that v1.5 can ship through Sparkle.

**Acceptance Criteria:**
- [ ] `MACOSX_DEPLOYMENT_TARGET` is 15.0 in pbxproj and `Package.swift`; `build-release.sh --no-publish` produces a
      notarized DMG that passes `spctl --assess` and whose bundle carries the FluidAudio binary xcframework signed.
- [ ] `docs/architecture.md` documents the engine seam (kinds, factory, config key, download location) and
      `docs/validation.md` lists the new test classes and the bench command.
- [ ] Full DiktaTests target green (baseline 647 + new), no `Downloading model:` lines in the test log.

## 4. Functional Requirements

- FR-1: `TranscriptionEngineKind` enum (`whisper`, `parakeetRedux`, `parakeetV3`, `parakeetUltra`), `Codable` with stable
  raw values; `AppConfig.engine` defaults to `.whisper` and decodes when absent.
- FR-2: `ParakeetEngine: TranscriptionEngine` wraps FluidAudio `AsrManager` / `AsrModels.downloadAndLoad(version:)`.
  `reload(model:)` on a Parakeet engine is a no-op that keeps `isReady` (Whisper model choice is irrelevant to it).
- FR-3: `MenuBarViewModel` owns `any TranscriptionEngine` selected by an engine factory keyed on kind; switching kind
  unloads the old engine and loads the new one with the same fallback ladder as `setWhisperModel` (previous → error).
- FR-4: `transcribeSegments` on Parakeet returns `[TranscriptSegment]` from FluidAudio segment/word timestamps,
  monotonic, in seconds relative to chunk start.
- FR-5: Parakeet models download to Application Support (FluidAudio default) on first use; sizes ~220 MB (redux),
  ~480 MB (v3/ultra); disk guard uses 2× size like Whisper.
- FR-6: Bench: `DiktaBench --engine parakeet --model-version redux|v3|ultra --language sv|en --audio-dir --out`;
  `run.sh` accepts the pair `parakeet <version>`.
- FR-7: Tests use `FakeTranscriptionEngine`; no test builds a real FluidAudio model (same XCTest-host guard as today).

## 5. Non-Goals

- Windows port changes.
- Python / Photon runtime, ONNX, or the C port.
- Changing the default engine or removing any Whisper model.
- Streaming / live partial results (FluidAudio `SlidingWindowAsrManager`).
- Parakeet diarization, VAD, EOU, or TTS features.
- Bundling Parakeet weights in the DMG.
- Keeping macOS 14 support.

## 6. Design Considerations

- Menu: add `Menu("Engine: …")` beside the existing "Whisper Model" submenu in `MenuBarView.swift`; mark the
  bench-winning variant "(Recommended)" once US-001 numbers exist.
- Reuse the model-switch UX from v1.3 (progress %, disk guard alert, fallback toast).

## 7. Technical Considerations

- FluidAudio SPM: `https://github.com/FluidInference/FluidAudio.git` from `0.17.3`; platforms macOS 14+, Swift tools
  6.0. Pulls binary xcframework `NemoTextProcessing` — verify notarization in US-005.
- Redux is ANE-slower than v3 (84× vs 129× RTFx) and slightly less accurate (2.71 vs 2.27 WER test-clean); its win is
  download size. Ultra is the accuracy pick at v3 size. Menu order / recommendation follows bench.
- Parakeet v3 Swedish FLEURS WER 16.8% (FluidAudio) vs KB-Whisper small 3.5% (DiktaBench). Expect Whisper to remain
  the Swedish recommendation.
- No decoder prompt in Parakeet: `promptText` ignored. No language hint: `language` ignored.
- `SentenceEmbeddingService` / formatter untouched; they consume text only.
- Machine: M2 Max, macOS 26.6.2, Xcode 27.0.

## 8. Success Metrics

- Bench table exists with all five rows for sv and en.
- Sebastian can switch engines from the menu and dictate on each without restart.
- 647 → ≥ 680 tests green; release DMG notarized.

## 9. Open Questions

- Does FluidAudio's `AsrManager` expose segment timestamps on the batch path, or only via the sliding-window path?
  (US-002 worker to confirm; fallback: one segment per VAD window.)
- Where does FluidAudio cache models — reuse for the disk guard path.
