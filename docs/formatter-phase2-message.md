# Phase 2 — Message Formatter

> **Historical / retired (2026-10):** Format Selection and its exclusive formatter implementation were removed. This phase record is retained as engineering history.

**Goal:** Take dictated text intended for person-to-person communication (email, Slack, chat) and add proper structure.

**Depends on:** Phase 1 (engine + helpers must be working)

**When done:** `engine.format(text, style: .message)` transforms raw dictation into properly structured messages with greeting, paragraphs, and sign-off separated.

---

## Progress

- [ ] TODO 1: Create MessageFormatter (skeleton)
- [ ] TODO 2: extractGreeting
- [ ] TODO 3: extractSignOff
- [ ] TODO 4: structureBody
- [ ] TODO 5: Wire into engine
- [ ] TODO 6: All 6 integration tests passing

---

## The big picture

This formatter runs three passes, always in this order:

```
Raw text
  → Pass 1: Extract greeting from the start
  → Pass 2: Extract sign-off from the end
  → Pass 3: Structure the body (everything in between)
  → Reassemble: greeting + blank line + body + blank line + sign-off
```

---

## TODO 1: Create MessageFormatter

**File:** `Formatter/MessageFormatter.swift`

Create a struct (or class) that conforms to `TextFormatter`. Its `format` method will call the three passes in order and assemble the result.

Start with a skeleton:
1. Call `extractGreeting` → get greeting string + remaining text
2. Call `extractSignOff` on the remaining text → get sign-off string + body text
3. Call `structureBody` on the body text → get paragraphed body
4. Assemble: join non-nil parts with blank lines between them

### Assembly rules

- If greeting exists: greeting + `\n\n` + body
- If sign-off exists: body + `\n\n` + sign-off
- If both: greeting + `\n\n` + body + `\n\n` + sign-off
- If neither: just the structured body
- Empty input → return empty string
- Single sentence → return unchanged (nothing to structure)

---

## TODO 2: extractGreeting

**What it does:** Looks at the START of the text for a greeting pattern. Returns the greeting line and the remaining text.

**Return type:** A tuple or a small struct with two properties:
- `greeting: String?` — the formatted greeting line, or nil
- `remaining: String` — the rest of the text after the greeting

### Greeting patterns to match

All case-insensitive. Check in this order (longest first to avoid partial matches):

```
"good morning [NAME]"
"good afternoon [NAME]"
"good evening [NAME]"
"hello there"
"hey there"
"hi there"
"dear [NAME]"
"hello [NAME]"
"hey [NAME]"
"hi [NAME]"
"good morning"
"good afternoon"
"good evening"
"hello"
"hey"
"hi"
```

Where `[NAME]` is 0-3 words that follow the greeting word. A word counts as part of the name if:
- It starts with an uppercase letter (e.g., "John", "Maria", "Mr.")
- OR it's a title: "Mr.", "Mrs.", "Ms.", "Dr.", "Prof."

Stop capturing name words when you hit:
- A lowercase word (that's the body starting)
- A comma (the name is done, comma is the separator)
- A period
- More than 3 words captured

### Comma handling

After extracting the greeting + name:
- If the original text had a comma right after the name → include it
- If there was NO comma → add one

The greeting line always ends with a comma.

### Examples to test against

| Input | Greeting | Remaining |
|-------|----------|-----------|
| `"Hi Maria, I wanted to ask"` | `"Hi Maria,"` | `"I wanted to ask"` |
| `"Hi Maria I wanted to ask"` | `"Hi Maria,"` | `"I wanted to ask"` |
| `"Hey, quick question"` | `"Hey,"` | `"quick question"` |
| `"Dear Mr. Smith, thank you"` | `"Dear Mr. Smith,"` | `"thank you"` |
| `"Good morning, just checking in"` | `"Good morning,"` | `"just checking in"` |
| `"Good morning Anna, how are you"` | `"Good morning Anna,"` | `"how are you"` |
| `"Just wanted to let you know"` | `nil` | `"Just wanted to let you know"` |
| `"I said hi to her yesterday"` | `nil` | `"I said hi to her yesterday"` |

The last one is important: "hi" appears mid-text, not at the start. Only match greetings at position 0 of the text.

### How to implement

1. Trim the input
2. Try each greeting pattern against the start of the text (use `hasPrefix` or `lowercased().hasPrefix`)
3. If matched, skip past the greeting word(s)
4. Capture 0-3 name words (uppercase or title)
5. Skip comma if present
6. The rest is `remaining`
7. Format: greeting words + name words + comma

A straightforward approach: no regex needed. Just string prefix checking and word-by-word scanning.

---

## TODO 3: extractSignOff

**What it does:** Looks at the END of the text for a sign-off pattern. Returns the sign-off block and the body text.

**Return type:** Tuple or struct:
- `signOff: String?` — formatted sign-off (possibly multi-line with name), or nil
- `body: String` — everything before the sign-off

### Sign-off patterns to match

All case-insensitive:

```
"best regards"
"kind regards"
"warm regards"
"yours sincerely"
"yours truly"
"all the best"
"talk soon"
"speak soon"
"take care"
"many thanks"
"thanks a lot"
"thank you"
"regards"
"sincerely"
"thanks"
"cheers"
"best"
```

**Order matters.** Check longer phrases first. If you check "best" before "best regards", you'll match too early.

### Where to look

Only look in the **last 30 words** of the text. This prevents matching "thanks for the update" in the middle of a long message.

### The "thanks" problem

"Thanks" and "thank you" are tricky because they appear in normal sentences:
- "Thank you for the report" → NOT a sign-off (has content after it)
- "Thanks, Sebastian" → IS a sign-off
- "Thank you" at the very end → IS a sign-off

**Rule:** "Thanks" / "Thank you" is a sign-off ONLY when:
- It's followed by nothing (end of text), OR
- It's followed by only a comma and a name, OR
- It's followed by a period and nothing else

If there are 4+ words after "thanks" that aren't a name → it's not a sign-off.

### Name detection after sign-off

After the sign-off phrase, check if the remaining text (trimmed) is 1-3 capitalized words. If so, that's the sender's name. Put it on a separate line under the sign-off.

### Comma between sign-off and name

If the sign-off phrase is directly followed by a comma before the name ("Thanks, Sebastian"), include the comma on the sign-off line:
```
Thanks,
Sebastian
```

If no comma ("Best regards Sebastian"), still separate them:
```
Best regards,
Sebastian
```

Wait — actually for formal sign-offs without comma, don't add one. Different sign-offs have different conventions:
- "Thanks," / "Cheers," → comma feels natural
- "Best regards" → usually no comma before name, name goes on next line

**Simplification for v1:** Always put a comma after the sign-off if there's a name following. It's acceptable in all cases and simpler to implement.

### Examples to test against

| Input | Sign-off | Body |
|-------|----------|------|
| `"...let me know. Thanks, Sebastian"` | `"Thanks,\nSebastian"` | `"...let me know."` |
| `"...looks good. Best regards"` | `"Best regards"` | `"...looks good."` |
| `"...I appreciate it. Cheers"` | `"Cheers"` | `"...I appreciate it."` |
| `"...Thank you Anna Maria"` | `"Thank you,\nAnna Maria"` | `"..."` |
| `"Thank you for sending the report. I'll review it."` | `nil` | (full text unchanged) |
| `"...it works. Thanks a lot, Johan"` | `"Thanks a lot,\nJohan"` | `"...it works."` |
| `"Short message."` | `nil` | `"Short message."` |

### How to implement

1. Split text into words
2. If fewer than 2 words → return nil (too short to have a sign-off)
3. Take the last 30 words as the search area
4. Try each sign-off pattern (longest first) — search for it in the search area
5. If found, check what's after it: nothing? name? more content?
6. If it qualifies as a sign-off: extract it, format the sign-off block, return the body (everything before)

---

## TODO 4: structureBody

**What it does:** Takes the body text (greeting and sign-off already removed) and splits it into paragraphs.

### Rule 1 — Split on transition words

Look for these words/phrases at the **start of a sentence** (case-insensitive):

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
"however"
"that said"
"on the other hand"
```

**"Start of a sentence"** means: the word appears right after a period+space, or it's the first word of the body.

When found: insert a paragraph break (blank line) BEFORE that sentence. Keep the transition word — don't remove it.

### How to implement Rule 1

1. Use `splitSentences` from Phase 1 to get an array of sentences
2. Loop through the sentences
3. For each sentence, check if it starts with any transition phrase
4. Group sentences into paragraphs: start a new paragraph whenever a transition phrase is found
5. Join sentences within a paragraph with spaces
6. Join paragraphs with `\n\n`

### Rule 2 — Long text fallback

If Rule 1 produced zero paragraph breaks (no transition words found) AND the body has more than 4 sentences:
- Insert a paragraph break every 3 sentences

Why 3? It's the sweet spot for readability. Two feels choppy. Four starts to feel like a wall.

If the body is 1-4 sentences and no transitions → leave as a single paragraph. Short messages are fine.

### Rule 3 — Keep question clusters together

After applying Rule 1 or 2, check: if a paragraph break would fall between two sentences where:
- The first ends with `?`
- The second starts with "or ", "and ", "what about", "how about", "should I"

Then remove that paragraph break. Keep them together — they're part of the same question.

### Examples to test against

**Transition word split:**
```
Input body: "I reviewed the proposal and it looks solid. However, the timeline seems aggressive for the frontend work. Also, could you clarify the budget for external contractors?"

Output:
"I reviewed the proposal and it looks solid.

However, the timeline seems aggressive for the frontend work.

Also, could you clarify the budget for external contractors?"
```

**Long text fallback (no transitions, 6 sentences):**
```
Input body: "The server migration is complete. Database performance has improved by 40%. All endpoints are responding within SLA. The monitoring dashboards are updated. SSL certificates have been renewed. Documentation has been published to the wiki."

Output:
"The server migration is complete. Database performance has improved by 40%. All endpoints are responding within SLA.

The monitoring dashboards are updated. SSL certificates have been renewed. Documentation has been published to the wiki."
```

**Short text (no change):**
```
Input body: "The deployment went fine. Tests are green."

Output:
"The deployment went fine. Tests are green."
```

**Question cluster (kept together):**
```
Input body: "Do you have the staging API keys? Or should I ask DevOps? Let me know when you can."

Output:
"Do you have the staging API keys? Or should I ask DevOps?

Let me know when you can."
```

Wait — that actually split. Let me reconsider. "Let me know" is a separate thought from the question. The question cluster is the first two sentences. The third is a separate closing remark. So the split IS correct here. Rule 3 kept "Do you have...?" and "Or should I...?" together, then Rule 2 or just natural break separated the closing.

---

## TODO 5: Wire it into the engine

Go back to `FormatterEngine.swift` and replace the `.message` stub with an actual `MessageFormatter` call.

---

## TODO 6: Full integration tests

Test the complete `MessageFormatter.format()` with these end-to-end inputs:

### Test 1: Full email
```
Input:
"Hi Maria, I wanted to follow up on our meeting yesterday. The project timeline looks good but we need to adjust the budget for Q3. Also, could you send me the updated spreadsheet when you get a chance? I need it for the board presentation on Friday. Thanks, Sebastian"

Expected:
"Hi Maria,

I wanted to follow up on our meeting yesterday. The project timeline looks good but we need to adjust the budget for Q3.

Also, could you send me the updated spreadsheet when you get a chance? I need it for the board presentation on Friday.

Thanks,
Sebastian"
```

### Test 2: No greeting, with sign-off
```
Input:
"Just wanted to let you know the deployment went smoothly. All tests are passing and the client confirmed it's working. Cheers"

Expected:
"Just wanted to let you know the deployment went smoothly. All tests are passing and the client confirmed it's working.

Cheers"
```

### Test 3: Formal email
```
Input:
"Dear Mr. Johnson, thank you for your prompt response regarding the contract terms. We've reviewed the amendments and are in agreement with sections one through four. However, we have concerns about the liability clause in section five. Regarding the timeline, we would prefer to push the signing date to next Friday to give our legal team time to review. Additionally, could you confirm whether the non-compete terms apply to all subsidiaries or only the parent company? We look forward to resolving these final points. Kind regards, Sebastian Strandberg"

Expected:
"Dear Mr. Johnson,

Thank you for your prompt response regarding the contract terms. We've reviewed the amendments and are in agreement with sections one through four.

However, we have concerns about the liability clause in section five.

Regarding the timeline, we would prefer to push the signing date to next Friday to give our legal team time to review.

Additionally, could you confirm whether the non-compete terms apply to all subsidiaries or only the parent company?

We look forward to resolving these final points.

Kind regards,
Sebastian Strandberg"
```

### Test 4: Quick question
```
Input:
"Hey, quick question. Do you have the API keys for the staging environment? Or should I ask DevOps? Let me know when you can. Thanks"

Expected:
"Hey,

Quick question. Do you have the API keys for the staging environment? Or should I ask DevOps?

Let me know when you can.

Thanks"
```

### Test 5: Bare message (no greeting, no sign-off, short)
```
Input:
"The build is broken on main. Can you take a look?"

Expected:
"The build is broken on main. Can you take a look?"
```
(unchanged — too short to need paragraph breaks)

### Test 6: Empty string
```
Input: ""
Expected: ""
```

---

## Done checklist

- [ ] `MessageFormatter` conforms to `TextFormatter`
- [ ] `extractGreeting` handles all patterns, comma logic, name capture
- [ ] `extractSignOff` handles all patterns, name detection, the "thanks" problem
- [ ] `structureBody` splits on transition words, falls back to every-3-sentences, keeps question clusters
- [ ] Engine routes `.message` to `MessageFormatter`
- [ ] All 6 integration tests pass
- [ ] Edge cases: empty input, single sentence, no greeting, no sign-off, both missing

Then move to [Phase 3 — Structured Text Formatter](formatter-phase3-structure.md).
