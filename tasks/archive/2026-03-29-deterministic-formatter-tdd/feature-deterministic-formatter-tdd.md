# Feature: Deterministic Text Formatter — TDD Hardening

## Introduction

Dikta's post-transcription formatter has a comprehensive test suite (129 cases) with 30 failing tests — all in body paragraph splitting. The test suite is the specification. This Feature iterates the formatter implementation until 90%+ tests pass.

The test suite lives in `DiktaTests/FormatterTests.swift`. Reference docs: `docs/email-formatting-conventions.md` and `docs/formatter-research-rules.md`.

## Goals

- 90%+ test pass rate (currently 85% — 30 failures out of 129 new tests + 68 existing)
- MessageFormatter delegates body formatting to StructuredTextFormatter
- StructuredTextFormatter handles paragraph splitting via topic-shift detection
- All deterministic — no LLM, no network, instant

## Pre-work completed (NOT stories)

- 129 test cases written in `DiktaTests/FormatterTests.swift`
- MessageFormatter rewritten with 6-zone model (greeting, opening pleasantry, body, closing pleasantry, sign-off, name)
- Research docs on formatting conventions and detection rules

## User Stories

### US-001: StructuredTextFormatter paragraph splitting

**Description:** As a user, I want the body formatter to detect natural topic shifts in dictation and insert paragraph breaks.

**Acceptance Criteria:**
- [ ] Transition phrases ("however", "by the way", "regarding", etc.) at sentence start trigger paragraph breaks
- [ ] Long text without markers gets split every 3 sentences as fallback
- [ ] All BodyParagraphSplittingTests (A01-A40) pass at 90%+ rate
- [ ] Typecheck passes

### US-002: MessageFormatter body delegation to StructuredTextFormatter

**Description:** As a user, I want the Message formatter to use StructuredTextFormatter for body formatting so paragraph/list logic is shared.

**Acceptance Criteria:**
- [ ] MessageFormatter calls StructuredTextFormatter.format() for the body zone instead of its own structureBody()
- [ ] All GreetingSignOffTests (C01-C20) still pass
- [ ] All EdgeCaseTests (D01-D22) still pass
- [ ] Typecheck passes

### US-003: Sync test file inlined code with production

**Description:** As a developer, I want the inlined formatter code in FormatterTests.swift to match the production code so tests validate the actual implementation.

**Acceptance Criteria:**
- [ ] MessageFormatter in FormatterTests.swift matches production MessageFormatter.swift exactly
- [ ] StructuredTextFormatter in FormatterTests.swift matches production StructuredTextFormatter.swift exactly
- [ ] All previously passing tests still pass after sync
- [ ] Typecheck passes

### US-004: Idempotency and no-regression fixes

**Description:** As a user, I want formatting to be idempotent and never produce worse output than the input.

**Acceptance Criteria:**
- [ ] All idempotency tests (D06-D09) pass
- [ ] No double punctuation (D18) passes
- [ ] All content preservation tests (D12-D15, A36-A38) pass
- [ ] Typecheck passes

## Functional Requirements

- FR-1: Test inputs are raw dictation strings — proper punctuation but no manual formatting
- FR-2: StructuredTextFormatter must handle both standalone use and delegated use from MessageFormatter
- FR-3: Formatting must be idempotent
- FR-4: Formatting must never lose text content
- FR-5: All string operations — no LLM, no network, no async

## Non-Goals

- No LLM/AI integration
- No UI changes
- No Windows port changes
- No multi-language formatting rules
- No new test cases (test suite is complete)

## Technical Considerations

- Tests run via `cd dikta-macos && swift test`
- Test file inlines production code (project uses executable target, not library)
- When changing production formatter files, MUST update the inlined copies in FormatterTests.swift
- Formatter source files: `Dikta/Formatter/MessageFormatter.swift`, `Dikta/Formatter/StructuredTextFormatter.swift`, `Dikta/Formatter/TextHelpers.swift`
- Reference: `docs/email-formatting-conventions.md` (6-zone model), `docs/formatter-research-rules.md` (detection rules)

## Success Metrics

- 90%+ test pass rate across all 197 tests (129 new + 68 existing)
- All 30 currently failing paragraph-splitting tests addressed
- Remaining failures documented as known deterministic limitations
