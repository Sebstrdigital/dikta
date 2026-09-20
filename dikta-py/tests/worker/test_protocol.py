"""Round-trip tests for the JSON-lines worker protocol (`dikta.worker.protocol`)."""

from __future__ import annotations

from pathlib import Path

import pytest
from pydantic import ValidationError

from dikta.pipeline.file_debrief import Stage
from dikta.worker.protocol import (
    DebriefRequest,
    ErrorEvent,
    LogEvent,
    ResultEvent,
    StageEvent,
    parse_event,
)


def test_debrief_request_round_trips_through_json():
    request = DebriefRequest(file=Path("/tmp/input.wav"), language="sv")

    restored = DebriefRequest.model_validate_json(request.model_dump_json())

    assert restored == request


def test_debrief_request_defaults_include_fake_stt_and_engine_fields():
    request = DebriefRequest(file=Path("/tmp/input.wav"))

    assert request.stt_engine == "faster-whisper"
    assert request.fake_stt_text is None
    assert request.fake_stt_delay == 0.0
    assert request.engine_kind == "auto"


def test_debrief_request_candidate_languages_defaults_to_en_sv():
    request = DebriefRequest(file=Path("/tmp/input.wav"))

    assert request.candidate_languages == ["en", "sv"]


def test_debrief_request_candidate_languages_round_trips_through_json():
    request = DebriefRequest(file=Path("/tmp/input.wav"), candidate_languages=["sv"])

    restored = DebriefRequest.model_validate_json(request.model_dump_json())

    assert restored == request


def test_debrief_request_candidate_languages_none_round_trips_through_json():
    request = DebriefRequest(file=Path("/tmp/input.wav"), candidate_languages=None)

    restored = DebriefRequest.model_validate_json(request.model_dump_json())

    assert restored.candidate_languages is None


def test_debrief_request_rejects_invalid_candidate_language_code():
    with pytest.raises(ValidationError):
        DebriefRequest(file=Path("/tmp/input.wav"), candidate_languages=["EN"])


def test_debrief_request_offline_defaults_to_false():
    request = DebriefRequest(file=Path("/tmp/input.wav"))

    assert request.offline is False


def test_debrief_request_offline_round_trips_through_json():
    request = DebriefRequest(file=Path("/tmp/input.wav"), offline=True)

    restored = DebriefRequest.model_validate_json(request.model_dump_json())

    assert restored == request


def test_stage_event_round_trips():
    event = StageEvent(stage=Stage.TRANSCRIBING)

    restored = parse_event(event.model_dump_json())

    assert isinstance(restored, StageEvent)
    assert restored.stage == Stage.TRANSCRIBING


def test_result_event_round_trips():
    event = ResultEvent(
        transcript="hello",
        rendered_text="MEETING DEBRIEF\n\nSUMMARY\nhello\n",
        summary_json='{"summary": "hello"}',
        folder=Path("/tmp/session"),
        engine_name="fake",
        issues=["one issue"],
    )

    restored = parse_event(event.model_dump_json())

    assert isinstance(restored, ResultEvent)
    assert restored == event


def test_error_event_round_trips():
    event = ErrorEvent(kind="empty_transcript", message="Transcript is empty.")

    restored = parse_event(event.model_dump_json())

    assert isinstance(restored, ErrorEvent)
    assert restored == event


def test_log_event_round_trips():
    event = LogEvent(level="warning", message="something odd")

    restored = parse_event(event.model_dump_json())

    assert isinstance(restored, LogEvent)
    assert restored == event
