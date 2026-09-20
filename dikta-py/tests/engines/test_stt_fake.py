from __future__ import annotations

import numpy as np
import pytest

from dikta.engines.stt.base import SpeechToText
from dikta.engines.stt.fake import FakeSpeechToText


def _samples(seconds: float, sample_rate: int = 16_000) -> np.ndarray:
    return np.zeros(int(seconds * sample_rate), dtype=np.float32)


class TestFixedText:
    def test_returns_fixed_text_as_a_single_segment(self) -> None:
        engine = FakeSpeechToText(text="hello world")
        samples = _samples(2.0)

        result = engine.transcribe(samples, language="en")

        assert result.text == "hello world"
        assert len(result.segments) == 1
        assert result.segments[0].text == "hello world"
        assert result.segments[0].start == 0.0
        assert result.segments[0].end == pytest.approx(result.audio_seconds)
        assert result.language == "en"
        assert result.audio_seconds == pytest.approx(2.0)

    def test_name_is_fake(self) -> None:
        assert FakeSpeechToText().name == "fake"

    def test_satisfies_speech_to_text_protocol(self) -> None:
        assert isinstance(FakeSpeechToText("x"), SpeechToText)


class TestResponder:
    def test_responder_receives_samples_and_language(self) -> None:
        seen: list[tuple[int, str | None]] = []

        def responder(samples: np.ndarray, language: str | None) -> str:
            seen.append((len(samples), language))
            return f"transcribed {len(samples)} samples in {language}"

        engine = FakeSpeechToText(responder=responder)
        samples = _samples(1.0)

        result = engine.transcribe(samples, language="sv")

        assert seen == [(16_000, "sv")]
        assert result.text == "transcribed 16000 samples in sv"


class TestCallRecording:
    def test_records_every_call(self) -> None:
        engine = FakeSpeechToText(text="x")

        engine.transcribe(_samples(1.0), language="en")
        engine.transcribe(_samples(0.5), language=None)

        assert engine.calls == [(16_000, "en"), (8_000, None)]

    def test_records_language_none_when_called_with_the_default(self) -> None:
        engine = FakeSpeechToText(text="x")

        engine.transcribe(_samples(1.0))  # no `language` argument at all

        assert engine.calls == [(16_000, None)]


class TestRaiseError:
    def test_raises_configured_error_instead_of_transcribing(self) -> None:
        boom = RuntimeError("boom")
        engine = FakeSpeechToText(text="never returned", raise_error=boom)

        with pytest.raises(RuntimeError, match="boom"):
            engine.transcribe(_samples(1.0))

        # The call is still recorded even though it raised.
        assert engine.calls == [(16_000, None)]
