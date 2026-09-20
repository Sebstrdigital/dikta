"""Tests for `dikta.engines.llm.heuristic`.

Ported from `HeuristicDebriefSummarizerTests`,
`HeuristicDebriefSummarizerLabeledTranscriptTests`, and
`HeuristicDebriefSummarizerRamblingTranscriptTests`
(`DiktaTests/DebriefSummaryTests.swift`).
"""

from __future__ import annotations

import pytest

from dikta.engines.llm.errors import EmptyTranscript
from dikta.engines.llm.heuristic import HeuristicSummarizer

_SUPPLIER_EN = (
    "Okay so we met with the supplier today. Anna will send the updated quote by Friday. "
    "We decided to go with the smaller pallet size. It is still unclear who owns the packaging spec"
)
_SUPPLIER_SV = (
    "Okej så vi träffade leverantören idag. Anna ska skicka den uppdaterade offerten på fredag. "
    "Vi kom överens om att köra på den mindre pallstorleken. "
    "Det är fortfarande oklart vem som äger förpackningsspecen"
)
_RAMBLING_EN = (
    "okay quick debrief from the supplier meeting so we went through the new packaging also Anna "
    "will send the updated quote by friday so we decided to go with the smaller pallet size and "
    "then it is still unclear who owns the packaging spec so I need to check with Johan tomorrow "
    "also we should update the shared folder afterwards"
)
_RAMBLING_SV = (
    "okej snabb genomgång från leverantörsmötet sen vi gick igenom den nya förpackningen också "
    "Anna ska skicka den uppdaterade offerten på fredag sen vi kom överens om att köra på den "
    "mindre pallstorleken och sen det är fortfarande oklart vem som äger förpackningsspecen sen "
    "jag behöver stämma av med Johan imorgon också vi bör uppdatera den delade mappen efteråt"
)


def test_is_always_available() -> None:
    assert HeuristicSummarizer().is_available() is True


def test_throws_on_empty_transcript() -> None:
    with pytest.raises(EmptyTranscript):
        HeuristicSummarizer().summarize("   \n  ", "en")


def test_english_summary_is_first_three_sentences() -> None:
    result = HeuristicSummarizer().summarize(_SUPPLIER_EN, "en")
    assert "Anna will send the updated quote by Friday." in result.summary
    assert "unclear" not in result.summary


def test_english_action_items_found_by_marker() -> None:
    result = HeuristicSummarizer().summarize(_SUPPLIER_EN, "en")
    assert len(result.action_items) == 1
    item = result.action_items[0]
    assert "Anna will send the updated quote by Friday" in item.text
    assert item.owner is None
    assert item.due is None


def test_english_decisions_found_by_marker() -> None:
    result = HeuristicSummarizer().summarize(_SUPPLIER_EN, "en")
    assert len(result.decisions) == 1
    assert "We decided to go with the smaller pallet size" in result.decisions[0]


def test_english_open_questions_found_by_marker() -> None:
    result = HeuristicSummarizer().summarize(_SUPPLIER_EN, "en")
    assert len(result.open_questions) == 1
    assert "unclear who owns the packaging spec" in result.open_questions[0]


def test_swedish_action_items_found_by_marker() -> None:
    result = HeuristicSummarizer().summarize(_SUPPLIER_SV, "sv")
    assert len(result.action_items) == 1
    assert "offerten" in result.action_items[0].text


def test_swedish_decisions_found_by_marker() -> None:
    result = HeuristicSummarizer().summarize(_SUPPLIER_SV, "sv")
    assert len(result.decisions) == 1
    assert "pallstorleken" in result.decisions[0]


def test_swedish_open_questions_found_by_marker() -> None:
    result = HeuristicSummarizer().summarize(_SUPPLIER_SV, "sv")
    assert len(result.open_questions) == 1
    assert "förpackningsspecen" in result.open_questions[0]


def test_action_items_capped_at_ten() -> None:
    transcript = " ".join(f"We will follow up on task {i}." for i in range(1, 16))
    result = HeuristicSummarizer().summarize(transcript, "en")
    assert len(result.action_items) == 10


@pytest.mark.skip(
    reason="out of scope: HeuristicDebriefSummarizerLabeledTranscriptTests."
    "test_labeledTranscript_noOutputFieldContainsMeOrThemLabels — TwoTrackMerger label "
    "stripping is out of scope for this single-track port; Me:/Them: prefixes pass through."
)
def test_labeled_transcript_no_output_field_contains_me_or_them_labels() -> None:
    pass


@pytest.mark.skip(
    reason="out of scope: HeuristicDebriefSummarizerLabeledTranscriptTests."
    "test_labeledTranscript_stillBucketsContentNormally — depends on the same "
    "out-of-scope TwoTrackMerger stripping."
)
def test_labeled_transcript_still_buckets_content_normally() -> None:
    pass


def test_english_rambling_transcript_separates_buckets_cleanly() -> None:
    result = HeuristicSummarizer().summarize(_RAMBLING_EN, "en")
    assert len(result.summary) / len(_RAMBLING_EN) < 0.6
    assert any("quote" in text.lower() for text in (item.text for item in result.action_items))
    assert any("pallet" in text.lower() for text in result.decisions)
    assert any("packaging spec" in text.lower() for text in result.open_questions)
    action_texts = [item.text for item in result.action_items]
    all_texts = result.decisions + action_texts + result.open_questions
    assert len(all_texts) == len(set(all_texts))


def test_swedish_rambling_transcript_separates_buckets_cleanly() -> None:
    result = HeuristicSummarizer().summarize(_RAMBLING_SV, "sv")
    assert len(result.summary) / len(_RAMBLING_SV) < 0.6
    assert any("offerten" in text.lower() for text in (item.text for item in result.action_items))
    assert any("pallstorleken" in text.lower() for text in result.decisions)
    assert any("förpackningsspecen" in text.lower() for text in result.open_questions)
    action_texts = [item.text for item in result.action_items]
    all_texts = result.decisions + action_texts + result.open_questions
    assert len(all_texts) == len(set(all_texts))


def test_long_segment_without_further_discourse_markers_falls_back_to_fixed_word_chunks() -> None:
    transcript = " ".join(f"filler{i}" for i in range(1, 62))
    result = HeuristicSummarizer().summarize(transcript, "en")
    assert "filler1 " in result.summary
    assert "filler61" not in result.summary
