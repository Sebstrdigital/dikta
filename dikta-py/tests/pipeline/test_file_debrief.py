"""Tests for `FileDebriefPipeline`, ported from the in-scope subset of
`DiktaTests/DebriefPipelineTests.swift` (see port-spec section 14).

Not ported: the true (chunking/live-session) branch of
`DebriefPipeline.run` and the `issues`/`summarize`-closure override
paths — both explicitly out of scope for the file-import port (port-spec
section 13).
"""

from __future__ import annotations

import time
import wave
from pathlib import Path

import numpy as np
import pytest

from dikta.core.debrief.model import ActionItem, DebriefSummary
from dikta.core.debrief.store import DebriefStore
from dikta.engines.llm.chained import ChainedSummarizer
from dikta.engines.llm.errors import EmptyTranscript, SummarizerError
from dikta.engines.llm.fake import FakeSummarizer
from dikta.engines.stt.base import TranscriptionResult
from dikta.engines.stt.fake import FakeSpeechToText
from dikta.pipeline.file_debrief import (
    DebriefResult,
    FileDebriefPipeline,
    Stage,
    TranscriptionTimeout,
    render_language,
)


class _FakeLoader:
    """Loader stub for `run_file` tests: returns fixed samples regardless of path."""

    def __init__(self, samples: np.ndarray) -> None:
        self.samples = samples

    def load(self, path: Path) -> np.ndarray:
        return self.samples


class _DetectingSTT:
    """A `SpeechToText` stub that reports a fixed *detected* language, independent of what was
    requested -- unlike `FakeSpeechToText`, which just echoes the requested language back.
    Simulates faster-whisper's language auto-detection when no language was requested.
    """

    name = "detecting-fake"

    def __init__(self, text: str, detected_language: str) -> None:
        self._text = text
        self._detected_language = detected_language
        self.calls: list[tuple[int, str | None]] = []

    def transcribe(self, samples: np.ndarray, language: str | None = None) -> TranscriptionResult:
        self.calls.append((len(samples), language))
        return TranscriptionResult(
            text=self._text,
            segments=(),
            language=self._detected_language,
            audio_seconds=len(samples) / 16_000,
        )


def _samples(seconds: float = 1.0) -> np.ndarray:
    return np.zeros(int(seconds * 16_000), dtype=np.float32)


def _make_pipeline(
    tmp_path: Path,
    stt=None,
    summarizer=None,
    store: DebriefStore | None = None,
    **kwargs,
) -> FileDebriefPipeline:
    return FileDebriefPipeline(
        loader=_FakeLoader(_samples()),
        stt=stt if stt is not None else FakeSpeechToText(text="hello world"),
        summarizer=summarizer
        if summarizer is not None
        else FakeSummarizer(result=DebriefSummary(summary="a summary")),
        store=store if store is not None else DebriefStore(root=tmp_path),
        **kwargs,
    )


def _write_wav(path: Path, seconds: float = 0.5, sample_rate: int = 16_000) -> None:
    n = int(seconds * sample_rate)
    pcm = np.zeros(n, dtype=np.int16)
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm.tobytes())


def test_run_samples_writes_all_files_and_reports_stages_in_order(tmp_path):
    stages: list[Stage] = []
    summarizer = FakeSummarizer(result=DebriefSummary(summary="a SUMMARY here"))
    pipeline = _make_pipeline(
        tmp_path, stt=FakeSpeechToText(text="we talked about things"), summarizer=summarizer
    )

    result = pipeline.run_samples(_samples(), language="en", on_stage=stages.append)

    assert stages == [Stage.TRANSCRIBING, Stage.SUMMARIZING, Stage.SAVING]
    assert isinstance(result, DebriefResult)
    assert result.paths.audio.exists()
    assert result.paths.transcript.exists()
    assert result.paths.summary.exists()
    assert result.paths.transcript.read_text() == "we talked about things"
    assert result.transcript == "we talked about things"
    assert result.paths.summary.read_text() == result.rendered_text
    assert "SUMMARY" in result.rendered_text
    assert result.engine_name == "fake"
    assert summarizer.calls == [("we talked about things", "en")]


def test_run_file_fires_loading_stage_first(tmp_path):
    stages: list[Stage] = []
    pipeline = _make_pipeline(tmp_path)
    audio_path = tmp_path / "input.wav"
    _write_wav(audio_path)

    pipeline.run_file(audio_path, language="en", on_stage=stages.append)

    assert stages == [Stage.LOADING, Stage.TRANSCRIBING, Stage.SUMMARIZING, Stage.SAVING]


def test_run_file_copies_original_file_when_imported(tmp_path):
    pipeline = _make_pipeline(tmp_path)
    audio_path = tmp_path / "input.wav"
    _write_wav(audio_path)

    result = pipeline.run_file(audio_path)

    original = result.paths.folder / "original.wav"
    assert original.exists()
    assert original.read_bytes() == audio_path.read_bytes()


def test_run_samples_without_original_file_writes_no_original(tmp_path):
    pipeline = _make_pipeline(tmp_path)

    result = pipeline.run_samples(_samples())

    assert list(result.paths.folder.glob("original.*")) == []


def test_run_samples_unsupported_language_renders_in_english(tmp_path):
    summarizer = FakeSummarizer(result=DebriefSummary(summary="s"))
    pipeline = _make_pipeline(tmp_path, summarizer=summarizer)

    pipeline.run_samples(_samples(), language="id")

    assert summarizer.calls[0][1] == "en"


@pytest.mark.parametrize(
    ("code", "expected"),
    [("sv", "sv"), ("en", "en"), ("id", "en"), (None, "en")],
)
def test_render_language_only_swedish_and_english_pass_through(code, expected):
    assert render_language(code) == expected


def test_run_samples_empty_transcript_raises_and_writes_no_summary(tmp_path):
    stages: list[Stage] = []
    summarizer = FakeSummarizer(result=DebriefSummary(summary="s"))
    pipeline = _make_pipeline(
        tmp_path, stt=FakeSpeechToText(text="   \n  "), summarizer=summarizer
    )

    with pytest.raises(EmptyTranscript):
        pipeline.run_samples(_samples(), on_stage=stages.append)

    assert stages == [Stage.TRANSCRIBING]
    assert summarizer.calls == []
    sessions = list(tmp_path.iterdir())
    assert len(sessions) == 1
    assert (sessions[0] / "transcript.txt").exists()
    assert not (sessions[0] / "summary.txt").exists()


@pytest.mark.parametrize(
    "marker",
    ["[BLANK_AUDIO]", "[silence]", " [ Silence ] ", "(silence)", "[NO SPEECH]"],
)
def test_run_samples_whisper_silence_marker_raises_empty_transcript(tmp_path, marker):
    summarizer = FakeSummarizer(result=DebriefSummary(summary="s"))
    pipeline = _make_pipeline(tmp_path, stt=FakeSpeechToText(text=marker), summarizer=summarizer)

    with pytest.raises(EmptyTranscript):
        pipeline.run_samples(_samples())

    assert summarizer.calls == []
    for folder in tmp_path.iterdir():
        assert not (folder / "summary.txt").exists()


def test_run_samples_normalized_dedupes_decision_that_duplicates_an_action_item(tmp_path):
    transcript = "we agreed alice will send the invoice"
    result_summary = DebriefSummary(
        summary="s",
        decisions=["send the invoice"],
        actionItems=[ActionItem(text="send the invoice", owner="Not specified", due="TBD")],
    )
    summarizer = FakeSummarizer(result=result_summary)
    pipeline = _make_pipeline(
        tmp_path, stt=FakeSpeechToText(text=transcript), summarizer=summarizer
    )

    result = pipeline.run_samples(_samples())

    assert result.summary.decisions == []
    assert result.summary.action_items[0].owner is None
    assert result.summary.action_items[0].due is None
    assert "Not specified" not in result.rendered_text
    assert "TBD" not in result.rendered_text


def test_run_samples_transcription_timeout_raises_and_never_summarizes(tmp_path):
    def _slow_responder(samples, language):
        time.sleep(2.0)
        return "late transcript"

    summarizer = FakeSummarizer(result=DebriefSummary(summary="s"))
    pipeline = _make_pipeline(
        tmp_path,
        stt=FakeSpeechToText(responder=_slow_responder),
        summarizer=summarizer,
        transcription_timeout=0.2,
    )

    with pytest.raises(TranscriptionTimeout):
        pipeline.run_samples(_samples())

    assert summarizer.calls == []
    sessions = list(tmp_path.iterdir())
    assert len(sessions) == 1
    assert not (sessions[0] / "transcript.txt").exists()


def test_run_samples_summarizer_failure_propagates(tmp_path):
    summarizer = FakeSummarizer(error=SummarizerError("boom"))
    pipeline = _make_pipeline(tmp_path, summarizer=summarizer)

    with pytest.raises(SummarizerError):
        pipeline.run_samples(_samples())


def test_run_samples_summarizer_failure_writes_no_summary_file(tmp_path):
    summarizer = FakeSummarizer(error=SummarizerError("boom"))
    pipeline = _make_pipeline(
        tmp_path, stt=FakeSpeechToText(text="we talked about things"), summarizer=summarizer
    )

    with pytest.raises(SummarizerError):
        pipeline.run_samples(_samples())

    sessions = list(tmp_path.iterdir())
    assert len(sessions) == 1
    assert (sessions[0] / "transcript.txt").exists()
    assert not (sessions[0] / "summary.txt").exists()


def test_run_samples_falls_back_to_detected_language_when_request_language_is_none(tmp_path):
    summarizer = FakeSummarizer(result=DebriefSummary(summary="s"))
    stt = _DetectingSTT(text="vi pratade om saker", detected_language="sv")
    pipeline = _make_pipeline(tmp_path, stt=stt, summarizer=summarizer)

    result = pipeline.run_samples(_samples(), language=None)

    assert summarizer.calls[0][1] == "sv"
    assert result.detected_language == "sv"
    assert "MÖTESSAMMANFATTNING" in result.rendered_text


def test_run_samples_requested_language_wins_over_detected_language(tmp_path):
    summarizer = FakeSummarizer(result=DebriefSummary(summary="s"))
    stt = _DetectingSTT(text="we talked about things", detected_language="sv")
    pipeline = _make_pipeline(tmp_path, stt=stt, summarizer=summarizer)

    result = pipeline.run_samples(_samples(), language="en")

    assert summarizer.calls[0][1] == "en"
    assert result.detected_language == "sv"
    assert "MEETING DEBRIEF" in result.rendered_text


def test_run_samples_engine_name_from_plain_summarizer(tmp_path):
    summarizer = FakeSummarizer(result=DebriefSummary(summary="s"), name="Fake")
    pipeline = _make_pipeline(tmp_path, summarizer=summarizer)

    result = pipeline.run_samples(_samples())

    assert result.engine_name == "Fake"


def test_run_samples_engine_name_from_chained_summarizer_last_used_engine(tmp_path):
    failing = FakeSummarizer(error=SummarizerError("nope"), name="First")
    succeeding = FakeSummarizer(result=DebriefSummary(summary="s"), name="Second")
    chained = ChainedSummarizer([failing, succeeding])
    pipeline = _make_pipeline(tmp_path, summarizer=chained)

    result = pipeline.run_samples(_samples())

    assert result.engine_name == "Second"
