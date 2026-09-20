"""Tests for `dikta.core.debrief.parser`, ported from `DebriefSummaryParserTests`
(`DiktaTests/DebriefSummaryTests.swift`).
"""

from __future__ import annotations

import json

import pytest

from dikta.core.debrief.parser import parse_summary
from dikta.engines.llm.errors import BadResponse


def test_parses_plain_json() -> None:
    raw = '{"summary": "Recap.", "decisions": ["A"], "actionItems": [], "openQuestions": []}'
    summary = parse_summary(raw)
    assert summary.summary == "Recap."
    assert summary.decisions == ["A"]


def test_parses_fenced_json() -> None:
    raw = '```json\n{"summary": "Recap."}\n```'
    summary = parse_summary(raw)
    assert summary.summary == "Recap."


def test_parses_json_with_leading_chatter() -> None:
    raw = 'Sure, here is the summary:\n{"summary": "Recap."}'
    summary = parse_summary(raw)
    assert summary.summary == "Recap."


def test_parses_null_owner_and_due() -> None:
    raw = '{"summary": "Recap.", "actionItems": [{"text": "Do X", "owner": null, "due": null}]}'
    summary = parse_summary(raw)
    assert summary.action_items[0].owner is None
    assert summary.action_items[0].due is None


def test_missing_arrays_default_to_empty() -> None:
    summary = parse_summary('{"summary": "Recap only."}')
    assert summary.decisions == []
    assert summary.action_items == []
    assert summary.open_questions == []


def test_garbage_input_throws_bad_response() -> None:
    raw = "not json at all, sorry"
    with pytest.raises(BadResponse) as exc_info:
        parse_summary(raw)
    assert exc_info.value.excerpt == raw[:200]


def test_malformed_json_throws_bad_response_with_excerpt() -> None:
    raw = '{"summary": "Recap.", "decisions": ["unterminated'
    with pytest.raises(BadResponse) as exc_info:
        parse_summary(raw)
    assert exc_info.value.excerpt == raw[:200]


def test_excerpt_is_taken_from_original_untrimmed_raw() -> None:
    raw = "   \n  garbage " * 30  # > 200 chars once repeated
    with pytest.raises(BadResponse) as exc_info:
        parse_summary(raw)
    assert exc_info.value.excerpt == raw[:200]


def test_action_item_missing_text_throws_bad_response() -> None:
    raw = '{"summary": "Recap.", "actionItems": [{"owner": "Anna"}]}'
    with pytest.raises(BadResponse):
        parse_summary(raw)


def test_summary_missing_throws_bad_response() -> None:
    with pytest.raises(BadResponse):
        parse_summary('{"decisions": ["A"]}')


_ARRAY_FIELD_ATTR = {
    "decisions": "decisions",
    "openQuestions": "open_questions",
    "actionItems": "action_items",
}


@pytest.mark.parametrize("field", ["decisions", "openQuestions", "actionItems"])
@pytest.mark.parametrize(
    "bad_value",
    ["we go with vendor A", {"a": 1}, False],
    ids=["string", "object", "bool"],
)
def test_array_field_wrong_type_throws_bad_response(field: str, bad_value: object) -> None:
    # Non-array JSON values must raise, not get blindly iterated (a string
    # into characters, a dict into its keys) or truthiness-defaulted to [].
    raw = json.dumps({"summary": "x", field: bad_value})
    with pytest.raises(BadResponse):
        parse_summary(raw)


@pytest.mark.parametrize("field", ["decisions", "openQuestions", "actionItems"])
def test_array_field_null_defaults_to_empty(field: str) -> None:
    raw = json.dumps({"summary": "x", field: None})
    summary = parse_summary(raw)
    assert getattr(summary, _ARRAY_FIELD_ATTR[field]) == []


@pytest.mark.parametrize("field", ["decisions", "openQuestions", "actionItems"])
def test_array_field_missing_key_defaults_to_empty(field: str) -> None:
    raw = json.dumps({"summary": "x"})
    summary = parse_summary(raw)
    assert getattr(summary, _ARRAY_FIELD_ATTR[field]) == []


def test_parser_output_is_already_normalized() -> None:
    raw = (
        '{"summary": "Recap.", "decisions": ["Not specified"], '
        '"actionItems": [{"text": "Do X", "owner": "TBD"}]}'
    )
    summary = parse_summary(raw)
    assert summary.decisions == []
    assert summary.action_items[0].owner is None
