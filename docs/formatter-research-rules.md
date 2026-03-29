# Deterministic Formatter — Research-Backed Detection Rules

Research compiled 2026-03-29 from linguistics literature (Schiffrin, Maschler), Purdue OWL, Google Developer Style Guide, Wikipedia (discourse markers, conversation analysis, filler words, valediction, salutation, postscript).

---

## 1. Paragraph Splitting in Natural Speech/Dictation

### 1A. Discourse Marker Topic Shifts

Linguistics classifies discourse markers into four categories (Maschler): **interpersonal**, **referential**, **structural**, **cognitive**. For paragraph splitting, only **structural** markers matter — they signal segment boundaries.

**Hard break markers** (sentence-initial, signal new topic):
| Marker | Regex pattern (sentence-initial) | Confidence |
|--------|----------------------------------|------------|
| `anyway` | `^Anyway[,.]?\s` | High |
| `so` | `^So[,]?\s` (only when NOT followed by "that") | Medium |
| `by the way` | `^By the way[,]?\s` | High |
| `speaking of which` | `^Speaking of (which\|that)[,]?\s` | High |
| `on another note` | `^On another note[,]?\s` | High |
| `moving on` | `^Moving on[,.]?\s` | High |
| `oh and` | `^Oh and[,]?\s` | High |
| `one more thing` | `^One more thing[,:]?\s` | High |
| `also` | `^Also[,]?\s` | Medium |
| `alright` | `^Alright[,.]?\s` | Medium |
| `okay so` | `^Okay so[,]?\s` | High |
| `now` | `^Now[,]?\s` (only when NOT temporal — heuristic: no time word in next 5 tokens) | Low |
| `incidentally` | `^Incidentally[,]?\s` | High |
| `before I forget` | `^Before I forget[,]?\s` | High |
| `oh` | `^Oh[,]?\s` (only when followed by a different subject than prior sentence) | Low |
| `well` | `^Well[,]?\s` (only sentence-initial and NOT "well-known" etc.) | Low |
| `right` | `^Right[,.]?\s` (only when standalone interjection, not adjective) | Low |

**NOT break markers** (these are continuation/hedging, NOT topic shifts):
- `you know`, `I mean`, `like`, `basically`, `actually` — these are **cognitive/interpersonal** markers that maintain the current topic
- `and`, `but`, `or`, `because`, `so that` — these are **connectives** that link within a topic

### 1B. Question-Based Topic Shifts

**Rule:** A question that introduces a new subject entity (noun/pronoun not mentioned in the prior 2 sentences) signals a paragraph break.

Detectable patterns (sentence-initial):
| Pattern | Example |
|---------|---------|
| `^How about\s` | "How about the budget?" |
| `^What about\s` | "What about parking?" |
| `^What do you think (about\|of)\s` | "What do you think about the timeline?" |
| `^Have you (considered\|thought about)\s` | "Have you considered the risks?" |
| `^Do you know (about\|if)\s` | "Do you know about the new policy?" |
| `^Can (we\|you)\s` | "Can we discuss the contract?" |
| `^Should (we\|I)\s` | "Should we revisit the pricing?" |
| `^What('s\| is) (the\|your)\s` | "What's the status on hiring?" |
| `^How (is\|are\|was\|were)\s` | "How is the project going?" |

**Exception:** Questions that are rhetorical continuations of the same topic do NOT break. Heuristic: if the question's subject noun appeared in the prior sentence, it's a continuation.

### 1C. Subject/Pronoun Shifts

**Rule (Purdue OWL — "verbal bridges"):** Paragraphs maintain coherence through repeated key words, synonyms, and pronoun references. When these bridges break, a new paragraph is warranted.

Detectable heuristic:
1. Track the **primary subject** of each sentence (first noun phrase before the verb).
2. If the subject changes AND no discourse connective links them AND no pronoun refers back to the prior subject, insert a paragraph break.
3. Exception: Lists of parallel statements about different items that share a common predicate pattern are NOT paragraph breaks.

**Practical simplification for deterministic code:** Only fire this rule when:
- 3+ consecutive sentences share a subject, then the subject changes
- The new subject was not mentioned anywhere in the prior paragraph

### 1D. Professional Transcript Editing Conventions

Editors use these heuristics (synthesized from Purdue OWL and discourse analysis):
1. **One idea per paragraph** — the atomic rule.
2. **New paragraph when contrasting** — "but", "however", "on the other hand" at sentence start after 2+ sentences on one side.
3. **New paragraph for reader's breath** — if a paragraph exceeds ~5 sentences in conversational text, break at the next natural pause.
4. **New paragraph at conclusions/summaries** — sentences starting with "In summary", "To sum up", "The bottom line is", "Overall".

---

## 2. List Detection in Natural Speech

### 2A. Explicit Ordinal Lists (Numbered)

**Rule:** Use **numbered** list when sequence/order/priority matters (Google Dev Style Guide).

Detection patterns — any of these at sentence start trigger list-item detection:

| Pattern | Regex | List type |
|---------|-------|-----------|
| Ordinals | `^(First\|Second\|Third\|Fourth\|Fifth\|Sixth\|Seventh\|Eighth\|Ninth\|Tenth)[,:]?\s` | Numbered |
| Cardinal ordinals | `^Number (one\|two\|three\|four\|five\|six\|seven\|eight\|nine\|ten)[,:]?\s` | Numbered |
| Lettered | `^(A\|B\|C\|D\|E)[,.):]?\s` (only when 2+ consecutive) | Numbered |
| Step-based | `^Step (one\|two\|three\|\d+)[,:]?\s` | Numbered |
| Next/Then chains | `^(Next\|Then\|After that\|Finally\|Lastly)[,]?\s` (when following an ordinal-started item) | Numbered |

**Termination:** A list ends when a sentence does NOT match any continuation pattern AND the subject shifts.

### 2B. Implicit Lists (Bulleted)

**Rule:** Use **bulleted** list when items are unordered/non-sequential (Google Dev Style Guide).

Detection heuristics:
1. **Parallel structure** — 3+ consecutive sentences that share the same syntactic skeleton (same verb, same sentence length within 30%, same opening pattern).
   - Example: "We need milk. We need eggs. We need flour." -> bulleted list
2. **Anaphoric repetition** — 3+ sentences starting with the same word/phrase.
   - Example: "Make sure the door is locked. Make sure the windows are closed. Make sure the alarm is set."
3. **Conjunction chains** — A sentence containing 3+ items joined by commas and "and"/"or".
   - Example: "Bring a laptop, a notebook, a pen, and your ID." -> bulleted list (inline or expanded)

### 2C. Colon-Style Introduction + Items

**Detection rule:** A sentence ending with a colon (`:`) or containing "the following", "these things", "a few things", "there are [N] things" signals the NEXT content should be list items.

**Introductory sentence patterns:**
| Pattern | Example |
|---------|---------|
| `there are \d+ (things\|items\|points\|reasons\|steps)` | "There are three things I want to cover" |
| `(here\|these) are (the\|some\|a few)` | "Here are the requirements" |
| `I (need\|want) (you\|to) .* (following\|these)` | "I need you to do the following" |
| `(a few\|several\|some\|three\|four) (things\|points\|items\|reasons)` at sentence end | "I have a few things" |
| Sentence ends with colon | "Please bring the following:" |

**After introduction:** Subsequent sentences/clauses that match parallel structure or ordinals become list items. The intro sentence becomes the list's lead-in paragraph.

### 2D. Numbered vs Bulleted Decision Rules

| Condition | List type |
|-----------|-----------|
| Explicit ordinals (first/second/third, step 1/2/3, number one/two) | **Numbered** |
| Order matters (chronological steps, priority, sequence) | **Numbered** |
| Items are interchangeable / no inherent order | **Bulleted** |
| Mixed detection with no ordinals but parallel structure | **Bulleted** |
| Fewer than 3 items detected | **Not a list** — keep as prose |
| Single item | **Never a list** (Google Dev Style Guide: "a single item isn't really a list") |

### 2E. Mixed Content: Preamble + List

**Rule:** When a list is detected, all non-list sentences before the first item that relate to the list topic become a **preamble paragraph**. The preamble ends and the list begins at the first list item.

Structure:
```
[Preamble paragraph]

- Item 1
- Item 2
- Item 3

[Continuation paragraph after list]
```

---

## 3. Email/Message Formatting Edge Cases

### 3A. Greeting Detection

**Formal greetings** (followed by comma or colon, then body):
| Pattern | Register |
|---------|----------|
| `^Dear (Mr\.\|Mrs\.\|Ms\.\|Dr\.\|Prof\.\|Sir\|Madam\|[A-Z][a-z]+)[,:]?` | Formal |
| `^To whom it may concern[,:]?` | Formal |
| `^Good (morning\|afternoon\|evening)[,]?` | Semi-formal |
| `^Hello[,]?\s*[A-Z]?` | Semi-formal |
| `^Hi[,]?\s*[A-Z]?` | Casual |
| `^Hey[,]?\s*[A-Z]?` | Casual |
| `^Greetings[,]?` | Formal |
| `^Hej[,]?\s*[A-Z]?` | Swedish casual |
| `^Hejsan[,]?` | Swedish casual |

**Rule:** Greeting line is ALWAYS its own paragraph (separated from body by blank line).

**No greeting:** If the first sentence matches none of the above, the message has no greeting. Start directly with body paragraph. Do NOT invent a greeting.

### 3B. Sign-off / Valediction Detection

**Patterns** (must appear as final 1-3 lines of message):
| Pattern | Register |
|---------|----------|
| `^(Yours truly\|Very truly yours\|Respectfully yours)[,]?` | Formal |
| `^(Sincerely\|Sincerely yours)[,]?` | Formal |
| `^(Best regards\|Kind regards\|Warm regards\|Regards)[,]?` | Semi-formal |
| `^(Best\|Best wishes\|All the best\|Cheers\|Thanks\|Thank you\|Many thanks)[,]?` | Casual |
| `^(Take care\|Talk soon\|See you\|Later\|Bye)[,]?` | Casual |
| `^(Cordially\|Respectfully\|Faithfully)[,]?` | Formal |
| `^(Med v.nliga h.lsningar\|Mvh\|H.lsningar\|Tack)[,]?` | Swedish |

**Rule:** Sign-off + name is ALWAYS its own paragraph block at the end, separated from body.

**Structure when both greeting and sign-off present:**
```
[Greeting line]

[Body paragraph(s)]

[Sign-off],
[Name]
```

**No sign-off:** If no valediction pattern matches in the final lines, end with the last body paragraph. Do NOT invent a sign-off.

### 3C. Very Short Messages (1-2 Sentences)

**Rules:**
1. If 1 sentence with greeting + body: `Greeting\n\nBody sentence.`
2. If 1 sentence, no greeting, no sign-off: Output as single paragraph (no structural formatting).
3. If 2 sentences, same topic: Single paragraph.
4. If 2 sentences, different topics (detected via subject shift): Two paragraphs.
5. Never create a list from fewer than 3 items.

### 3D. Messages That Are Entirely Questions

**Rules:**
1. If all sentences are questions about the same subject: Single paragraph.
2. If questions address different subjects: One paragraph per subject cluster.
3. Questions preceded by a preamble statement: Preamble paragraph + questions paragraph.
4. Never convert questions into list items (questions are not parallel-structured data items).

### 3E. Formal vs Casual Register Detection

**Heuristic scoring:**

| Signal | Points toward Formal | Points toward Casual |
|--------|---------------------|---------------------|
| Greeting is "Dear..." | +2 | |
| Greeting is "Hey" | | +2 |
| Contractions present | | +1 each (max 3) |
| No contractions in 3+ sentences | +2 | |
| Valediction is "Sincerely/Respectfully" | +2 | |
| Valediction is "Cheers/Thanks/Later" | | +2 |
| Sentence avg length > 20 words | +1 | |
| Sentence avg length < 10 words | | +1 |
| Exclamation marks present | | +1 each (max 2) |

**Score:** Formal >= 3, Casual >= 3, otherwise Neutral.

**Impact:** Register does NOT change formatting structure. It affects:
- Whether to preserve contractions (always preserve dictated contractions)
- Whether single-word sign-offs get a comma (formal: yes, casual: optional)

### 3F. Postscript (P.S.) Sections

**Detection patterns:**
| Pattern | Regex |
|---------|-------|
| Standard | `^P\.?S\.?\s` |
| With dash | `^P\.?S\.?\s*[-:]\s` |
| Spoken | `^(PS\|P S\|post script\|postscript)[,:]?\s` |
| Multiple | `^P\.?P\.?S\.?\s` (post-post-scriptum) |

**Rules:**
1. P.S. is ALWAYS separated from sign-off by a blank line.
2. P.S. is ALWAYS the final structural element (after sign-off + name).
3. Normalize spoken "post script" to "P.S."
4. P.S. content stays as a single paragraph regardless of length.
5. Multiple P.S. sections (P.S., P.P.S.) each get their own line with blank line separation.

**Structure:**
```
[Body]

[Sign-off],
[Name]

P.S. [content]
```

---

## 4. Composite Rules for Test Case Design

### 4A. Priority Order for Detection

When multiple rules could fire, apply in this order:
1. **Greeting detection** (first line only)
2. **Sign-off detection** (last 1-3 lines)
3. **P.S. detection** (after sign-off)
4. **List detection** (intro sentence + items)
5. **Paragraph splitting** (discourse markers, subject shifts, length)

### 4B. Minimum Thresholds

| Metric | Threshold |
|--------|-----------|
| Min items for a list | 3 |
| Max paragraph length before forced break | 5 sentences (conversational) / 7 sentences (formal) |
| Min sentences to detect parallel structure | 3 consecutive |
| Min confidence for paragraph break on discourse marker | Medium (skip Low unless combined with subject shift) |

### 4C. Test Case Categories (100 cases)

Suggested distribution for comprehensive coverage:

| Category | Count | Coverage |
|----------|-------|----------|
| Paragraph splitting — discourse markers | 15 | All High/Medium markers, edge cases with Low |
| Paragraph splitting — question shifts | 10 | Each question pattern, rhetorical exceptions |
| Paragraph splitting — subject shifts | 8 | 3+ sentence runs, entity tracking |
| Paragraph splitting — length-based breaks | 5 | 5-sentence threshold, formal vs casual |
| List detection — explicit ordinals | 10 | first/second, number one, step N, mixed |
| List detection — implicit parallel | 8 | Anaphoric, structural, conjunction chains |
| List detection — intro sentence + items | 7 | Colon, "there are N things", "the following" |
| List detection — numbered vs bulleted | 5 | Decision boundary cases |
| Email — greeting + sign-off combos | 10 | All register levels, Swedish, missing parts |
| Email — short messages | 7 | 1-sentence, 2-sentence, question-only |
| Email — P.S. handling | 5 | Spoken, normalized, P.P.S., no sign-off + P.S. |
| Email — register detection | 5 | Formal, casual, mixed signals |
| Composite / integration | 5 | Greeting + list + sign-off + P.S. in one message |
| **Total** | **100** | |
