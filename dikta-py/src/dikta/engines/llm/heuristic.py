"""Deterministic, non-LLM debrief summarizer.

Port of `HeuristicDebriefSummarizer`
(`Services/Debrief/HeuristicDebriefSummarizer.swift`). Buckets transcript
segments into decisions/action items/open questions by substring marker
matching — no model call, always available.
"""

from __future__ import annotations

import re

from dikta.core.debrief.model import ActionItem, DebriefSummary
from dikta.engines.llm.errors import EmptyTranscript

__all__ = ["HeuristicSummarizer"]

_MAX_SEGMENT_WORDS_BEFORE_SPLIT = 30
_WORD_COUNT_FALLBACK_CHUNK_SIZE = 20
_MAX_ACTION_ITEMS = 10
_SUMMARY_SEGMENT_COUNT = 3

# Order matters: longer phrases first so e.g. "and then" wins over "then"
# both for the priority of `_contains_any` and for regex alternation order
# in `_split_at_discourse_markers`.
_DISCOURSE_MARKERS_EN = ["and then", "so", "okay", "ok", "also", "next", "then"]
_DISCOURSE_MARKERS_SV = ["och sen", "sen", "så", "okej", "också", "sedan"]
_ACTION_MARKERS_EN = [
    "will ",
    "should ",
    "need to",
    "needs to",
    "must ",
    "todo",
    "action item",
    "follow up",
]
_ACTION_MARKERS_SV = ["ska ", "måste ", "behöver ", "bör ", "åtgärd", "följa upp"]
_DECISION_MARKERS_EN = ["decided", "agreed", "we will go with"]
_DECISION_MARKERS_SV = ["beslutade", "bestämde", "kom överens", "vi kör på"]
_OPEN_QUESTION_MARKERS_EN = ["open question", "unclear", "not sure"]
_OPEN_QUESTION_MARKERS_SV = ["öppen fråga", "oklart", "osäker"]


def _contains_any(markers: list[str], text: str) -> bool:
    """Plain (non-word-boundary) substring containment, case-insensitive.

    Mirrors `contains(any:in:)` (`HeuristicDebriefSummarizer.swift:228-231`).
    """
    lowered = text.lower()
    return any(marker in lowered for marker in markers)


def _split_sentences(text: str) -> list[str]:
    """Split on `\\n` (dropped) and keep `.`/`!`/`?` as part of the sentence they terminate.

    Mirrors `splitSentences` (`HeuristicDebriefSummarizer.swift:143-169`).
    """
    sentences: list[str] = []
    buffer: list[str] = []
    for ch in text:
        if ch == "\n":
            sentence = "".join(buffer).strip()
            if sentence:
                sentences.append(sentence)
            buffer = []
        elif ch in ".!?":
            buffer.append(ch)
            sentence = "".join(buffer).strip()
            if sentence:
                sentences.append(sentence)
            buffer = []
        else:
            buffer.append(ch)
    sentence = "".join(buffer).strip()
    if sentence:
        sentences.append(sentence)
    return sentences


def _split_every_n_words(text: str, n: int) -> list[str]:
    """Fixed `n`-word chunks; the last chunk may be shorter.

    Mirrors `splitEveryNWords` (`HeuristicDebriefSummarizer.swift:210-222`).
    """
    words = text.split()
    return [" ".join(words[i : i + n]) for i in range(0, len(words), n)]


def _split_at_discourse_markers(text: str, markers: list[str]) -> list[str]:
    """Split on a single case-insensitive `\\b(?:marker1|marker2|...)\\b` regex.

    The matched marker is dropped, not kept in either piece. Returns
    `[text]` unchanged if no marker matches. Mirrors
    `splitAtDiscourseMarkers` (`HeuristicDebriefSummarizer.swift:176-200`).
    """
    pattern = re.compile(
        r"\b(?:" + "|".join(re.escape(marker) for marker in markers) + r")\b", re.IGNORECASE
    )
    pieces = [piece.strip() for piece in pattern.split(text) if piece.strip()]
    return pieces if pieces else [text]


def _split_into_segments(text: str, discourse_markers: list[str]) -> list[str]:
    """Sentence-split, then further split any sentence over 30 words.

    Mirrors `splitIntoSegments` (`HeuristicDebriefSummarizer.swift:122-138`).
    """
    segments: list[str] = []
    for sentence in _split_sentences(text):
        if len(sentence.split()) <= _MAX_SEGMENT_WORDS_BEFORE_SPLIT:
            segments.append(sentence)
            continue
        for piece in _split_at_discourse_markers(sentence, discourse_markers):
            if len(piece.split()) > _MAX_SEGMENT_WORDS_BEFORE_SPLIT:
                segments.extend(_split_every_n_words(piece, _WORD_COUNT_FALLBACK_CHUNK_SIZE))
            else:
                segments.append(piece)
    return segments


def _dedupe_keeping_order(items: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


class HeuristicSummarizer:
    """Deterministic marker-based summarizer. Always available; makes no network calls."""

    name = "Heuristic"

    def is_available(self) -> bool:
        return True

    def summarize(self, transcript: str, language: str) -> DebriefSummary:
        """Bucket transcript segments into decisions/actionItems/openQuestions by marker matching.

        Owner/due are always `None` for this engine. Action items are
        capped at 10; decisions and open questions are uncapped. Mirrors
        `summarize(transcript:language:)`
        (`HeuristicDebriefSummarizer.swift:63-114`).

        Raises:
            EmptyTranscript: `transcript` is blank after trimming.
        """
        trimmed = transcript.strip()
        if not trimmed:
            raise EmptyTranscript()

        # NOTE: the Swift original strips "Me:"/"Them:" two-track labels here
        # via `TwoTrackMerger.stripLabels` when `isLabeledTranscript` is
        # true. That mechanism (and its detection rule) is out of scope for
        # this single-track (file-import) port.

        if language == "sv":
            discourse_markers = _DISCOURSE_MARKERS_SV
            action_markers = _ACTION_MARKERS_SV
            decision_markers = _DECISION_MARKERS_SV
            open_question_markers = _OPEN_QUESTION_MARKERS_SV
        else:
            discourse_markers = _DISCOURSE_MARKERS_EN
            action_markers = _ACTION_MARKERS_EN
            decision_markers = _DECISION_MARKERS_EN
            open_question_markers = _OPEN_QUESTION_MARKERS_EN

        segments = _split_into_segments(trimmed, discourse_markers)
        summary = " ".join(segments[:_SUMMARY_SEGMENT_COUNT])

        decision_texts: list[str] = []
        action_texts: list[str] = []
        open_question_texts: list[str] = []
        for segment in segments:
            if segment.endswith("?") or _contains_any(open_question_markers, segment):
                open_question_texts.append(segment)
            elif _contains_any(decision_markers, segment):
                decision_texts.append(segment)
            elif _contains_any(action_markers, segment):
                action_texts.append(segment)
            # else: bucketed nowhere (may still appear in `summary`).

        decisions = _dedupe_keeping_order(decision_texts)
        action_items = [
            ActionItem(text=text, owner=None, due=None)
            for text in _dedupe_keeping_order(action_texts)[:_MAX_ACTION_ITEMS]
        ]
        open_questions = _dedupe_keeping_order(open_question_texts)

        return DebriefSummary(
            summary=summary,
            decisions=decisions,
            actionItems=action_items,
            openQuestions=open_questions,
        )
