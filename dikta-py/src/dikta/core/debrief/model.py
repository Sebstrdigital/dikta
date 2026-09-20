"""DebriefSummary / ActionItem — the domain model for a meeting debrief.

Port of ``Models/DebriefSummary.swift`` from the macOS app. Both types are
frozen (immutable) and support round-tripping through JSON via
`to_json`/`from_json`, matching Swift's strict `Codable` conformance used
for internal persistence. The *tolerant* decoding of untrusted LLM output
is a separate concern — see `dikta.core.debrief.parser`.
"""

from __future__ import annotations

import re
import unicodedata
from datetime import date, datetime
from typing import Self

from pydantic import BaseModel, ConfigDict, Field

__all__ = ["ActionItem", "DebriefSummary"]

#: Placeholder values that mean "nothing was actually specified" for
#: owner/due, and (via `_EMPTY_CONTENT_PLACEHOLDERS`) for decision/action/
#: open-question text. Mirrors `DebriefActionItem.placeholderValues`
#: (Models/DebriefSummary.swift:16-33).
_PLACEHOLDER_VALUES: frozenset[str] = frozenset(
    {
        "not specified",
        "tbd",
        "n/a",
        "na",
        "none",
        "unknown",
        "null",
        "ingen",
        "ingen specificerad",
        "ingen angiven",
        "ej angivet",
        "ej specificerat",
        "okänd",
        "-",
        "–",
        "—",
    }
)

#: Generic collective owners that don't identify an actual person.
#: Mirrors `DebriefActionItem.genericOwnerPlaceholders`
#: (Models/DebriefSummary.swift:39-46). Only applied to `owner`, never
#: `due` — a real due date could coincidentally contain one of these words.
_GENERIC_OWNER_PLACEHOLDERS: frozenset[str] = frozenset(
    {"team", "the team", "everyone", "all", "teamet", "alla"}
)

#: `_PLACEHOLDER_VALUES` plus the Swedish plural "inga" ("none"), applied
#: to whole decision/action/question text. Mirrors
#: `emptyContentPlaceholders` (Models/DebriefSummary.swift:240).
_EMPTY_CONTENT_PLACEHOLDERS: frozenset[str] = _PLACEHOLDER_VALUES | {"inga"}

#: Edge punctuation trimmed (with whitespace) from owner/due fields.
#: Mirrors the punctuation set at Models/DebriefSummary.swift:51.
_EDGE_PUNCTUATION = ".,;:"

#: First-person self-reference forms exempted from owner fabrication
#: checks. Mirrors `firstPersonOwners` (Models/DebriefSummary.swift:141-144).
_FIRST_PERSON_OWNERS: frozenset[str] = frozenset({"me", "i", "myself", "jag", "mig", "själv"})

_ISO_DATE_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}")
_FOUR_DIGIT_YEAR_PATTERN = re.compile(r"\b\d{4}\b")


def _trim_edge_punctuation(value: str) -> str:
    """Strip whitespace and `_EDGE_PUNCTUATION` repeatedly from both ends.

    Mirrors `trimmedOfEdgePunctuation` (Models/DebriefSummary.swift:55-67).
    """
    value = value.strip()
    while value and value[0] in _EDGE_PUNCTUATION:
        value = value[1:].strip()
    while value and value[-1] in _EDGE_PUNCTUATION:
        value = value[:-1].strip()
    return value


def _normalized_field(
    value: str | None, *, extra_placeholders: frozenset[str] = frozenset()
) -> str | None:
    """Normalize a single owner/due field.

    Mirrors `normalizedField(_:extraPlaceholders:)`
    (Models/DebriefSummary.swift:71-79).
    """
    if value is None:
        return None
    trimmed = _trim_edge_punctuation(value)
    if not trimmed:
        return None
    lowered = trimmed.lower()
    if lowered in _PLACEHOLDER_VALUES or lowered in extra_placeholders:
        return None
    return trimmed


def _is_empty_or_placeholder(text: str) -> bool:
    """Mirrors `isEmptyOrPlaceholder` (Models/DebriefSummary.swift:244-248)."""
    trimmed = text.strip()
    if not trimmed:
        return True
    return trimmed.lower() in _EMPTY_CONTENT_PLACEHOLDERS


def _strip_punctuation(text: str) -> str:
    """Remove every Unicode punctuation character (category "P*").

    Mirrors stripping `CharacterSet.punctuationCharacters`.
    """
    return "".join(ch for ch in text if not unicodedata.category(ch).startswith("P"))


def _dedupe_key(text: str) -> str:
    """Mirrors `DebriefActionItem.dedupeKey` (Models/DebriefSummary.swift:84-88)."""
    return _strip_punctuation(text.lower()).strip()


def _similarity_tokens(text: str) -> set[str]:
    """Tokenize for paraphrase detection: lowercase, strip punctuation, split
    on any whitespace, keep tokens of length >= 3.

    Mirrors `similarityTokens` (Models/DebriefSummary.swift:207-211).
    """
    stripped = _strip_punctuation(text.lower())
    return {token for token in stripped.split() if len(token) >= 3}


def _is_paraphrase(a: str, b: str) -> bool:
    """Jaccard similarity of `_similarity_tokens(a)`/`_similarity_tokens(b)` >= 0.75.

    Mirrors `isParaphrase` (Models/DebriefSummary.swift:222-229). Requires
    at least 3 tokens on each side, guarding short strings against a
    high Jaccard score by chance.
    """
    tokens_a = _similarity_tokens(a)
    tokens_b = _similarity_tokens(b)
    if min(len(tokens_a), len(tokens_b)) < 3:
        return False
    union = tokens_a | tokens_b
    if not union:
        return False
    intersection = tokens_a & tokens_b
    return len(intersection) / len(union) >= 0.75


def _is_capitalized_single_word(value: str) -> bool:
    """Mirrors `isCapitalizedSingleWord` (Models/DebriefSummary.swift:126-129)."""
    if not value or any(ch.isspace() for ch in value):
        return False
    return value[0].isupper()


def _contains_whole_word(haystack: str, word: str) -> bool:
    """Case-insensitive whole-word substring search.

    Mirrors `containsWholeWord` (Models/DebriefSummary.swift:115-121).
    """
    pattern = r"\b" + re.escape(word) + r"\b"
    return re.search(pattern, haystack, flags=re.IGNORECASE) is not None


class ActionItem(BaseModel):
    """A single follow-up task extracted from a debrief transcript."""

    model_config = ConfigDict(frozen=True, populate_by_name=True)

    text: str
    owner: str | None = None
    due: str | None = None

    def normalized(self) -> ActionItem:
        """Trim and placeholder-strip `owner`/`due`.

        Mirrors `DebriefActionItem.normalized()`
        (Models/DebriefSummary.swift:90-98).
        """
        return self.model_copy(
            update={
                "owner": _normalized_field(
                    self.owner, extra_placeholders=_GENERIC_OWNER_PLACEHOLDERS
                ),
                "due": _normalized_field(self.due),
            }
        )

    def validated(self, transcript: str) -> ActionItem:
        """Null out `due`/`owner` values that look fabricated against `transcript`.

        Not a general fact-checker — only catches two narrow shapes (an
        ISO-date/4-digit-year `due` absent from the transcript; a
        capitalized single-word `owner` absent from the transcript). Mirrors
        `DebriefActionItem.validated(against:)`
        (Models/DebriefSummary.swift:172-189).
        """
        due = self.due
        if due is not None:
            match = _ISO_DATE_PATTERN.search(due) or _FOUR_DIGIT_YEAR_PATTERN.search(due)
            if match is not None and match.group(0).lower() not in transcript.lower():
                due = None

        owner = self.owner
        if (
            owner is not None
            and owner.lower() not in _FIRST_PERSON_OWNERS
            and _is_capitalized_single_word(owner)
            and not _contains_whole_word(transcript, owner)
        ):
            owner = None

        if due == self.due and owner == self.owner:
            return self
        return self.model_copy(update={"due": due, "owner": owner})


class DebriefSummary(BaseModel):
    """A structured meeting debrief: summary, decisions, action items, and open questions."""

    model_config = ConfigDict(frozen=True, populate_by_name=True)

    summary: str
    decisions: list[str] = Field(default_factory=list)
    action_items: list[ActionItem] = Field(default_factory=list, alias="actionItems")
    open_questions: list[str] = Field(default_factory=list, alias="openQuestions")

    def normalized(self) -> DebriefSummary:
        """Drop empty/placeholder entries and dedupe decisions against action items.

        Mirrors `DebriefSummary.normalized()` (Models/DebriefSummary.swift:264-282).
        Order is preserved throughout; no re-sorting.
        """
        normalized_items = [item.normalized() for item in self.action_items]
        surviving_items = [
            item for item in normalized_items if not _is_empty_or_placeholder(item.text)
        ]
        action_item_keys = {_dedupe_key(item.text) for item in surviving_items}

        surviving_decisions: list[str] = []
        for decision in self.decisions:
            if _is_empty_or_placeholder(decision):
                continue
            if _dedupe_key(decision) in action_item_keys:
                continue
            if any(_is_paraphrase(decision, item.text) for item in surviving_items):
                continue
            surviving_decisions.append(decision)

        surviving_questions = [q for q in self.open_questions if not _is_empty_or_placeholder(q)]

        return DebriefSummary(
            summary=self.summary,
            decisions=surviving_decisions,
            actionItems=surviving_items,
            openQuestions=surviving_questions,
        )

    def validated(self, transcript: str) -> DebriefSummary:
        """Apply `ActionItem.validated` to every action item; other fields pass through.

        Mirrors `DebriefSummary.validated(against:)` (Models/DebriefSummary.swift:289-296).
        """
        return DebriefSummary(
            summary=self.summary,
            decisions=self.decisions,
            actionItems=[item.validated(transcript) for item in self.action_items],
            openQuestions=self.open_questions,
        )

    def render_plain_text(self, language: str, date: datetime | date | None = None) -> str:
        """Render as plain text for `summary.txt`. See `dikta.core.debrief.render`.

        `date` defaults to the local current date/time when omitted.
        """
        from dikta.core.debrief.render import render_plain_text as _render_plain_text

        return _render_plain_text(self, language, date=date)

    def to_json(self) -> str:
        """Strict JSON encoding (by alias), for internal round-tripping/persistence."""
        return self.model_dump_json(by_alias=True)

    @classmethod
    def from_json(cls, text: str) -> Self:
        """Strict JSON decoding — the inverse of `to_json`, NOT the tolerant LLM-output parser."""
        return cls.model_validate_json(text)
