"""Tests for `dikta.core.debrief.model`.

Ported from `DebriefSummaryNormalizationTests`, `DebriefSummaryValidationTests`,
and `DebriefSummaryCodableTests` (`DiktaTests/DebriefSummaryTests.swift`).
Test bodies mirror the Swift originals' inputs/expectations exactly, per
port-spec section 3/4/14; test names are snake_case translations of the
Swift test names so the mapping stays traceable.
"""

from __future__ import annotations

import pytest

from dikta.core.debrief.model import ActionItem, DebriefSummary

# --- ActionItem.normalized() ------------------------------------------------

_PLACEHOLDER_INPUTS = [
    "Not specified",
    "TBD",
    "N/A",
    "n/a",
    "None",
    "Unknown",
    "null",
    "Ingen",
    "Ingen specificerad",
    "Ej angivet",
    "Okänd",
    "-",
    "–",
    "—",
    "  ",
    "",
]


@pytest.mark.parametrize("placeholder", _PLACEHOLDER_INPUTS)
def test_normalized_maps_every_placeholder_to_nil(placeholder: str) -> None:
    item = ActionItem(text="Do X", owner=placeholder, due=placeholder).normalized()
    assert item.owner is None
    assert item.due is None


_GENERIC_OWNER_INPUTS = ["Team", "the team", "Everyone", "ALL", "Teamet", "alla"]


@pytest.mark.parametrize("owner", _GENERIC_OWNER_INPUTS)
def test_normalized_drops_generic_collective_owners(owner: str) -> None:
    item = ActionItem(text="Do X", owner=owner).normalized()
    assert item.owner is None


def test_normalized_never_drops_due_for_generic_owner_words() -> None:
    # "team"/"everyone"/etc are only checked against `owner`; a real due
    # date could coincidentally contain one of those words.
    item = ActionItem(text="Do X", due="Team meeting on Friday").normalized()
    assert item.due == "Team meeting on Friday"


def test_normalized_trims_edge_punctuation_and_whitespace() -> None:
    item = ActionItem(text="Do X", owner="Tomas. ", due=", Friday,").normalized()
    assert item.owner == "Tomas"
    assert item.due == "Friday"


def test_normalized_keeps_a_real_owner_and_due() -> None:
    item = ActionItem(text="Send contract", owner="Anna", due="Friday").normalized()
    assert item.owner == "Anna"
    assert item.due == "Friday"


# --- DebriefSummary.normalized() --------------------------------------------


def test_summary_normalized_drops_empty_and_placeholder_action_items() -> None:
    summary = DebriefSummary(
        summary="x",
        actionItems=[
            ActionItem(text="Do X"),
            ActionItem(text="Not specified"),
            ActionItem(text="  "),
        ],
    )
    normalized = summary.normalized()
    assert [item.text for item in normalized.action_items] == ["Do X"]


def test_summary_normalized_drops_empty_and_placeholder_decisions_keeps_order() -> None:
    summary = DebriefSummary(
        summary="x",
        decisions=["", "Not specified", "Go with vendor A", "inga", "Go with vendor B"],
    )
    normalized = summary.normalized()
    assert normalized.decisions == ["Go with vendor A", "Go with vendor B"]


def test_summary_normalized_drops_placeholder_open_questions_only() -> None:
    summary = DebriefSummary(
        summary="x", openQuestions=["Who owns onboarding?", "N/A", "", "Still open?"]
    )
    normalized = summary.normalized()
    assert normalized.open_questions == ["Who owns onboarding?", "Still open?"]


def test_summary_normalized_dedupes_decision_exactly_matching_action_item() -> None:
    summary = DebriefSummary(
        summary="x",
        decisions=["Booked the meeting."],
        actionItems=[ActionItem(text="booked the meeting")],
    )
    normalized = summary.normalized()
    assert normalized.decisions == []
    assert [item.text for item in normalized.action_items] == ["booked the meeting"]


def test_summary_normalized_removes_decision_that_paraphrases_an_action_item() -> None:
    summary = DebriefSummary(
        summary="x",
        decisions=["We agreed to send updated quote to vendor Friday"],
        actionItems=[ActionItem(text="Send updated quote to vendor Friday")],
    )
    normalized = summary.normalized()
    assert normalized.decisions == []


def test_summary_normalized_removes_a_second_paraphrase_above_the_raised_threshold() -> None:
    summary = DebriefSummary(
        summary="x",
        decisions=[
            "We agreed to send updated quote to vendor Friday",
            "We agreed to review Falcon repo docs",
        ],
        actionItems=[
            ActionItem(text="Send updated quote to vendor Friday"),
            ActionItem(text="Review Falcon repo docs"),
        ],
    )
    normalized = summary.normalized()
    assert normalized.decisions == []


@pytest.mark.parametrize(
    ("decision", "action_text"),
    [
        ("Boka möte med Erik", "Boka möte med Anna"),
        ("Review the Falcon repo", "Review the Falcon docs"),
    ],
)
def test_summary_normalized_does_not_treat_moderately_similar_distinct_items_as_a_paraphrase(
    decision: str, action_text: str
) -> None:
    # Jaccard ~0.6 for both pairs — below the raised 0.75 threshold, so both
    # must survive as distinct entries (not deduped as paraphrases).
    summary = DebriefSummary(
        summary="x", decisions=[decision], actionItems=[ActionItem(text=action_text)]
    )
    normalized = summary.normalized()
    assert normalized.decisions == [decision]


def test_summary_normalized_paraphrase_detection_splits_on_any_whitespace() -> None:
    summary = DebriefSummary(
        summary="x",
        decisions=["We agreed to\tsend\nupdated quote to vendor Friday"],
        actionItems=[ActionItem(text="Send updated quote to vendor Friday")],
    )
    normalized = summary.normalized()
    assert normalized.decisions == []


def test_summary_normalized_summary_field_passes_through_unchanged() -> None:
    summary = DebriefSummary(summary="  Not touched.  ")
    assert summary.normalized().summary == "  Not touched.  "


# --- ActionItem.validated() / DebriefSummary.validated() -------------------


def test_validated_nulls_fabricated_iso_date_due() -> None:
    item = ActionItem(text="Send report", due="2027-01-01")
    validated = item.validated("We talked about the report but gave no date.")
    assert validated.due is None


def test_validated_nulls_fabricated_four_digit_year_due() -> None:
    item = ActionItem(text="Send report", due="by 2027")
    validated = item.validated("No year was mentioned in this meeting at all.")
    assert validated.due is None


def test_validated_keeps_due_when_literal_year_present_in_transcript() -> None:
    item = ActionItem(text="Send report", due="by 2027")
    validated = item.validated("We agreed to wrap this up by 2027 at the latest.")
    assert validated.due == "by 2027"


def test_validated_leaves_non_date_due_untouched_even_if_fabricated() -> None:
    # Known limitation: a relative due like "imorgon" has no year/ISO-date
    # shape, so it's never checked against the transcript at all.
    item = ActionItem(text="Send report", due="imorgon")
    validated = item.validated("This transcript never mentions a due date.")
    assert validated.due == "imorgon"


def test_validated_due_token_match_is_substring_based_not_whole_string() -> None:
    item = ActionItem(text="Send report", due="sometime around 2027")
    validated = item.validated("Let's target 2027 for this, roughly.")
    assert validated.due == "sometime around 2027"


def test_validated_nulls_unknown_capitalized_owner_not_in_transcript() -> None:
    item = ActionItem(text="Send report", owner="Ingrid")
    validated = item.validated("We discussed the report but nobody else was mentioned.")
    assert validated.owner is None


def test_validated_keeps_owner_genuinely_present_in_transcript() -> None:
    item = ActionItem(text="Send report", owner="Anna")
    validated = item.validated("Anna will send the report on Friday.")
    assert validated.owner == "Anna"


def test_validated_keeps_owner_present_but_attached_to_wrong_task() -> None:
    # Documented limitation: an owner that appears anywhere in the
    # transcript is left alone, even if misattributed to this task.
    item = ActionItem(text="Send report", owner="Anna")
    validated = item.validated("Anna joined the call. Someone else needs to send the report.")
    assert validated.owner == "Anna"


def test_validated_never_touches_lowercase_owner() -> None:
    item = ActionItem(text="Send report", owner="someone")
    validated = item.validated("Nothing about someone in this transcript.")
    assert validated.owner == "someone"


@pytest.mark.parametrize("owner", ["Me", "me", "I", "Jag", "jag", "Myself", "Mig", "Själv"])
def test_validated_keeps_first_person_owner_even_when_absent_verbatim(owner: str) -> None:
    item = ActionItem(text="Send report", owner=owner)
    validated = item.validated("This transcript never spells out that pronoun explicitly.")
    assert validated.owner == owner


def test_validated_nulls_unrelated_capitalized_name() -> None:
    item = ActionItem(text="Send report", owner="Johan")
    validated = item.validated("Anna and Erik discussed the report; nobody else was named.")
    assert validated.owner is None


def test_summary_validated_only_touches_action_item_owner_and_due() -> None:
    summary = DebriefSummary(
        summary="Recap mentioning Ingrid.",
        decisions=["A decision mentioning Ingrid."],
        actionItems=[ActionItem(text="Send report", owner="Ingrid", due="2099-01-01")],
        openQuestions=["A question mentioning Ingrid?"],
    )
    validated = summary.validated("This transcript never mentions that owner or that date.")
    assert validated.summary == summary.summary
    assert validated.decisions == summary.decisions
    assert validated.open_questions == summary.open_questions
    assert validated.action_items[0].owner is None
    assert validated.action_items[0].due is None


# --- Codable round trip ------------------------------------------------------


def test_codable_round_trips_through_json() -> None:
    summary = DebriefSummary(
        summary="Recap.",
        decisions=["Go with vendor A"],
        actionItems=[
            ActionItem(text="Send contract", owner="Anna", due="Friday"),
            ActionItem(text="Follow up"),
        ],
        openQuestions=["Who owns onboarding?"],
    )
    round_tripped = DebriefSummary.from_json(summary.to_json())
    assert round_tripped == summary
    assert round_tripped.action_items[1].owner is None
    assert round_tripped.action_items[1].due is None
