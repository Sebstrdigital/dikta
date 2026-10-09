# Validation Rules

This document defines mandatory validation steps for each area of the codebase. **Before proposing any fix or change**, run the relevant test suite first to establish a baseline. **After every change**, re-run to confirm no regressions.

## Formatter (MessageFormatter, StructuredTextFormatter, FormatterEngine, TextHelpers)

**Files**: `dikta-macos/Dikta/Formatter/*.swift`
**Tests**: `dikta-macos/DiktaTests/FormatterTests.swift` (68 tests as of v1.2)
**Test classes**: `BodyParagraphSplittingTests`, `ListDetectionTests`, `GreetingSignOffTests`, `EdgeCaseTests`, `CombinedScenarioTests`, `SplitSentencesTests`, `TrimItemTests`, `FindPreambleTests`

**Run command**:
```bash
cd dikta-macos && xcodebuild test -project Dikta.xcodeproj -scheme Dikta -only-testing:DiktaTests -destination 'platform=macOS' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=UUM29335B4 2>&1 | grep 'Executed.*test'
```

**Rules**:
1. Run tests BEFORE analyzing bugs — get the green baseline first
2. Run tests AFTER every code change — confirm no regressions
3. If adding a new behavior or fixing a bug, add a test case for it
4. Never propose a formatter fix without evidence from the test suite

## Config (AppConfig, ConfigService)

**Files**: `dikta-macos/Dikta/Models/AppConfig.swift`, `dikta-macos/Dikta/Services/ConfigService.swift`
**Tests**: `AppConfigDecodingTests`, `AppConfigEnabledLanguagesDecodingTests`, `ConfigServiceAtomicWriteTests`

**Run command**: same as above (all in DiktaTests target)

## Transcription Engine (Parakeet Ultra)

**Files**: `dikta-macos/Dikta/Services/TranscriptionEngine.swift`,
`dikta-macos/Dikta/Services/ParakeetEngine.swift`, `dikta-macos/Dikta/Services/TranscriptionSupport.swift`,
`dikta-macos/Dikta/Services/TextLanguageInference.swift`, `dikta-macos/Dikta/ViewModels/MenuBarViewModel.swift`.
Legacy config compatibility also covers `TranscriptionEngineKind.swift`, `AppConfig.swift`, and `HotkeyConfig.swift`.

**Test classes**: `ParakeetEngineTests`, `TranscriptionSupportPostProcessingTests`,
`TranscriptionSupportSanitizeAndDropEmptyTests`, `TranscriptionSupportSortMonotonicTests`,
`TextLanguageInferenceTests`, `HotkeyModeAvailabilityTests`, and config tests above.

**Run command**: same signed Release `DiktaTests` target as above.

**Rules**:
1. Unit tests must inject `FakeParakeetBackend` or `FakeTranscriptionEngine`; they must never load or download a real model.
2. Cover Ultra load/download failure, disk guard, cleanup, empty/no-speech behavior, timing fallback/order,
   automatic language consumers, nil language hints at every app entry point, inactive language-hotkey collisions,
   and legacy config round-trip.
3. Real Ultra checks are separate manual qualification runs using public fixtures only.
4. The isolated validation scheme must inject both `DIKTA_CONFIG_FILE` and `DIKTA_REAL_SESSIONS_DIR`;
   `TestHostIsolationTests` verifies those effective test-host paths.

**Parakeet bench command** (WER/RTF/load-time comparison against Whisper, not part of the
`DiktaTests` gate — a manual report, see `docs/review-2026-09/parakeet-bench.md`):
```bash
cd dikta-macos/bench && ./run.sh parakeet redux parakeet v3 parakeet ultra
```
Single variant: `./run.sh parakeet v3` (or `redux`/`ultra`). See `bench/README.md` for scoring a
single piece by hand and the first-load ANE-compile caveat (a cold Parakeet load can take minutes).

## Debrief mode (summarizers, audio I/O, pipeline, ViewModel wiring)

**Files**: `dikta-macos/Dikta/Models/DebriefSummary.swift`, `dikta-macos/Dikta/Services/Debrief/*.swift`,
`dikta-macos/Dikta/Services/ClipboardManager.swift` (`pasteMultiline`),
`dikta-macos/Dikta/Services/AudioRecorder.swift` (`silenceAutoStopEnabled`, `maxBufferSamples`),
`dikta-macos/Dikta/ViewModels/MenuBarViewModel.swift` (debrief branch), `dikta-macos/Dikta/Views/MenuBarView.swift` (`DebriefMenu`)

**Test files**: `DebriefSummaryTests.swift`, `AudioFileLoaderTests.swift`, `DebriefStoreTests.swift`,
`DebriefPipelineTests.swift`, `MenuBarViewModelDebriefTests.swift`, `DebriefRealTranscriptTests.swift`

**Test classes**: `DebriefSummaryRenderPlainTextEnglishTests`, `DebriefSummaryRenderPlainTextSwedishTests`,
`DebriefSummaryParserTests`, `DebriefSummaryCodableTests`, `HeuristicDebriefSummarizerTests`,
`HeuristicDebriefSummarizerRamblingTranscriptTests`, `OllamaDebriefSummarizerTests`,
`OllamaDebriefSummarizerModelMatchesTests`, `ChainedDebriefSummarizerTests`, `DebriefSummarizerFactoryTests`,
`AudioFileLoaderTests`, `DebriefStoreTests`, `DebriefPipelineTests`, `AudioRecorderDebriefOverrideTests`,
`AppConfigDebriefDecodingTests`, `MenuBarViewModelDebriefTests`, `TranscriptSanitizerTests`,
`DebriefSummaryNormalizationTests`

**Run command** — run the full target. `-only-testing:` takes a *class* name, not a file name, so
`-only-testing:DiktaTests/DebriefSummaryTests` matches nothing and silently runs zero tests:
```bash
cd dikta-macos && xcodebuild test -project Dikta.xcodeproj -scheme Dikta -only-testing:DiktaTests -destination 'platform=macOS' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=UUM29335B4 2>&1 | grep -E 'Executed.*test|error:|Downloading model:'
```

To run a single class, use its class name, e.g.
`-only-testing:DiktaTests/DebriefPipelineTests`.

**Signing**: test builds are signed with the same Developer ID identity as releases, never ad-hoc (`CODE_SIGN_IDENTITY=-`). macOS ties Microphone / System Audio grants to the code signature; an ad-hoc signature changes on every rebuild, so each rebuilt test host re-prompts. With the stable identity you grant once. Confirmed 2026-09-18.

**Before a run that requires Dikta to be stopped**: ask the user before quitting it. Check for conflicting builds; do not stop unrelated applications. A live Dikta instance can hold the audio device and interfere with ViewModel tests.

**Real-input tests**: `DebriefRealTranscriptTests.swift`'s real-transcript tests read from a local, gitignored
directory — `~/Documents/Dikta` by default, or the `DIKTA_REAL_SESSIONS_DIR` environment variable — and skip via
`XCTSkip` when it's missing or has no sessions. No real recording, transcript, or summary is ever checked into this
repo (see `.gitignore`); the known-defect regression tests in that file use synthetic, made-up transcripts instead.

## Call Debrief (system audio capture, streaming writer, chunked transcription, rolling summary)

**Files**: `dikta-macos/Dikta/Services/SystemAudioTapRecorder.swift`,
`dikta-macos/Dikta/Services/Debrief/StreamingWavWriter.swift`,
`dikta-macos/Dikta/Services/Debrief/ChunkedTranscriptionSession.swift`,
`dikta-macos/Dikta/Services/Debrief/TwoTrackMerger.swift`,
`dikta-macos/Dikta/Services/Debrief/DebriefState.swift`,
`dikta-macos/Dikta/Services/Debrief/DebriefDelta.swift`,
`dikta-macos/Dikta/Services/Debrief/DebriefAccumulator.swift`,
`dikta-macos/Dikta/Services/Debrief/EmbeddingSimilarity.swift`,
`dikta-macos/Dikta/Services/Debrief/RollingDebriefSummarizer.swift`,
`dikta-macos/Dikta/Services/Debrief/FoundationModelsDeltaSummarizer.swift`,
`dikta-macos/Dikta/Services/Debrief/HeuristicDeltaSummarizer.swift`,
`dikta-macos/Dikta/Services/Debrief/OllamaDeltaSummarizer.swift`,
`dikta-macos/Dikta/Models/TranscriptSegment.swift`, `dikta-macos/Dikta/Models/LabeledSegment.swift`,
`dikta-macos/Dikta/ViewModels/MenuBarViewModel.swift` (call debrief branch)

**Test files**: `SystemAudioTapRecorderTests.swift`, `StreamingWavWriterTests.swift`,
`ChunkedTranscriptionSessionTests.swift`, `TwoTrackMergerTests.swift`, `DebriefAccumulatorTests.swift`,
`RollingDebriefSummarizerTests.swift`, `TranscriptSegmentTests.swift`

**Test classes**: `SystemAudioTapRecorderTests`, `StreamingWavWriterTests`, `ChunkedTranscriptionSessionTests`,
`TwoTrackMergerMergeTests`, `TwoTrackMergerRenderTests`, `TwoTrackMergerIsLabeledTranscriptTests`,
`TwoTrackMergerStripLabelsTests`, `DebriefAccumulatorTests`, `RollingDebriefSummarizerTests`,
`TranscriptSegmentTests`, `TranscriberSanitizeAndDropEmptyTests`, `TranscriberSortMonotonicTests`,
`TranscriberCappedPromptTokensTests`

**Run command**:
```bash
cd dikta-macos && xcodebuild test -project Dikta.xcodeproj -scheme Dikta -only-testing:DiktaTests -destination 'platform=macOS' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=UUM29335B4 2>&1 | grep -E 'Executed.*test|error:|failed'
```

To run a single class, use its class name, e.g. `-only-testing:DiktaTests/RollingDebriefSummarizerTests`.

**Rules**:
1. No test may open a real process tap or touch the microphone — use `FakeSystemAudioCapture` or another fake capture source, never a live `SystemAudioTapRecorder` device.
2. Kill orphaned `Dikta -ApplePersistenceIgnoreState` test hosts before running ViewModel tests — a leftover instance holds the audio device and can hang the run:
```bash
for p in $(pgrep -x Dikta); do ps -o command= -p $p | grep -q ApplePersistenceIgnoreState && kill $p; done
```
3. Real call recordings live under `~/Documents/Dikta` (or the `DIKTA_REAL_SESSIONS_DIR` environment variable) and are never committed — see `.gitignore`.
4. Every test that constructs a `MenuBarViewModel` must inject `FakeAudioRecorder` and `FakeAudioFeedback` (via its file's `makeViewModel` helper). A real `AudioFeedback` builds an `AVAudioEngine` in its initializer and can wedge the test host against a previous instance's `deinit` inside CoreAudio's `HALB_Mutex`; a real `AudioRecorder` reaches the microphone and `AVCaptureDevice.requestAccess`. `MenuBarViewModel.makeDefaultAudioFeedback()` falls back to `SilentAudioFeedback` under XCTest as a safety net, but tests inject explicitly.

**Known pre-existing failure**: `testSlackMuterReturnsNilWhenSlackNotRunning` (`MicMutingTests.swift`) fails when
Slack.app is open on the test machine — unrelated to Call Debrief, not a regression.

## Non-interfering local validation

ViewModel tests must use `FakeMuterRegistry` (including omitted/nil factory arguments), not production muters. Keep the user's browsers, Slack and other unrelated applications open and untouched; their presence alone is not a blocker.

Until the four real-muter absence tests are isolated, local validation may exclude them:
- `-skip-testing:DiktaTests/MicMutingTests/testTeamsMuterReturnsNilWhenTeamsNotRunning`
- `-skip-testing:DiktaTests/MicMutingTests/testSlackMuterReturnsNilWhenSlackNotRunning`
- `-skip-testing:DiktaTests/MicMutingTests/testWhatsAppMuterReturnsNilWhenWhatsAppNotRunning`
- `-skip-testing:DiktaTests/MicMutingTests/testUvenMuterReturnsNilWhenUvenNotRunning`

Report this as a filtered run with the four coverage gaps, not a full-suite pass. Keep safe fake tests and relevant Native Kokoro checks. Use synthetic/isolated real-session inputs rather than the user's recordings. No mandatory app inventory or repeated whole-test-factory audit. Ask before stopping Dikta itself if a check requires it.

## Release gate (build-release.sh)

**Files**: `dikta-macos/scripts/build-release.sh`

There is no macOS CI — releases are built, tested, signed, notarized and published locally, so the release
script is the only gate. It enforces that the `DiktaTests` target actually ran before anything ships —
a chronic failure mode is a green-looking pipeline that shipped a broken or empty test suite (e.g. an
`-only-testing:` filter that silently matches zero tests, or a build error that never reaches the test phase).

**`scripts/build-release.sh`**: before archiving, runs
`xcodebuild test -only-testing:DiktaTests ...` (same identity/team as the archive build) into a log, then aborts
the release with a clear error and the last lines of the log if:
- the log has no `Executed N tests` line with `N > 0`, or
- the test run's exit code is non-zero (a real failure).

`--skip-tests` bypasses the gate entirely and prints a loud warning that the DMG is being built on an unverified
test suite — use only for emergencies, never routinely. `--no-publish` (DMG only, no appcast/release) still runs
the gate; the two flags combine in either order:
```bash
./scripts/build-release.sh --skip-tests
./scripts/build-release.sh --no-publish --skip-tests
```

**Known pre-existing gap this gate must not choke on**: `DebriefRealTranscriptTests` skips via `XCTSkip` (not a
failure) when `~/Documents/Dikta` has no local sessions — the gate counts a skip as part of a passing run, since
`xcodebuild` reports it separately from failures and it still contributes to `Executed N tests`. On a machine
that *does* have a local session, but the newest one is too short to yield any decision/action item, one of that
file's real-transcript assertions can fail for real (an environment condition, not a regression) — see that
file's own doc comment. That failure is real and the gate is meant to catch it like any other; it is not silenced
here. If it fires only because of a too-short local recording, re-record a longer local session or use
`DIKTA_REAL_SESSIONS_DIR` to point at one that isn't, rather than reaching for `--skip-tests`.

---

*Add new sections here as validation rules are established for other areas.*
