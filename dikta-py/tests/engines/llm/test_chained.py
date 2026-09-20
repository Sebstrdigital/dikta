"""Tests for `dikta.engines.llm.chained`, ported from `ChainedDebriefSummarizerTests`
(`DiktaTests/DebriefSummaryTests.swift`).

The Swift original's `Task.checkCancellation()` / `CancellationError`
short-circuit between engines has no equivalent in this synchronous port
(see `dikta.engines.llm.chained` module docstring) — the corresponding
Swift test is skipped rather than silently omitted.
"""

from __future__ import annotations

import pytest

from dikta.core.debrief.model import DebriefSummary
from dikta.engines.llm.chained import ChainedSummarizer
from dikta.engines.llm.errors import EmptyTranscript, SummarizerUnavailable
from dikta.engines.llm.fake import FakeSummarizer


def test_picks_first_available_engine() -> None:
    first = FakeSummarizer(result=DebriefSummary(summary="first"), name="First")
    second = FakeSummarizer(result=DebriefSummary(summary="second"), name="Second")
    chained = ChainedSummarizer([first, second])

    result = chained.summarize("Some transcript.", "en")

    assert result.summary == "first"
    assert chained.last_used_engine_name == "First"
    assert second.summarize_call_count == 0


def test_falls_through_on_throwing_engine() -> None:
    first = FakeSummarizer(error=SummarizerUnavailable("boom"), name="First")
    second = FakeSummarizer(result=DebriefSummary(summary="second"), name="Second")
    chained = ChainedSummarizer([first, second])

    result = chained.summarize("Some transcript.", "en")

    assert result.summary == "second"
    assert chained.last_used_engine_name == "Second"


def test_throws_when_no_engine_available() -> None:
    first = FakeSummarizer(available=False, name="First")
    second = FakeSummarizer(available=False, name="Second")
    chained = ChainedSummarizer([first, second])

    with pytest.raises(SummarizerUnavailable):
        chained.summarize("Some transcript.", "en")
    assert chained.last_used_engine_name is None


def test_throws_last_error_when_every_engine_fails() -> None:
    class Boom(Exception):
        pass

    first = FakeSummarizer(error=Boom("first failed"), name="First")
    second = FakeSummarizer(error=Boom("second failed"), name="Second")
    chained = ChainedSummarizer([first, second])

    with pytest.raises(Boom, match="second failed"):
        chained.summarize("Some transcript.", "en")


def test_is_available_true_if_any_engine_available() -> None:
    first = FakeSummarizer(available=False, name="First")
    second = FakeSummarizer(available=True, name="Second")
    chained = ChainedSummarizer([first, second])
    assert chained.is_available() is True


def test_is_available_false_if_no_engine_available() -> None:
    first = FakeSummarizer(available=False, name="First")
    second = FakeSummarizer(available=False, name="Second")
    chained = ChainedSummarizer([first, second])
    assert chained.is_available() is False


def test_empty_transcript_short_circuits_before_touching_any_engine() -> None:
    first = FakeSummarizer(result=DebriefSummary(summary="first"), name="First")
    chained = ChainedSummarizer([first])

    with pytest.raises(EmptyTranscript):
        chained.summarize("   \n  ", "en")

    assert first.summarize_call_count == 0


def test_last_used_engine_name_resets_after_a_subsequent_total_failure() -> None:
    first = FakeSummarizer(result=DebriefSummary(summary="first"), name="First")
    chained = ChainedSummarizer([first])

    result = chained.summarize("Some transcript.", "en")
    assert result.summary == "first"
    assert chained.last_used_engine_name == "First"

    first.available = False  # now every engine is unavailable
    with pytest.raises(SummarizerUnavailable):
        chained.summarize("Some other transcript.", "en")

    assert chained.last_used_engine_name is None


def test_engine_names_reports_try_order() -> None:
    first = FakeSummarizer(name="First")
    second = FakeSummarizer(name="Second")
    chained = ChainedSummarizer([first, second])
    assert chained.engine_names == ["First", "Second"]


@pytest.mark.skip(
    reason="out of scope: ChainedDebriefSummarizerTests."
    "test_cancellationError_propagatesImmediatelyWithoutFallingThrough — this port is "
    "synchronous (runs in a worker subprocess), so there is no Task.checkCancellation()/"
    "CancellationError equivalent to port."
)
def test_cancellation_error_propagates_immediately_without_falling_through() -> None:
    pass
