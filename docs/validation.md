# Validation Rules

This document defines mandatory validation steps for each area of the codebase. **Before proposing any fix or change**, run the relevant test suite first to establish a baseline. **After every change**, re-run to confirm no regressions.

## Formatter (MessageFormatter, StructuredTextFormatter, FormatterEngine, TextHelpers)

**Files**: `dikta-macos/Dikta/Formatter/*.swift`
**Tests**: `dikta-macos/DiktaTests/FormatterTests.swift` (68 tests as of v1.2)
**Test classes**: `BodyParagraphSplittingTests`, `ListDetectionTests`, `GreetingSignOffTests`, `EdgeCaseTests`, `CombinedScenarioTests`, `SplitSentencesTests`, `TrimItemTests`, `FindPreambleTests`

**Run command**:
```bash
cd dikta-macos && xcodebuild test -project Dikta.xcodeproj -scheme Dikta -only-testing:DiktaTests -destination 'platform=macOS' CODE_SIGN_IDENTITY=- 2>&1 | grep 'Executed.*test'
```

**Rules**:
1. Run tests BEFORE analyzing bugs — get the green baseline first
2. Run tests AFTER every code change — confirm no regressions
3. If adding a new behavior or fixing a bug, add a test case for it
4. Never propose a formatter fix without evidence from the test suite

## Config (AppConfig, ConfigService)

**Files**: `dikta-macos/Dikta/Models/AppConfig.swift`, `dikta-macos/Dikta/Services/ConfigService.swift`
**Tests**: `AppConfigDecodingTests`, `AppConfigEnabledLanguagesDecodingTests`

**Run command**: same as above (all in DiktaTests target)

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
cd dikta-macos && xcodebuild test -project Dikta.xcodeproj -scheme Dikta -only-testing:DiktaTests -destination 'platform=macOS' CODE_SIGN_IDENTITY=- 2>&1 | grep -E 'Executed.*test|error:|Downloading model:'
```

To run a single class, use its class name, e.g.
`-only-testing:DiktaTests/DebriefPipelineTests`.

**Before every run**: quit any running `Dikta.app` (`pgrep -x Dikta` → `osascript -e 'quit app "Dikta"'`) and make
sure no other `xcodebuild` is in flight — a live instance holds the audio device and can hang the ViewModel tests.

**Real-input tests**: `DebriefRealTranscriptTests.swift`'s real-transcript tests read from a local, gitignored
directory — `~/Documents/Dikta` by default, or the `DIKTA_REAL_SESSIONS_DIR` environment variable — and skip via
`XCTSkip` when it's missing or has no sessions. No real recording, transcript, or summary is ever checked into this
repo (see `.gitignore`); the known-defect regression tests in that file use synthetic, made-up transcripts instead.

---

*Add new sections here as validation rules are established for other areas.*
