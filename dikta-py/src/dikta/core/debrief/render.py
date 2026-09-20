"""Plain-text rendering of a `DebriefSummary`.

Port of `DebriefSummary.renderPlainText(language:date:)` and
`DebriefSummaryStrings` (`Models/DebriefSummary.swift:302-378`).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime

from dikta.core.debrief.model import ActionItem, DebriefSummary

__all__ = ["render_plain_text"]


@dataclass(frozen=True)
class _Strings:
    title: str
    summary_heading: str
    decisions_heading: str
    action_items_heading: str
    open_questions_heading: str
    due_format: str  # `str.format` template with one positional placeholder


_ENGLISH = _Strings(
    title="MEETING DEBRIEF",
    summary_heading="SUMMARY",
    decisions_heading="DECISIONS",
    action_items_heading="ACTION ITEMS",
    open_questions_heading="OPEN QUESTIONS",
    due_format="due {}",
)

_SWEDISH = _Strings(
    title="MÖTESSAMMANFATTNING",
    summary_heading="SAMMANFATTNING",
    decisions_heading="BESLUT",
    action_items_heading="ÅTGÄRDER",
    open_questions_heading="ÖPPNA FRÅGOR",
    due_format="senast {}",
)


def _strings_for_language(language: str) -> _Strings:
    """`"sv"` gets Swedish strings; anything else (including unsupported codes) falls back to
    English.
    """
    return _SWEDISH if language == "sv" else _ENGLISH


def _render_action_item(item: ActionItem, strings: _Strings) -> str:
    """Mirrors `renderActionItem` (Models/DebriefSummary.swift:341-354)."""
    line = f"[ ] {item.text}"
    due_suffix = strings.due_format.format(item.due) if item.due is not None else None
    if item.owner is not None and due_suffix is not None:
        line += f" ({item.owner}, {due_suffix})"
    elif item.owner is not None:
        line += f" ({item.owner})"
    elif due_suffix is not None:
        line += f" ({due_suffix})"
    return line


def render_plain_text(
    summary: DebriefSummary, language: str, date: datetime | date | None = None
) -> str:
    """Render `summary` as the plain text written to `summary.txt`.

    `language` is `"sv"` for Swedish headings, anything else falls back to
    English. `date` defaults to the local current date/time when omitted.
    Empty sections (no decisions/action items/open questions) are omitted
    entirely, including their heading. Blocks are separated by a blank
    line; the result ends with exactly one trailing newline. Mirrors
    `DebriefSummary.renderPlainText(language:date:)`
    (Models/DebriefSummary.swift:302-329).
    """
    strings = _strings_for_language(language)
    resolved_date = date if date is not None else datetime.now().astimezone()
    date_string = resolved_date.strftime("%Y-%m-%d")

    blocks = [
        f"{strings.title} – {date_string}",
        f"{strings.summary_heading}\n{summary.summary}",
    ]

    if summary.decisions:
        blocks.append(strings.decisions_heading + "\n" + "\n".join(summary.decisions))
    if summary.action_items:
        blocks.append(
            strings.action_items_heading
            + "\n"
            + "\n".join(_render_action_item(item, strings) for item in summary.action_items)
        )
    if summary.open_questions:
        blocks.append(strings.open_questions_heading + "\n" + "\n".join(summary.open_questions))

    return "\n\n".join(blocks) + "\n"
