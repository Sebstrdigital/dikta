# Phase 1 — Formatter Engine

> **Historical / retired (2026-10):** Format Selection and its exclusive formatter implementation were removed. This phase record is retained as engineering history.

**Goal:** Build the skeleton that all formatters plug into, plus the shared helper functions that every formatter needs.

**When done:** You can call `engine.format(text, style: .message)` and it returns the text unchanged (stub). All helpers work and are tested.

---

## Progress

- [ ] TODO 1: Create the directory structure
- [ ] TODO 2: FormatterStyle enum
- [ ] TODO 3: TextFormatter protocol
- [ ] TODO 4: FormatterEngine
- [ ] TODO 5: splitSentences helper
- [ ] TODO 6: trimItem helper
- [ ] TODO 7: findPreamble helper
- [ ] All helpers tested and passing

---

## TODO 1: Create the directory structure

Create a `Formatter/` directory inside your Dikta source folder:

```
dikta-macos/Dikta/Formatter/
  FormatterStyle.swift
  TextFormatter.swift
  FormatterEngine.swift
  TextHelpers.swift
```

Four files. That's all of Phase 1.

---

## TODO 2: FormatterStyle enum

**File:** `FormatterStyle.swift`

Create an enum with two cases:
- `message` — for emails, chat, Slack (Phase 2)
- `structure` — for specs, notes, lists (Phase 3)

Make it conform to `String` and `CaseIterable` so you can loop over all styles later (useful for the picker UI in Phase 4).

---

## TODO 3: TextFormatter protocol

**File:** `TextFormatter.swift`

Define a protocol with a single method:
- Takes a `String`, returns a `String`

That's it. One method. Every formatter in Phase 2 and 3 will conform to this.

---

## TODO 4: FormatterEngine

**File:** `FormatterEngine.swift`

This is the router. It has one public method that:
1. Takes a `String` and a `FormatterStyle`
2. Uses a `switch` on the style to pick the right formatter
3. Calls that formatter's `format` method
4. Returns the result

**For now:** Since no formatters exist yet, both cases should just return the input text unchanged. Add a `// TODO: Phase 2` / `// TODO: Phase 3` comment so you know where to wire them in later.

---

## TODO 5: splitSentences helper

**File:** `TextHelpers.swift`

This is the most important helper. Every formatter needs to split text into sentences.

### The problem

Splitting on "." sounds easy but isn't. These all have periods that are NOT sentence endings:
- "Dr. Smith went home."
- "We use v1.0 in production."
- "Check e.g. the docs."
- "J. K. Rowling wrote it."
- "The cost was $3.50."

### The approach

1. **Build an abbreviation list.** These periods should be ignored:
   ```
   Mr. Mrs. Ms. Dr. Prof. Jr. Sr. St.
   e.g. i.e. etc. vs. approx. dept. govt. corp.
   ```

2. **Protect abbreviations.** Before splitting, temporarily replace each abbreviation's period with a placeholder character that won't appear in normal text (like `\u{FFFF}` or any Unicode character you pick). Example: `"Dr."` becomes `"Dr\u{FFFF}"`.

3. **Protect decimal numbers.** A period between two digits (`\d\.\d`) is a decimal, not a sentence end. Replace those periods with the same placeholder.

4. **Protect ellipsis.** Replace `"..."` with a placeholder.

5. **Split.** Now split on a period, question mark, or exclamation mark that is followed by:
   - One or more spaces AND an uppercase letter
   - OR end of string

   Keep the punctuation with the sentence (it belongs to it).

6. **Restore.** Replace all placeholder characters back to periods.

7. **Trim.** Trim whitespace from each sentence.

### How to think about the regex

You're looking for this pattern: sentence-ending punctuation followed by a space and a capital letter. In regex terms:
```
[.!?](?=\s+[A-Z])
```

But you want to SPLIT on it while keeping the punctuation with the left side. In Swift, you might find it easier to:
- Find all match positions
- Slice the string at each position (after the punctuation, before the space)

Or use `enumerateMatches` on an `NSRegularExpression`. Or just iterate character by character — sometimes a simple loop is clearer than regex, especially when learning.

### Test yourself with these

| Input | Expected output |
|-------|----------------|
| `"Hello. World."` | `["Hello.", "World."]` |
| `"Dr. Smith went home. He was tired."` | `["Dr. Smith went home.", "He was tired."]` |
| `"What? Really! Yes."` | `["What?", "Really!", "Yes."]` |
| `"Version 1.0 is out. Update now."` | `["Version 1.0 is out.", "Update now."]` |
| `"Check e.g. the docs. Then proceed."` | `["Check e.g. the docs.", "Then proceed."]` |
| `"She said hello... Then she left."` | `["She said hello...", "Then she left."]` |
| `"One sentence."` | `["One sentence."]` |
| `""` | `[]` |
| `"No period at the end"` | `["No period at the end"]` |
| `"J. K. Rowling wrote Harry Potter. It sold millions."` | `["J. K. Rowling wrote Harry Potter.", "It sold millions."]` |

The last one is hard. A single uppercase letter followed by a period (`J.`) is an initial, not a sentence. You can handle this by also protecting single-letter-dot patterns: any uppercase letter followed by a period and a space and another uppercase letter (`[A-Z]\. [A-Z]`).

---

## TODO 6: trimItem helper

**File:** `TextHelpers.swift` (same file, below splitSentences)

Takes a string and cleans it up for use as a bullet point or numbered step.

### Steps (in order)

1. Trim leading and trailing whitespace
2. If it starts with "and " or "or " or "but " (lowercase, with trailing space) → remove that prefix
3. Remove trailing period (but NOT trailing `?` or `!` — those carry meaning)
4. Capitalize the first character (only if it's a lowercase letter)
5. Trim whitespace again (in case removing prefix left a space)

### Test yourself

| Input | Expected |
|-------|----------|
| `"  buy milk.  "` | `"Buy milk"` |
| `"and fix the bug."` | `"Fix the bug"` |
| `"or skip this step."` | `"Skip this step"` |
| `"is it ready?"` | `"Is it ready?"` |
| `"Already capitalized."` | `"Already capitalized"` |
| `"  "` | `""` |
| `"wow!"` | `"Wow!"` |
| `"but not this one."` | `"Not this one"` |

---

## TODO 7: findPreamble helper

**File:** `TextHelpers.swift` (same file)

When a list starts at sentence 2 or 3 (not at the beginning), the sentences before it are a "preamble" — an introductory line.

### What it does

Takes:
- An array of sentences (from `splitSentences`)
- An index: where the list/steps start

Returns:
- A `String?` — the preamble text (joined sentences before the index), or `nil` if the list starts at index 0

### Logic

1. If `startIndex` is 0 → return `nil`
2. Take all sentences from index 0 to `startIndex - 1`
3. Join them with a space
4. Return the joined string

### Formatting note

When there IS a preamble, the formatter should change the preamble's last period to a colon. Example:

```
Preamble: "Here's what we need to do."
→ becomes: "Here's what we need to do:"
```

This is a nicer lead-in to a list. Implement this as a separate small helper or just inline it — your call.

### Test yourself

| Sentences | startIndex | Expected |
|-----------|-----------|----------|
| `["We need three things.", "Buy milk.", "Buy eggs."]` | `1` | `"We need three things."` |
| `["Buy milk.", "Buy eggs.", "Buy bread."]` | `0` | `nil` |
| `["Intro one.", "Intro two.", "First item.", "Second item."]` | `2` | `"Intro one. Intro two."` |

---

## Done checklist

When you've finished Phase 1, verify:

- [ ] `FormatterStyle` enum exists with `.message` and `.structure`
- [ ] `TextFormatter` protocol exists with one `format` method
- [ ] `FormatterEngine` routes styles to formatters (stubs for now)
- [ ] `splitSentences` passes all test cases above
- [ ] `trimItem` passes all test cases above
- [ ] `findPreamble` passes all test cases above
- [ ] All four files compile with no errors

Then move to [Phase 2 — Message Formatter](formatter-phase2-message.md).
