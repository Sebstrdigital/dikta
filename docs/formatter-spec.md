# Dikta Deterministic Formatter — Feature Specification

> **Historical / retired (2026-10):** Format Selection and its exclusive formatter implementation were removed. This document is retained as engineering history, not an active specification.

**Version:** Draft 2
**Author:** Claude (analyst), Sebastian (implementer)
**Date:** 2026-03-28

---

## Overview

After dictation, the user can select text and apply a formatting style via hotkey. The formatter takes raw transcribed text (already punctuated by WhisperKit) and restructures it deterministically — no AI, no network, instant.

## User Flow

1. User dictates text as normal — it gets pasted
2. User selects some or all of the pasted text
3. User presses a formatting hotkey (e.g., Cmd+Shift+F)
4. A small popup appears with style choices
5. User picks a style (click or keyboard shortcut)
6. The selected text is replaced with the formatted version

---

## The Structure Hierarchy

This is the fundamental principle behind all formatters. It comes from basic composition/rhetoric:

```
Level 0: Inline     →  "X, Y, and Z" inside a sentence     (1-3 words per item)
Level 1: Bullet     →  - Item one                           (one line per item)
                       - Item two
Level 2: Numbered   →  1. Do this                           (one line, order matters)
                       2. Then this
Level 3: Sections   →  ## Topic A                           (one paragraph+ per item)
                       Paragraph about topic A.
                       ## Topic B
                       Paragraph about topic B.
```

**The rule:** The longer each item is, the higher the structural level it needs.
- One word → stays inline (no formatting needed)
- One sentence → bullet point or numbered step
- Multiple sentences about one topic → section with a heading

The formatters apply this hierarchy. They don't change words — they add structure.

---

## Phased Delivery

### Phase 1 — Engine (the framework)
Build the formatter infrastructure. No actual formatting yet, just the skeleton that all formatters plug into.

### Phase 2 — Message Formatter (email/chat/message)
The most universally useful formatter. Works for emails, Slack messages, chat — any person-to-person communication.

### Phase 3 — Structured Text Formatter (bullets, sections)
For when you're dictating specifications, notes, lists, or documentation. Automatically picks the right structure level.

### Phase 4 — Integration
Wire it into Dikta with a hotkey and style picker UI.

---

## Phase 1: Engine

### What to build

```
Formatter/
  FormatterStyle.swift      — enum of available styles
  TextFormatter.swift        — protocol (one method: format)
  FormatterEngine.swift      — routes a style to the right formatter
  TextHelpers.swift          — shared utilities
```

### FormatterStyle

```
enum FormatterStyle: String, CaseIterable {
    case message        // Phase 2
    case structure      // Phase 3
}
```

### TextFormatter protocol

```
protocol TextFormatter {
    func format(_ text: String) -> String
}
```

Every formatter conforms to this. Pure function: string in, string out.

### FormatterEngine

```
class FormatterEngine {
    func format(_ text: String, style: FormatterStyle) -> String
}
```

Just a router — takes style enum, picks the right formatter, calls it. This is where you'd add new formatters later without changing the calling code.

### TextHelpers — Shared utilities

These helpers are used by multiple formatters. Build them first.

**1. `splitSentences(_ text: String) -> [String]`**

Split text into sentences. Sounds simple, isn't quite.

Split on: `.` `?` `!` followed by a space and an uppercase letter (or end of string).

Do NOT split on:
- Abbreviations: "Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "Jr.", "Sr."
- Common shortenings: "e.g.", "i.e.", "etc.", "vs.", "approx.", "dept."
- Numbers: "3.5", "v1.0"
- Ellipsis: "..."
- Single uppercase letter followed by period: "J. K. Rowling"

Strategy: The simplest approach that works is to:
1. Replace known abbreviations with placeholders (e.g., "Mr." → "Mr\x00")
2. Split on `. ` / `? ` / `! ` followed by uppercase (or end of string)
3. Restore placeholders

Return each sentence with its trailing punctuation included, whitespace trimmed.

```
Input:  "Dr. Smith went home. He was tired. What a day!"
Output: ["Dr. Smith went home.", "He was tired.", "What a day!"]
```

**2. `trimItem(_ text: String) -> String`**

Clean up a text fragment to be used as a bullet/step:
- Trim leading and trailing whitespace
- Remove trailing period (but keep `?` and `!`)
- Capitalize the first letter
- Remove leading conjunctions: "and ", "or ", "but " (only when at the very start)

```
Input:  "  update the database schema.  "
Output: "Update the database schema"

Input:  "and fix the tests."
Output: "Fix the tests"
```

**3. `findPreamble(_ sentences: [String], beforeIndex: Int) -> String?`**

Returns sentences before the first list/step item as a preamble block, or nil if the list starts at the beginning.

```
Sentences: ["We need to do three things.", "First, update X.", "Second, fix Y."]
beforeIndex: 1
Output: "We need to do three things."
```

### Test cases for Phase 1

You can test these helpers independently:

| Helper | Input | Expected |
|--------|-------|----------|
| splitSentences | "Hello. World." | ["Hello.", "World."] |
| splitSentences | "Dr. Smith said hello. She left." | ["Dr. Smith said hello.", "She left."] |
| splitSentences | "What? Really! Yes." | ["What?", "Really!", "Yes."] |
| splitSentences | "Version 1.0 is out. Update now." | ["Version 1.0 is out.", "Update now."] |
| splitSentences | "He said e.g. this works. Fine." | ["He said e.g. this works.", "Fine."] |
| trimItem | "  buy milk.  " | "Buy milk" |
| trimItem | "and fix the bug." | "Fix the bug" |
| trimItem | "is it ready?" | "Is it ready?" |
| trimItem | "  Already capitalized" | "Already capitalized" |

### Phase 1 deliverable

When Phase 1 is done, you should be able to:
1. Create a `FormatterEngine`
2. Call `engine.format(text, style: .message)` — it won't do anything useful yet (just return the text unchanged as a stub)
3. All helper functions work and are tested

---

## Phase 2: Message Formatter

### Purpose

Take dictated text intended for person-to-person communication (email, Slack, chat) and add proper structure: greeting on its own line, paragraphs separated by blank lines, sign-off separated.

This is the most universally useful formatter because everyone sends messages.

### How it works — three passes

The formatter runs three passes over the input text, in order:

**Pass 1: Extract greeting**
**Pass 2: Extract sign-off**
**Pass 3: Structure the body (everything in between)**

#### Pass 1 — Greeting detection

Scan the BEGINNING of the text (first sentence or first 10 words) for greeting patterns.

Patterns to match (case-insensitive):
```
"hi [NAME]"
"hey [NAME]"
"hello [NAME]"
"dear [NAME]"
"good morning [NAME]"
"good afternoon [NAME]"
"good evening [NAME]"
"hi there"
"hey there"
"hello there"
"good morning"
"good afternoon"
"good evening"
```

Where `[NAME]` = 0 to 3 words. Detect the name by taking consecutive words that are either:
- Capitalized (e.g., "John", "Maria", "Mr. Smith")
- A title followed by a capitalized word ("Mr.", "Mrs.", "Dr.")

If the greeting is followed by a comma, the comma is part of the greeting. If there's no comma, add one.

**Output:** The greeting line, followed by a blank line. Remove the greeting from the remaining text.

```
"Hi Maria I wanted to ask" → greeting = "Hi Maria," / remaining = "I wanted to ask"
"Hi Maria, I wanted to ask" → greeting = "Hi Maria," / remaining = "I wanted to ask"
"Good morning, just a quick" → greeting = "Good morning," / remaining = "just a quick"
"Hey what's up" → greeting = "Hey," / remaining = "what's up"
```

**When NOT to match:**
- "Hi" or "Hey" in the middle of text ("I said hi to her") — only match at the start
- Names that aren't actually names: fall back to 0-name pattern ("Hi," + rest) — this is fine

#### Pass 2 — Sign-off detection

Scan the END of the text (last 30 words) for sign-off patterns.

Patterns to match (case-insensitive):
```
"best regards"
"kind regards"
"warm regards"
"regards"
"thanks"
"thank you"
"many thanks"
"thanks a lot"
"cheers"
"sincerely"
"yours sincerely"
"yours truly"
"best"
"all the best"
"talk soon"
"speak soon"
"take care"
```

**Important:** Only match "thanks" / "thank you" as a sign-off when:
- It's at the START of a sentence (after a period, or at the beginning after extracting greeting)
- AND it's within the last 30 words of the text
- "Thank you for sending the report" in the middle of the text is NOT a sign-off

**Name after sign-off:** After the sign-off phrase, look for 1-3 capitalized words at the very end of the text. That's the sender's name.

**Output:** The sign-off on its own line. If there's a name, put it on the next line. Separated from the body by a blank line.

```
"... let me know. Thanks, Sebastian" → sign-off = "Thanks,\nSebastian"
"... looks good. Best regards" → sign-off = "Best regards"
"... I appreciate it. Thank you so much, Anna Maria" → sign-off = "Thank you so much,\nAnna Maria"
```

#### Pass 3 — Body structuring

The body is everything between the greeting and sign-off. Now add paragraph breaks.

**Rule 1 — Split on transition words**
Look for these at the START of a sentence (case-insensitive):
```
"also"
"additionally"
"furthermore"
"moreover"
"by the way"
"another thing"
"on another note"
"on a different note"
"regarding"
"as for"
"separately"
"in addition"
"one more thing"
"besides that"
"apart from that"
"anyway"
"moving on"
```

When found: insert a blank line BEFORE the sentence that starts with the transition word. Keep the transition word in the text (don't remove it — it reads naturally in emails).

**Rule 2 — Long text fallback**
If no transition words were found AND the body is longer than 4 sentences: insert a paragraph break every 3 sentences. This prevents wall-of-text emails.

If the body is 1-4 sentences and has no transition words: leave as a single paragraph. Short emails are fine as-is.

**Rule 3 — Question grouping**
If a sentence ends with `?` and the next sentence also relates to it (starts with "or", "and", "what about"), keep them in the same paragraph. Don't split question clusters.

### Full examples

```
Input:
"Hi Maria, I wanted to follow up on our meeting yesterday. The project timeline looks good but we need to adjust the budget for Q3. Also, could you send me the updated spreadsheet when you get a chance? I need it for the board presentation on Friday. Thanks, Sebastian"

Output:
"Hi Maria,

I wanted to follow up on our meeting yesterday. The project timeline looks good but we need to adjust the budget for Q3.

Also, could you send me the updated spreadsheet when you get a chance? I need it for the board presentation on Friday.

Thanks,
Sebastian"
```

```
Input:
"Just wanted to let you know the deployment went smoothly. All tests are passing and the client confirmed it's working. Cheers"

Output:
"Just wanted to let you know the deployment went smoothly. All tests are passing and the client confirmed it's working.

Cheers"
```

```
Input:
"Dear Mr. Johnson, thank you for your prompt response regarding the contract terms. We've reviewed the amendments and are in agreement with sections one through four. However, we have concerns about the liability clause in section five. Regarding the timeline, we would prefer to push the signing date to next Friday to give our legal team time to review. Additionally, could you confirm whether the non-compete terms apply to all subsidiaries or only the parent company? We look forward to resolving these final points. Kind regards, Sebastian Strandberg"

Output:
"Dear Mr. Johnson,

Thank you for your prompt response regarding the contract terms. We've reviewed the amendments and are in agreement with sections one through four. However, we have concerns about the liability clause in section five.

Regarding the timeline, we would prefer to push the signing date to next Friday to give our legal team time to review.

Additionally, could you confirm whether the non-compete terms apply to all subsidiaries or only the parent company?

We look forward to resolving these final points.

Kind regards,
Sebastian Strandberg"
```

```
Input:
"Hey, quick question. Do you have the API keys for the staging environment? Or should I ask DevOps? Let me know when you can. Thanks"

Output:
"Hey,

Quick question. Do you have the API keys for the staging environment? Or should I ask DevOps?

Let me know when you can.

Thanks"
```

### Edge cases

| Situation | What to do |
|-----------|------------|
| No greeting, no sign-off | Just do paragraph splitting on the body |
| Greeting but no sign-off | Format greeting + structured body |
| "Thanks for the update" mid-text | NOT a sign-off — it's a full sentence with content after "thanks" |
| "Thanks!" mid-text | NOT a sign-off if there are 30+ words after it |
| Multiple possible sign-offs | Use the LAST one that's within the final 30 words |
| Empty text | Return empty string |
| One sentence | Return unchanged |
| "Hi" with no name | Greeting = "Hi," |
| Name with title "Dear Dr. Smith" | Greeting = "Dear Dr. Smith," |

---

## Phase 3: Structured Text Formatter

### Purpose

Take dictated text about tasks, specs, plans, or explanations and add structure — bullets, numbered lists, or sections — based on what the content needs.

This formatter is smarter than the Message formatter because it has to DECIDE which structure level to use. It uses the structure hierarchy from above.

### How it works — analyze then format

**Step 1: Detect what kind of content this is**
**Step 2: Apply the right structure level**

#### Step 1 — Content analysis

Run these checks in order. Use the FIRST one that matches:

**Check A — Explicit enumeration**
Look for sequence markers (case-insensitive):
```
"first" / "firstly" / "first of all"
"second" / "secondly"
"third" / "thirdly"
"next"
"then"
"finally" / "lastly" / "last"
"also" (when listing)
"another" / "another thing"
"step one" / "step two" / etc.
"number one" / "number two" / etc.
```

If you find 3+ of these scattered through the text → this is an enumerated list.

Now decide: **bullets or numbers?**

- If sequence markers imply ORDER ("first...then...finally", "step one...step two"): → **numbered list**
- If sequence markers just enumerate without order ("also", "another thing"): → **bullet list**

**Check B — Colon-list**
Look for a colon (`:`) or trigger phrase followed by a comma-separated list:
```
Trigger phrases: "such as", "like", "including", "for example", "the following"
```

Only match when the comma-list goes to the END of the sentence (see Phase 2 discussion for why mid-sentence lists should be left alone).

If found → **bullet list** (one bullet per comma-separated item)

**Check C — Homogeneous short sentences**
If ALL sentences are under 15 words and there are 3+ sentences:
- If sentences are imperative (start with a verb) → **numbered list** (they're steps)
- Otherwise → **bullet list**

How to detect imperative: check if the first word of each sentence is a common verb form. Simple heuristic — check if the first word is NOT:
- A pronoun (I, we, he, she, it, they, you)
- An article (the, a, an)
- A preposition (in, on, at, for, with)
- A conjunction (and, but, or)
- A name (capitalized word that isn't the first word in the text)

If the first word is none of these, it's likely an imperative verb. If most (>60%) sentences start with an imperative verb → numbered. Otherwise → bullets.

**Check D — Long heterogeneous items**
If sentences can be grouped into 2-5 TOPICS where each topic has 2+ sentences, and the topics are separated by transition words (same list as in Message Formatter Pass 3) → **sections**

A "topic" = a cluster of sentences between transition words. Each topic gets a heading.

How to generate the heading: take the first noun phrase from the first sentence of that cluster. Keep it to 2-4 words. Capitalize it as a title.

This is the trickiest detection. Acceptable to get it wrong sometimes — the user can always re-dictate.

**Check E — No pattern detected**
Return the text unchanged. Don't force structure where there isn't any.

#### Step 2 — Apply formatting

**Bullet list output:**
```
[optional preamble]

- Item one
- Item two
- Item three

[optional postamble]
```

Rules:
- Preamble = any sentences before the first list item. Keep as regular paragraph.
- Each item: use `trimItem()`, remove the sequence marker that triggered the detection.
- Postamble = any sentences after the last list item. Rare, but handle it.
- Strip trailing periods from items.
- Capitalize first letter of each item.

**Numbered list output:**
```
[optional preamble]

1. First action
2. Second action
3. Third action
```

Same rules as bullets, but with `1.` `2.` `3.` prefix.

Additional rule for numbered lists: strip filler phrases from the start of each step:
- "you need to" → remove
- "you should" → remove
- "you have to" → remove
- "you can" → remove
- "you" (when followed by a verb) → remove
- "then" (when at the start of a step) → remove
- "after that" → remove
- "next" (when at the start of a step) → remove

```
"First you need to update the schema" → "1. Update the schema"
"Then you should run the tests" → "2. Run the tests"
```

**Sections output:**
```
[optional preamble]

## Topic A

Sentences about topic A. Kept as flowing text, not bulleted.

## Topic B

Sentences about topic B.
```

Rules:
- Each section gets a `##` heading (markdown style — this will look right in most contexts, and can be rendered nicely if the target app supports markdown).
- The body of each section is the original sentences, unmodified (except normal sentence spacing).
- If a section has only 1 sentence, that's fine — still make it a section.

### Full examples

**Explicit enumeration → bullets:**
```
Input:
"There are several issues with the current design. First, the navigation is confusing for new users. Second, the color contrast doesn't meet accessibility standards. Third, the loading states are missing on all forms. Also, the mobile layout breaks below 320 pixels."

Output:
"There are several issues with the current design.

- The navigation is confusing for new users
- The color contrast doesn't meet accessibility standards
- The loading states are missing on all forms
- The mobile layout breaks below 320 pixels"
```

**Explicit ordered steps → numbered:**
```
Input:
"Here's how to set up the project. First, you need to clone the repository from GitHub. Then you install all the dependencies using npm install. After that, you should create a dot env file with your database credentials. Finally, run the migration script and start the dev server."

Output:
"Here's how to set up the project:

1. Clone the repository from GitHub
2. Install all the dependencies using npm install
3. Create a dot env file with your database credentials
4. Run the migration script and start the dev server"
```

**Colon-list → bullets:**
```
Input:
"The tech stack includes: React for the frontend, Node.js for the API, PostgreSQL for the database, and Redis for caching."

Output:
"The tech stack includes:

- React for the frontend
- Node.js for the API
- PostgreSQL for the database
- Redis for caching"
```

**Short imperative sentences → numbered:**
```
Input:
"Open the terminal. Navigate to the project folder. Run npm install. Copy the env example file. Start the development server."

Output:
"1. Open the terminal
2. Navigate to the project folder
3. Run npm install
4. Copy the env example file
5. Start the development server"
```

**Long mixed content → sections:**
```
Input:
"The authentication system needs a complete overhaul. Currently we're storing session tokens in local storage which our legal team flagged as non-compliant. We need to move to HTTP-only cookies with proper CSRF protection. Regarding the API, we should switch from REST to GraphQL for the dashboard endpoints. The current REST setup requires too many round trips for the complex data views. On a different note, the deployment pipeline is too slow. Build times have increased to over 15 minutes and the team is losing productivity waiting for CI."

Output:
"## Authentication

The authentication system needs a complete overhaul. Currently we're storing session tokens in local storage which our legal team flagged as non-compliant. We need to move to HTTP-only cookies with proper CSRF protection.

## API

We should switch from REST to GraphQL for the dashboard endpoints. The current REST setup requires too many round trips for the complex data views.

## Deployment

The deployment pipeline is too slow. Build times have increased to over 15 minutes and the team is losing productivity waiting for CI."
```

### Edge cases

| Situation | What to do |
|-----------|------------|
| "and then" chains in one sentence | Split on "and then", make numbered list |
| Mix of bullets and sections | Prefer sections if any item is 2+ sentences long |
| Only 2 items detected | Still format (2-item lists are valid) |
| Comma list mid-sentence | Leave unchanged (don't break sentence flow) |
| All sentences are long (20+ words each) | Probably prose — Check D (sections) or Check E (no change) |
| "Then" meaning "at that time" ("Back then...") | Only split on "then" when: after a period, or "and then", or at sentence start followed by a comma |
| Text is already formatted (has newlines/bullets) | Return unchanged — don't re-format formatted text |

---

## Phase 4: Integration

### Hotkey & UI

This phase wires the engine into Dikta. Details to be decided when we get here, but the rough plan:

1. **Register a formatting hotkey** (e.g., Cmd+Shift+F — check for collisions with existing Dikta hotkeys)
2. **Read the selected text** from the frontmost application (via Accessibility API or pasteboard trick: Cmd+C to copy, read pasteboard, format, Cmd+V to paste back)
3. **Show a style picker** — small floating panel near the cursor with options:
   - Message (Phase 2)
   - Structure (Phase 3)
   - Auto (try both, use whichever has more effect — stretch goal)
4. **Replace the selection** with the formatted text

### Open questions for Phase 4

1. **Hotkey:** Cmd+Shift+F? Or something else?
2. **Style picker UI:** Floating panel? Context menu? Single-key shortcuts (M for Message, S for Structure)?
3. **What if no rules match?** Return unchanged with a subtle notification? Or just return unchanged silently?
4. **Undo:** Cmd+Z in the target app should undo the paste. Verify this works.
5. **Auto mode:** Worth building? Or just let users pick?

---

## Summary: What to build, in order

| Phase | What | Sessions | Deliverable |
|-------|------|----------|-------------|
| 1 | Engine + helpers | 2-3 | FormatterStyle, TextFormatter protocol, FormatterEngine router, splitSentences, trimItem, findPreamble — all tested |
| 2 | Message Formatter | 3-4 | Greeting/sign-off/body detection, paragraph splitting — tested with examples above |
| 3 | Structured Text | 4-5 | Content analysis (5 checks), bullet/numbered/section output — tested with examples above |
| 4 | Integration | 2-3 | Hotkey, style picker, selection read/replace |
