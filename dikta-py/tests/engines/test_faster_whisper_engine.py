from __future__ import annotations

import logging
import os
from dataclasses import dataclass

import numpy as np
import pytest

from dikta.engines.stt.base import SpeechToText, TranscriptionError
from dikta.engines.stt.faster_whisper_engine import FasterWhisperEngine


def _samples(seconds: float, sample_rate: int = 16_000) -> np.ndarray:
    return np.zeros(int(seconds * sample_rate), dtype=np.float32)


class TestNameWithoutLoading:
    def test_name_reflects_model_without_constructing_whisper_model(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        class _ExplodingIfConstructed:
            def __init__(self, *args, **kwargs) -> None:
                raise AssertionError("WhisperModel should not be constructed just to read .name")

        monkeypatch.setattr("faster_whisper.WhisperModel", _ExplodingIfConstructed)

        engine = FasterWhisperEngine(model="tiny")

        assert engine.name == "faster-whisper:tiny"

    def test_satisfies_speech_to_text_protocol_without_constructing_whisper_model(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        class _ExplodingIfConstructed:
            def __init__(self, *args, **kwargs) -> None:
                raise AssertionError(
                    "WhisperModel should not be constructed for an isinstance check"
                )

        monkeypatch.setattr("faster_whisper.WhisperModel", _ExplodingIfConstructed)

        assert isinstance(FasterWhisperEngine(model="tiny"), SpeechToText)


@dataclass
class _StubSegment:
    text: str
    start: float
    end: float


@dataclass
class _StubInfo:
    language: str


class _StubWhisperModel:
    """Stand-in for `faster_whisper.WhisperModel` — no download, no inference.

    `transcribe`/`detect_language` capture exactly the kwargs they were
    called with (via `**kwargs`, not fixed parameters), so a test can
    assert on presence/absence of e.g. `language_detection_segments`
    rather than every call needing to supply it.
    """

    construct_count = 0
    last_call: dict | None = None
    last_detect_call: dict | None = None
    #: `(language, probability, all_language_probs)` returned by
    #: `detect_language`, or `None` to leave the class default in place.
    #: A sane default so tests that don't care about detection still get
    #: *something* back from it.
    detect_language_result: tuple[str, float, list[tuple[str, float]]] = (
        "en",
        0.9,
        [("en", 0.9), ("sv", 0.05)],
    )
    #: When set, `detect_language` raises this instead of returning.
    detect_language_error: Exception | None = None

    def __init__(
        self,
        model_name: str,
        device: str,
        compute_type: str,
        download_root: str | None,
        **kwargs,
    ) -> None:
        # `**kwargs` swallows `local_files_only` -- this stub always
        # "finds" the model locally, so `_load_model`'s download-fallback
        # path is never exercised here (see `TestModelLoading` for that).
        type(self).construct_count += 1
        self.model_name = model_name

    def transcribe(self, samples, **kwargs):
        type(self).last_call = {**kwargs, "n_samples": len(samples)}
        segments = iter(
            [
                _StubSegment(text="  hello ", start=0.0, end=1.0),
                _StubSegment(text="world  ", start=1.0, end=2.0),
            ]
        )
        returned_language = kwargs.get("language") or "en"
        return segments, _StubInfo(language=returned_language)

    def detect_language(self, samples, **kwargs):
        type(self).last_detect_call = {**kwargs, "n_samples": len(samples)}
        if type(self).detect_language_error is not None:
            raise type(self).detect_language_error
        return type(self).detect_language_result


@pytest.fixture(autouse=True)
def _reset_stub_whisper_model() -> None:
    """Every test starts with a clean `_StubWhisperModel` class state.

    Needed because `construct_count`/`last_call`/`detect_language_*` are
    class attributes shared across every test in this module.
    """
    _StubWhisperModel.construct_count = 0
    _StubWhisperModel.last_call = None
    _StubWhisperModel.last_detect_call = None
    _StubWhisperModel.detect_language_error = None
    _StubWhisperModel.detect_language_result = ("en", 0.9, [("en", 0.9), ("sv", 0.05)])


class _RaisingWhisperModel:
    def __init__(self, *args, **kwargs) -> None:
        pass

    def transcribe(self, *args, **kwargs):
        raise RuntimeError("inference exploded")


class TestStubbedTranscription:
    def test_joins_and_strips_segments_and_forwards_options(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr("faster_whisper.WhisperModel", _StubWhisperModel)
        engine = FasterWhisperEngine(model="tiny", beam_size=3, vad_filter=False)

        result = engine.transcribe(_samples(2.0), language="en")

        assert result.text == "hello world"
        assert [s.text for s in result.segments] == ["hello", "world"]
        assert result.segments[0].start == 0.0
        assert result.segments[1].end == 2.0
        assert result.language == "en"
        assert result.audio_seconds == pytest.approx(2.0)
        assert _StubWhisperModel.last_call == {
            "language": "en",
            "beam_size": 3,
            "vad_filter": False,
            "n_samples": 32_000,
        }

    def test_wraps_transcription_failure(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr("faster_whisper.WhisperModel", _RaisingWhisperModel)
        engine = FasterWhisperEngine(model="tiny")

        with pytest.raises(TranscriptionError, match="inference exploded"):
            engine.transcribe(_samples(1.0))

    def test_wraps_model_load_failure(self, monkeypatch: pytest.MonkeyPatch) -> None:
        class _RaisingConstructor:
            def __init__(self, *args, **kwargs) -> None:
                raise OSError("no such model")

        monkeypatch.setattr("faster_whisper.WhisperModel", _RaisingConstructor)
        engine = FasterWhisperEngine(model="does-not-exist")

        with pytest.raises(TranscriptionError, match="no such model"):
            engine.transcribe(_samples(1.0))

    def test_unload_forces_the_model_to_reload_on_next_transcribe(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        _StubWhisperModel.construct_count = 0
        monkeypatch.setattr("faster_whisper.WhisperModel", _StubWhisperModel)
        engine = FasterWhisperEngine(model="tiny")
        engine.transcribe(_samples(0.1))
        assert _StubWhisperModel.construct_count == 1

        engine.unload()
        engine.transcribe(_samples(0.1))

        assert _StubWhisperModel.construct_count == 2


class _LoadTrackingWhisperModel:
    """Stand-in for `WhisperModel` that records every construction's kwargs.

    Used to test `_load_model`'s local-first / download-fallback logic in
    isolation from transcription itself (every test here passes an
    explicit `language`, so `detect_language` is never involved).
    """

    construct_count = 0
    construct_calls: list[dict] = []
    #: If set, raise this when constructed with `local_files_only=True`
    #: (simulating "model not cached locally yet").
    raise_when_local_only: Exception | None = None

    def __init__(self, model_name: str, **kwargs) -> None:
        type(self).construct_count += 1
        type(self).construct_calls.append({"model_name": model_name, **kwargs})
        if kwargs.get("local_files_only") and type(self).raise_when_local_only is not None:
            raise type(self).raise_when_local_only
        self.model_name = model_name

    def transcribe(self, samples, **kwargs):
        return iter([]), _StubInfo(language=kwargs.get("language") or "en")


@pytest.fixture(autouse=True)
def _reset_load_tracking_whisper_model() -> None:
    _LoadTrackingWhisperModel.construct_count = 0
    _LoadTrackingWhisperModel.construct_calls = []
    _LoadTrackingWhisperModel.raise_when_local_only = None


class TestModelLoading:
    """`FasterWhisperEngine._load_model`'s local-files-first / download-fallback behavior."""

    def test_cached_model_loads_with_local_files_only_and_a_single_construction(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr("faster_whisper.WhisperModel", _LoadTrackingWhisperModel)
        engine = FasterWhisperEngine(model="tiny")

        engine.transcribe(_samples(0.1), language="en")

        assert _LoadTrackingWhisperModel.construct_count == 1
        assert _LoadTrackingWhisperModel.construct_calls[0]["local_files_only"] is True

    def test_uncached_model_falls_back_to_downloading(
        self, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
    ) -> None:
        monkeypatch.setattr("faster_whisper.WhisperModel", _LoadTrackingWhisperModel)
        _LoadTrackingWhisperModel.raise_when_local_only = RuntimeError("not cached")
        engine = FasterWhisperEngine(model="tiny")

        with caplog.at_level(logging.INFO, logger="dikta.engines.stt"):
            engine.transcribe(_samples(0.1), language="en")

        assert _LoadTrackingWhisperModel.construct_count == 2
        assert _LoadTrackingWhisperModel.construct_calls[0]["local_files_only"] is True
        assert _LoadTrackingWhisperModel.construct_calls[1]["local_files_only"] is False
        assert any("downloading model" in record.message for record in caplog.records)

    def test_offline_mode_raises_instead_of_downloading_and_only_tries_once(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr("faster_whisper.WhisperModel", _LoadTrackingWhisperModel)
        _LoadTrackingWhisperModel.raise_when_local_only = RuntimeError("not cached")
        engine = FasterWhisperEngine(model="tiny", offline=True)

        with pytest.raises(TranscriptionError, match="offline mode is on"):
            engine.transcribe(_samples(0.1), language="en")

        assert _LoadTrackingWhisperModel.construct_count == 1


class TestLanguageDetection:
    """`FasterWhisperEngine`'s candidate-restricted auto-detection (`language=None`)."""

    def test_picks_highest_probability_candidate_when_it_narrowly_beats_the_next_one(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr("faster_whisper.WhisperModel", _StubWhisperModel)
        _StubWhisperModel.detect_language_result = (
            "sv",
            0.44,
            [("sv", 0.44), ("en", 0.41), ("no", 0.10)],
        )
        engine = FasterWhisperEngine(model="tiny", candidate_languages=("en", "sv"))

        result = engine.transcribe(_samples(1.0))

        assert _StubWhisperModel.last_detect_call is not None
        assert _StubWhisperModel.last_call["language"] == "sv"
        assert result.language == "sv"

    def test_ignores_a_noncandidate_language_even_if_it_has_the_highest_probability(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr("faster_whisper.WhisperModel", _StubWhisperModel)
        _StubWhisperModel.detect_language_result = (
            "no",
            0.50,
            [("no", 0.50), ("sv", 0.30), ("en", 0.20)],
        )
        engine = FasterWhisperEngine(model="tiny", candidate_languages=("en", "sv"))

        result = engine.transcribe(_samples(1.0))

        assert _StubWhisperModel.last_call["language"] == "sv"
        assert result.language == "sv"

    def test_no_candidates_skips_detect_language_and_uses_multi_window_transcribe(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr("faster_whisper.WhisperModel", _StubWhisperModel)
        engine = FasterWhisperEngine(
            model="tiny", candidate_languages=None, language_detection_segments=5
        )

        engine.transcribe(_samples(1.0))

        assert _StubWhisperModel.last_detect_call is None
        assert _StubWhisperModel.last_call["language"] is None
        assert _StubWhisperModel.last_call["language_detection_segments"] == 5

    def test_explicit_language_skips_detect_language(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr("faster_whisper.WhisperModel", _StubWhisperModel)
        engine = FasterWhisperEngine(model="tiny", candidate_languages=("en", "sv"))

        result = engine.transcribe(_samples(1.0), language="en")

        assert _StubWhisperModel.last_detect_call is None
        assert _StubWhisperModel.last_call["language"] == "en"
        assert result.language == "en"

    def test_detect_language_failure_falls_back_to_unrestricted_autodetect(
        self, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
    ) -> None:
        monkeypatch.setattr("faster_whisper.WhisperModel", _StubWhisperModel)
        _StubWhisperModel.detect_language_error = RuntimeError("boom")
        engine = FasterWhisperEngine(
            model="tiny", candidate_languages=("en", "sv"), language_detection_segments=5
        )

        with caplog.at_level(logging.WARNING, logger="dikta.engines.stt"):
            engine.transcribe(_samples(1.0))

        assert _StubWhisperModel.last_call["language"] is None
        assert _StubWhisperModel.last_call["language_detection_segments"] == 5
        assert any(
            "language detection failed" in record.message and "boom" in record.message
            for record in caplog.records
        )


@pytest.mark.real
@pytest.mark.skipif(
    os.environ.get("DIKTA_REAL_STT") != "1",
    reason="set DIKTA_REAL_STT=1 to download and run a real model",
)
class TestRealTinyModel:
    def test_transcribes_silence(self) -> None:
        engine = FasterWhisperEngine(model="tiny")
        samples = _samples(2.0)

        result = engine.transcribe(samples)

        assert result.audio_seconds == pytest.approx(2.0)
        assert engine.name == "faster-whisper:tiny"

    def test_detect_language_returns_probabilities_for_a_sine_wave(self) -> None:
        """No transcript text asserted -- only that `detect_language` itself works end to end."""
        from faster_whisper import WhisperModel

        model = WhisperModel("tiny")
        t = np.linspace(0, 2.0, int(2.0 * 16_000), endpoint=False, dtype=np.float32)
        sine = (0.1 * np.sin(2 * np.pi * 440.0 * t)).astype(np.float32)

        language, probability, all_language_probs = model.detect_language(
            sine, language_detection_segments=1
        )

        assert isinstance(language, str) and language
        assert 0.0 <= probability <= 1.0
        assert len(all_language_probs) > 0
