# Phase 3 — Structured Text Formatter

> **Historical / retired (2026-10):** Format Selection and its exclusive formatter implementation were removed. This phase record is retained as engineering history.

**Goal:** Take dictated specifications, notes, or explanations and add the right structure — bullets, numbered lists, or sections — based on what the content needs.

**Depends on:** Phase 1 (engine + helpers) and Phase 2 (for experience with the pattern)

**When done:** `engine.format(text, style: .structure)` analyzes content and applies the appropriate structure level automatically.

---

## Progress

- [ ] TODO 1: Create StructuredTextFormatter (skeleton)
- [ ] TODO 2: Content analysis (Checks A through E)
- [ ] TODO 3: Bullet list formatting
- [ ] TODO 4: Numbered list formatting
- [ ] TODO 5: Section formatting
- [ ] TODO 6: "And then" chain handling
- [ ] TODO 7: Wire into engine + all 10 integration tests passing

---

## The key idea

This formatter is different from the Message Formatter. The Message Formatter always does the same thing (greeting + paragraphs + sign-off). This one has to DECIDE what kind of structure to apply.

It follows the structure hierarchy:

```
Bullet list   →  items are short, no particular order
Numbered list →  items are short, order matters (steps/instructions)
Sections      →  items are long (paragraph each), different topics
No change     →  text is regular prose, no list structure detected
```

The formatter checks for patterns in priority order and uses the first match.

---

## TODO 1: Create StructuredTextFormatter

**File:** `Formatter/StructuredTextFormatter.swift`

Create a struct conforming to `TextFormatter`. Its `format` method:

1. Check if input is already formatted (has bullet chars `•` `-` `*` or numbered patterns `1.` `2.`). If so → return unchanged.
2. Run content analysis (TODO 2) to determine what type of structure to apply
3. Apply the matching structure formatter (TODO 3, 4, or 5)
4. If no pattern matches → return unchanged

---

## TODO 2: Content analysis — detect what kind of content this is

Run these checks IN ORDER. Use the FIRST one that matches.

### Check A — Explicit enumeration

Scan for sequence markers scattered through the text (case-insensitive):

**Ordered markers** (imply sequence/steps):
```
"first" / "firstly" / "first of all"
"second" / "secondly"
"third" / "thirdly"
"then" (at start of sentence or after comma)
"next"
"after that"
"finally" / "lastly" / "last"
"step one" / "step two" / "step three" (etc.)
"number one" / "number two" (etc.)
"start by"
```

**Unordered markers** (just listing):
```
"also"
"another" / "another thing"
"in addition"
"plus"
"on top of that"
```

**How to decide:**
- Count ordered markers found and unordered markers found
- If 3+ markers total found:
  - If majority are ordered → **numbered list**
  - If majority are unordered → **bullet list**
  - If tie → **bullet list** (safer default)

**Important:** Only count a marker if it appears at the START of a sentence (after a period) or at the very beginning of the text. "First base" in the middle of a sentence is not a list marker.

### Check B — Colon-list or trigger phrase list

Look for:
- A colon `:` followed by a comma-separated list
- OR one of these trigger phrases followed by a comma-separated list:
  ```
  "such as"
  "like" (when followed by a list — not "I like pizza")
  "including"
  "for example"
  "the following"
  ```

**Only match when** the comma-list goes to the END of the sentence. Mid-sentence lists stay inline.

How to detect "goes to end": after the colon or trigger phrase, if the remaining text until the period is a comma-separated list (pattern: `word/phrase, word/phrase, [and/or] word/phrase.`).

If found → **bullet list**

### Check C — Homogeneous short sentences

If ALL sentences (from `splitSentences`) are under 15 words AND there are 3+ sentences:

**Sub-check: are they imperative?**

Check if the first word of each sentence is likely an imperative verb. Simple heuristic — it's probably a verb if it is NOT:
- A pronoun: I, we, he, she, it, they, you, my, our, his, her, its, their
- An article: the, a, an
- A preposition: in, on, at, for, with, to, from, by, of, about
- A conjunction: and, but, or, so, yet
- A demonstrative: this, that, these, those
- A number word: one, two, first, second

If 60%+ of sentences start with a likely verb → **numbered list** (they're steps)
Otherwise → **bullet list**

### Check D — Sections (long grouped content)

Use `splitSentences`, then look for transition words (same list as in Phase 2: "also", "regarding", "on a different note", "however", etc.).

If the text can be split into 2-5 groups where:
- Each group has 2+ sentences
- Groups are separated by transition words

Then → **sections**

### Check E — No pattern

If none of the above match → return text unchanged.

### How to return the result

Create an enum for the analysis result:

```
enum ContentType {
    case bulletList(items: [String], preamble: String?)
    case numberedList(items: [String], preamble: String?)
    case sections(groups: [(heading: String, body: String)])
    case noChange
}
```

The analysis populates this with the extracted items/groups, so the formatting step doesn't need to re-parse.

---

## TODO 3: Bullet list formatting

Takes the analysis result (items + optional preamble) and builds the output.

### Rules

1. If preamble exists: output preamble, change its trailing period to a colon, add blank line
2. For each item:
   - Run `trimItem()` from Phase 1
   - Remove the sequence marker that triggered detection (e.g., strip "First, " from the start)
   - Prefix with `"- "`
3. Join items with newlines (single `\n`, not double)

### Markers to strip from items

When Check A or B detected items, the marker word needs to be removed from the item text:

```
Strip these from the START of each item:
"first, " / "firstly, " / "first of all, "
"second, " / "secondly, "
"third, " / "thirdly, "
"also, " / "also "
"another thing, " / "another thing is "
"in addition, "
"plus, " / "plus "
"next, " / "next "
"finally, " / "lastly, " / "last, "
"on top of that, "
```

For colon-lists (Check B), items are already clean (they're the comma-separated values).

### Test cases

**From Check A (unordered):**
```
Input:
"There are several issues. First, the navigation is confusing. Second, the contrast is poor. Also, the mobile layout breaks."

Expected:
"There are several issues:

- The navigation is confusing
- The contrast is poor
- The mobile layout breaks"
```

**From Check B (colon-list):**
```
Input:
"The stack includes: React, Node, PostgreSQL, and Redis."

Expected:
"The stack includes:

- React
- Node
- PostgreSQL
- Redis"
```

**From Check C (short sentences, unordered):**
```
Input:
"The header is too large. The font is hard to read. The colors clash."

Expected:
"- The header is too large
- The font is hard to read
- The colors clash"
```

---

## TODO 4: Numbered list formatting

Very similar to bullet list but with numbers and extra cleanup.

### Rules

1. Preamble handling: same as bullet list
2. For each item:
   - Run `trimItem()`
   - Strip sequence marker (same as TODO 3)
   - **Strip filler phrases** from the start:
     ```
     "you need to "
     "you should "
     "you have to "
     "you can "
     "you " (when followed by a verb — simplification: just strip "you " if it's the first word)
     "then " (at start)
     "after that "
     "next " (at start)
     "start by " → special case: rephrase. "Start by cloning" → "Clone"
     ```
   - Prefix with `"N. "` (sequential number)
3. Join items with newlines

### Handling "start by"

"Start by" is special because you need to convert the gerund (-ing form) to imperative:
- "start by cloning" → "Clone"
- "start by installing" → "Install"
- "start by running" → "Run"

Simple rule: remove "start by ", then if the first word ends in "ing", remove "ing" and add "e" (this works for most cases: cloning→clone, installing→installe... wait, that gives "installe" not "install").

Better rule: remove "start by " and remove trailing "ing" from the first word. Then check: if the word now ends in a double consonant (like "runn"), remove the last letter ("run"). If it ends in a vowel + consonant (like "clone" from "cloning" — wait, "cloning" minus "ing" = "clon", plus "e" = "clone").

Actually, this gerund-to-imperative conversion is fiddly. **Simplification for v1:** just remove "start by " and leave the gerund. "Cloning the repo" is fine as a step. You can revisit this later.

### Test cases

**From Check A (ordered):**
```
Input:
"Here's how to set up the project. First, clone the repo. Then install the dependencies. After that, create a dot env file. Finally, run the dev server."

Expected:
"Here's how to set up the project:

1. Clone the repo
2. Install the dependencies
3. Create a dot env file
4. Run the dev server"
```

**From Check C (imperative short sentences):**
```
Input:
"Open the terminal. Navigate to the project. Run npm install. Start the server."

Expected:
"1. Open the terminal
2. Navigate to the project
3. Run npm install
4. Start the server"
```

**"And then" chains:**
```
Input:
"You click the button and then enter your password and then click submit."

Expected:
"1. Click the button
2. Enter your password
3. Click submit"
```

For the "and then" chain: this is a SINGLE sentence. `splitSentences` won't help. You need a separate check: scan for "and then" within a sentence and split on it. Do this check inside the numbered list path when Check A found ordered markers within a single sentence.

---

## TODO 5: Section formatting

Takes groups of sentences and gives each group a heading.

### Rules

1. Each group becomes a section with a `##` heading
2. The heading is derived from the first sentence of the group
3. The body is all sentences in the group, joined with spaces

### Generating headings

This is the hardest part. Strategy:

1. Take the first sentence of the group
2. Look for a key subject noun phrase. Heuristic:
   - Find the first noun-like word (not a preposition, article, or verb-like word)
   - Take it and up to 2 following words
3. Capitalize as a title (first letter of each word uppercase)

**Simpler alternative for v1:** Use the first 2-4 "important" words from the first sentence. Remove articles ("the", "a", "an"), remove filler ("we need to", "I think", "it's about"). What's left is usually a decent heading.

**Simplest alternative:** Just use "Section 1", "Section 2", etc. Not great, but ships fast. You can improve heading generation later.

**Recommended for v1:** Try the "first important words" approach. If it's too hard, fall back to numbered sections.

### Example

```
Input:
"The authentication system needs an overhaul. Currently we're storing tokens in local storage which isn't compliant. We need HTTP-only cookies with CSRF protection. Regarding the API, we should switch from REST to GraphQL for the dashboard. The current REST setup requires too many round trips. On a different note, the deployment pipeline is too slow. Build times are over 15 minutes."

Expected:
"## Authentication

The authentication system needs an overhaul. Currently we're storing tokens in local storage which isn't compliant. We need HTTP-only cookies with CSRF protection.

## API

We should switch from REST to GraphQL for the dashboard. The current REST setup requires too many round trips.

## Deployment

The deployment pipeline is too slow. Build times are over 15 minutes."
```

### How I got those headings

- Group 1 starts with "The authentication system..." → key word: "Authentication"
- Group 2 starts with "Regarding the API..." → "Regarding" is a transition word, skip it → key phrase: "the API" → heading: "API"
- Group 3 starts with "On a different note, the deployment pipeline..." → skip transition → key phrase: "the deployment pipeline" → heading: "Deployment"

Pattern: skip transition words, skip articles, take the first noun/noun-phrase.

---

## TODO 6: Handle "and then" chains

This is a special case that doesn't fit neatly into the checks above.

A single sentence like:
```
"You click login and then enter your email and then click submit."
```

Won't be split by `splitSentences` (it's one sentence). But it's clearly a sequence of steps.

### Detection

After `splitSentences`, if you have a SINGLE sentence (or few sentences) that contain "and then" 2+ times → split on "and then" and format as numbered list.

Also check for: just "then" preceded by a comma: "click login, then enter email, then click submit."

### Where to put this

Run this check early in the analysis (before Check C). Or make it part of Check A — add "and then" as a sequence marker, but instead of splitting sentences, split WITHIN the sentence.

---

## TODO 7: Wire into engine + integration tests

Update `FormatterEngine` to route `.structure` to `StructuredTextFormatter`.

### Full integration tests

**Test 1: Enumerated bullets**
```
Input: "There are several issues with the design. First, the navigation is confusing. Second, the color contrast is poor. Third, the loading states are missing. Also, the mobile layout breaks."
Expected:
"There are several issues with the design:

- The navigation is confusing
- The color contrast is poor
- The loading states are missing
- The mobile layout breaks"
```

**Test 2: Ordered steps**
```
Input: "Here's how to deploy. First, build the project. Then push to main. Finally, check the CI pipeline."
Expected:
"Here's how to deploy:

1. Build the project
2. Push to main
3. Check the CI pipeline"
```

**Test 3: Colon-list**
```
Input: "The tech stack includes: React, Node.js, PostgreSQL, and Redis."
Expected:
"The tech stack includes:

- React
- Node.js
- PostgreSQL
- Redis"
```

**Test 4: Short imperative sentences**
```
Input: "Open the terminal. Navigate to the project folder. Run npm install. Start the server."
Expected:
"1. Open the terminal
2. Navigate to the project folder
3. Run npm install
4. Start the server"
```

**Test 5: Sections**
```
Input: "The auth system needs work. We're storing tokens wrong. It's a compliance issue. Regarding the API, we should move to GraphQL. REST has too many round trips. On a different note, the CI is slow. Builds take 15 minutes."
Expected:
"## Authentication

The auth system needs work. We're storing tokens wrong. It's a compliance issue.

## API

We should move to GraphQL. REST has too many round trips.

## CI

The CI is slow. Builds take 15 minutes."
```

**Test 6: "And then" chain**
```
Input: "You click the button and then enter your password and then click submit."
Expected:
"1. Click the button
2. Enter your password
3. Click submit"
```

**Test 7: Regular prose (no change)**
```
Input: "I had a great meeting with the client yesterday. They were really impressed with the demo and want to move forward with the project. I think we should start planning the next sprint."
Expected: (unchanged — it's prose, not a list)
```

**Test 8: Already formatted (no change)**
```
Input: "- Item one\n- Item two\n- Item three"
Expected: (unchanged — already formatted)
```

**Test 9: Single sentence**
```
Input: "Update the database."
Expected: "Update the database." (unchanged)
```

**Test 10: Empty**
```
Input: ""
Expected: ""
```

---

## Done checklist

- [ ] `StructuredTextFormatter` conforms to `TextFormatter`
- [ ] Content analysis correctly identifies: enumerated, colon-list, short sentences, sections, no-change
- [ ] Bullet list output is correctly formatted with preamble and trimmed items
- [ ] Numbered list output strips filler phrases and sequence markers
- [ ] Section output generates reasonable headings
- [ ] "And then" chains are detected and formatted
- [ ] Already-formatted text is returned unchanged
- [ ] Engine routes `.structure` to `StructuredTextFormatter`
- [ ] All 10 integration tests pass

Then move to [Phase 4 — Integration](formatter-phase4-integration.md).
