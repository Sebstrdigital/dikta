# Feature: Expanded Language Support with Carousel Control

## Introduction

Dikta currently supports 3 dictation languages (English, Swedish, Indonesian) cycled via a single hotkey. As more languages are added, cycling through all of them becomes tedious — users must pass through languages they never use. This feature adds 9 new languages and introduces an enable/disable mechanism so the hotkey carousel only cycles through languages the user actively uses.

## Goals

- Support 12 total dictation languages covering major European and Nordic languages
- Let users control which languages appear in the hotkey carousel
- Keep the menu bar experience clean and discoverable — users can see all available languages and easily enable the ones they need
- Maintain backward compatibility with existing config.json files (3 current languages stay enabled by default)

## User Stories

### US-001: Add new dictation languages

**Description:** As a user, I want to dictate in Spanish, French, German, Portuguese, Italian, Dutch, Finnish, Norwegian, and Danish so that I can use Dikta in my preferred language.

**Acceptance Criteria:**
- [ ] All 9 new languages are selectable in the Write In menu and produce correct Whisper transcription
- [ ] The menu bar indicator shows the correct 2-letter code (ES, FR, DE, PT, IT, NL, FI, NO, DA) when each language is active
- [ ] Existing configs with English, Swedish, or Indonesian continue to work without migration

### US-002: Enable/disable languages in the carousel

**Description:** As a user, I want to enable or disable languages in the hotkey carousel so that I only cycle through languages I actively use.

**Acceptance Criteria:**
- [ ] Each language in the Write In menu has a visible enabled/disabled indicator and a toggle to change it
- [ ] The enabled/disabled state persists across app restarts (stored in config.json)
- [ ] At least one language must remain enabled at all times — disabling the last one is prevented

### US-003: Carousel cycles only enabled languages

**Description:** As a user, I want the language hotkey to skip disabled languages so that I can switch between my active languages quickly.

**Acceptance Criteria:**
- [ ] Pressing the language hotkey cycles only through enabled languages, skipping disabled ones
- [ ] Selecting a disabled language from the menu activates it and auto-enables it in the carousel
- [ ] If the active language is disabled, the app switches to the next enabled language

## Functional Requirements

- FR-1: The `Language` enum must include cases for all 12 languages with correct Whisper language codes: en, sv, id, es, fr, de, pt, it, nl, fi, no, da
- FR-2: `AppConfig` must store an `enabledLanguages: [Language]` array, defaulting to `[.english, .swedish, .indonesian]` for backward compatibility
- FR-3: When decoding a config.json that has no `enabledLanguages` key, the app must default to the 3 original languages enabled
- FR-4: The language carousel (`next` logic) must filter by enabled languages only
- FR-5: The Write In menu must show all 12 languages with a checkmark or similar indicator for enabled state, and a way to toggle it
- FR-6: Selecting a disabled language sets it as active AND enables it in the carousel
- FR-7: Attempting to disable the only remaining enabled language must be silently prevented (button disabled or no-op)
- FR-8: The `OutputMode.prompt(for:)` switch must compile with all 12 language cases (content is unused at runtime)

## Non-Goals (Out of Scope)

- Translation support (speak one language, get text in another) — transcription only
- Per-language hotkeys — the single carousel hotkey is sufficient
- Saved filter presets or language groups
- CJK languages (Japanese, Korean, Chinese) — may need special input handling, deferred
- Changes to the OutputMode prompts beyond making the switch exhaustive (unused at runtime)
- Windows port changes (dikta-windows)

## Technical Considerations

- The `Language` enum conforms to `CaseIterable` — all menu iteration and carousel logic picks up new cases automatically
- `enabledLanguages` must be a subset of `Language.allCases`; invalid entries in config should be silently dropped
- The duplicate `Language` enum in `DiktaTests.swift` must be updated to match
- New Swift files (if any) must be registered in `project.pbxproj`

## Success Metrics

- Users can dictate accurately in all 12 supported languages
- The hotkey carousel respects enabled languages — no unnecessary cycling
- Existing users upgrading from older configs experience no breakage

## Open Questions

- None — all decisions confirmed during scoping
