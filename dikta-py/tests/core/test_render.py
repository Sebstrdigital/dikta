"""Tests for `dikta.core.debrief.render`, ported from
`DebriefSummaryRenderPlainTextEnglishTests` /
`DebriefSummaryRenderPlainTextSwedishTests` (`DiktaTests/DebriefSummaryTests.swift`).

Uses a fixed date (2026-09-17, matching the Swift tests' `fixedDate()`)
passed explicitly via `render_plain_text`'s `date` parameter.
"""

from __future__ import annotations

from datetime import datetime

from dikta.core.debrief.model import ActionItem, DebriefSummary

_FIXED_DATE = datetime(2026, 9, 17, 12, 0, 0)


def _blank(summary_text: str = "Short recap.") -> DebriefSummary:
    return DebriefSummary(summary=summary_text)


# --- English --------------------------------------------------------------


def test_renders_heading_with_date() -> None:
    text = _blank().render_plain_text("en", date=_FIXED_DATE)
    assert text.startswith("MEETING DEBRIEF – 2026-09-17\n")


def test_summary_section_always_present() -> None:
    text = _blank().render_plain_text("en", date=_FIXED_DATE)
    assert "SUMMARY\nShort recap." in text


def test_omits_empty_sections() -> None:
    text = _blank().render_plain_text("en", date=_FIXED_DATE)
    assert "DECISIONS" not in text
    assert "ACTION ITEMS" not in text
    assert "OPEN QUESTIONS" not in text


def test_includes_non_empty_sections() -> None:
    summary = DebriefSummary(
        summary="Short recap.",
        decisions=["Go with vendor A"],
        actionItems=[ActionItem(text="Send contract", owner="Anna", due="Friday")],
        openQuestions=["Who owns onboarding?"],
    )
    text = summary.render_plain_text("en", date=_FIXED_DATE)
    expected = (
        "MEETING DEBRIEF – 2026-09-17\n\n"
        "SUMMARY\nShort recap.\n\n"
        "DECISIONS\nGo with vendor A\n\n"
        "ACTION ITEMS\n[ ] Send contract (Anna, due Friday)\n\n"
        "OPEN QUESTIONS\nWho owns onboarding?\n"
    )
    assert text == expected


def test_action_item_with_owner_and_due() -> None:
    item = ActionItem(text="Send contract", owner="Anna", due="Friday")
    summary = DebriefSummary(summary="x", actionItems=[item])
    text = summary.render_plain_text("en", date=_FIXED_DATE)
    assert "[ ] Send contract (Anna, due Friday)" in text


def test_action_item_with_owner_only() -> None:
    item = ActionItem(text="Send contract", owner="Anna")
    summary = DebriefSummary(summary="x", actionItems=[item])
    text = summary.render_plain_text("en", date=_FIXED_DATE)
    assert "[ ] Send contract (Anna)" in text


def test_action_item_with_due_only() -> None:
    item = ActionItem(text="Send contract", due="Friday")
    summary = DebriefSummary(summary="x", actionItems=[item])
    text = summary.render_plain_text("en", date=_FIXED_DATE)
    assert "[ ] Send contract (due Friday)" in text


def test_action_item_with_neither_owner_nor_due() -> None:
    summary = DebriefSummary(summary="x", actionItems=[ActionItem(text="Send contract")])
    text = summary.render_plain_text("en", date=_FIXED_DATE)
    assert "[ ] Send contract" in text
    _, _, after = text.partition("[ ] Send contract")
    assert "(" not in after.split("\n", 1)[0]


def test_ends_with_single_trailing_newline() -> None:
    text = _blank().render_plain_text("en", date=_FIXED_DATE)
    assert text.endswith("\n")
    assert not text.endswith("\n\n")


def test_unknown_language_falls_back_to_english() -> None:
    text = _blank().render_plain_text("fr", date=_FIXED_DATE)
    assert text.startswith("MEETING DEBRIEF")


def test_omitted_date_defaults_to_local_now() -> None:
    before = datetime.now().astimezone().strftime("%Y-%m-%d")
    text = _blank().render_plain_text("en")
    assert before in text


# --- Swedish ----------------------------------------------------------------


def test_renders_swedish_heading() -> None:
    text = _blank().render_plain_text("sv", date=_FIXED_DATE)
    assert text.startswith("MÖTESSAMMANFATTNING – 2026-09-17\n")


def test_renders_swedish_section_headings() -> None:
    summary = DebriefSummary(
        summary="Kort sammanfattning.",
        decisions=["Vi kör på leverantör A"],
        actionItems=[ActionItem(text="Skicka avtal", owner="Anna", due="fredag")],
        openQuestions=["Vem äger onboarding?"],
    )
    text = summary.render_plain_text("sv", date=_FIXED_DATE)
    expected = (
        "MÖTESSAMMANFATTNING – 2026-09-17\n\n"
        "SAMMANFATTNING\nKort sammanfattning.\n\n"
        "BESLUT\nVi kör på leverantör A\n\n"
        "ÅTGÄRDER\n[ ] Skicka avtal (Anna, senast fredag)\n\n"
        "ÖPPNA FRÅGOR\nVem äger onboarding?\n"
    )
    assert text == expected


def test_swedish_action_item_due_only_uses_senast() -> None:
    item = ActionItem(text="Skicka avtal", due="fredag")
    summary = DebriefSummary(summary="x", actionItems=[item])
    text = summary.render_plain_text("sv", date=_FIXED_DATE)
    assert "[ ] Skicka avtal (senast fredag)" in text


def test_swedish_omits_empty_sections() -> None:
    text = _blank("Kort.").render_plain_text("sv", date=_FIXED_DATE)
    assert "BESLUT" not in text
    assert "ÅTGÄRDER" not in text
    assert "ÖPPNA FRÅGOR" not in text
