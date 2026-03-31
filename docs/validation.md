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

---

*Add new sections here as validation rules are established for other areas.*
