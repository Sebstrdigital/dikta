"""Tolerant parser for raw LLM debrief output.

Port of `DebriefSummaryParser` (`Services/Debrief/DebriefSummarizer.swift:236-291`).
Handles code-fenced JSON and leading/trailing prose ("chatter") around the
JSON object, and defaults missing optional array keys to `[]` — but is
otherwise a strict JSON decode of the required `summary` field. Untrusted
by construction: any deviation from the expected shape raises `BadResponse`
rather than guessing.
"""

from __future__ import annotations

import json
import re

from pydantic import ValidationError

from dikta.core.debrief.errors import BadResponse
from dikta.core.debrief.model import ActionItem, DebriefSummary

__all__ = ["parse_summary"]

_FENCE_LINE = re.compile(r"^```")
_EXCERPT_LENGTH = 200


def _array_or_default(data: dict, key: str, excerpt: str) -> list:
    """Extract `data[key]` as a JSON array, defaulting to `[]` for a missing
    key or explicit JSON `null`.

    Mirrors Swift `JSONDecoder` decoding a `[String]?`/`[DebriefActionItem]?`
    DTO field (spec section 2): only a missing key or JSON `null` defaults to
    `[]`; any other non-array JSON value (string, object, bool, number) is a
    type mismatch that throws in Swift, so it raises `BadResponse` here too.
    Using `isinstance(value, list)` (rather than `value or []`, which is
    falsy-based) matters: a falsy-but-present value like `false`/`0` must
    still raise, and a truthy string/object must never be blindly iterated
    into characters/keys via `list(value)`.
    """
    if key not in data or data[key] is None:
        return []
    value = data[key]
    if not isinstance(value, list):
        raise BadResponse(excerpt)
    return value


def _strip_code_fence(text: str) -> str:
    """Drop every line starting with a code fence marker, wherever it occurs.

    Mirrors step 2 of `parse` (`DebriefSummarizer.swift:243-246`): both the
    opening ` ```json ` and closing ` ``` ` lines are removed, not just the
    first/last line.
    """
    if not text.startswith("```"):
        return text
    lines = [line for line in text.split("\n") if not _FENCE_LINE.match(line)]
    return "\n".join(lines).strip()


def parse_summary(raw: str) -> DebriefSummary:
    """Parse `raw` LLM output into a normalized `DebriefSummary`.

    The returned summary has already been passed through `.normalized()`
    (mirrors `DebriefSummaryDTO.toDebriefSummary()`,
    `DebriefSummarizer.swift:281-289` — the parser's output is normalized
    even for callers that never call `.normalized()` themselves).

    Raises:
        BadResponse: `raw` has no parseable `{...}` JSON object, or the
            JSON fails to decode into the expected shape (missing/non-string
            `summary`, malformed `actionItems` entries, etc). The excerpt on
            the error is always `raw[:200]` from the original, untrimmed
            input.
    """
    excerpt = raw[:_EXCERPT_LENGTH]
    text = _strip_code_fence(raw.strip())

    first_brace = text.find("{")
    last_brace = text.rfind("}")
    if first_brace == -1 or last_brace == -1 or first_brace > last_brace:
        raise BadResponse(excerpt)

    candidate = text[first_brace : last_brace + 1]
    try:
        candidate.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise BadResponse(excerpt) from exc

    try:
        data = json.loads(candidate)
    except json.JSONDecodeError as exc:
        raise BadResponse(excerpt) from exc

    if not isinstance(data, dict) or not isinstance(data.get("summary"), str):
        raise BadResponse(excerpt)

    try:
        action_items_raw = _array_or_default(data, "actionItems", excerpt)
        # Element-level type mismatches (e.g. `text` not a string, an
        # element that isn't an object at all) are caught below: a
        # non-dict element fails at `item["text"]`/`item.get(...)` with
        # TypeError, and a wrong-typed `text`/`owner`/`due` value fails
        # `ActionItem`'s own str-typed fields with ValidationError — pydantic
        # does not coerce non-strings, matching spec section 2's "no custom
        # coercion" rule.
        action_items = [
            ActionItem(text=item["text"], owner=item.get("owner"), due=item.get("due"))
            for item in action_items_raw
        ]
        summary = DebriefSummary(
            summary=data["summary"],
            decisions=_array_or_default(data, "decisions", excerpt),
            actionItems=action_items,
            openQuestions=_array_or_default(data, "openQuestions", excerpt),
        )
    except (KeyError, TypeError, ValidationError) as exc:
        raise BadResponse(excerpt) from exc

    return summary.normalized()
