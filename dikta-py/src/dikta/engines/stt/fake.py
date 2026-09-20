"""In-memory `SpeechToText` fake for tests."""

from __future__ import annotations

from collections.abc import Callable

import numpy as np

from dikta.engines.stt.base import TranscriptionResult, TranscriptSegment

__all__ = ["FakeSpeechToText"]

# `SpeechToText.transcribe` always receives 16 kHz mono audio (see base.py);
# hardcoded here rather than imported from the audio engine to avoid coupling
# this test double to that package.
_SAMPLE_RATE = 16_000


class FakeSpeechToText:
    """A `SpeechToText` engine that returns canned text instead of transcribing.

    Construct with a fixed `text`, or a `responder` callback for
    input-dependent output. Every call is recorded in `calls` as
    `(sample_count, language)`.
    """

    name = "fake"

    def __init__(
        self,
        text: str = "",
        *,
        responder: Callable[[np.ndarray, str | None], str] | None = None,
        raise_error: Exception | None = None,
    ) -> None:
        self._text = text
        self._responder = responder
        self.raise_error = raise_error
        self.calls: list[tuple[int, str | None]] = []

    def transcribe(self, samples: np.ndarray, language: str | None = None) -> TranscriptionResult:
        self.calls.append((len(samples), language))
        if self.raise_error is not None:
            raise self.raise_error

        text = self._responder(samples, language) if self._responder is not None else self._text
        audio_seconds = len(samples) / _SAMPLE_RATE
        segment = TranscriptSegment(text=text, start=0.0, end=audio_seconds)
        return TranscriptionResult(
            text=text,
            segments=(segment,),
            language=language,
            audio_seconds=audio_seconds,
        )
