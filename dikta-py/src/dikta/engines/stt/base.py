"""Protocol and value types shared by all speech-to-text engines."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, runtime_checkable

import numpy as np

__all__ = [
    "TranscriptSegment",
    "TranscriptionResult",
    "TranscriptionError",
    "SpeechToText",
]


@dataclass(frozen=True)
class TranscriptSegment:
    """A single timed span of transcribed text."""

    text: str
    start: float
    end: float


@dataclass(frozen=True)
class TranscriptionResult:
    """The full result of transcribing one chunk of audio."""

    text: str
    segments: tuple[TranscriptSegment, ...]
    language: str | None
    audio_seconds: float


class TranscriptionError(Exception):
    """Raised when a `SpeechToText` engine fails to transcribe audio."""


@runtime_checkable
class SpeechToText(Protocol):
    """A speech-to-text engine.

    `samples` passed to `transcribe` are always 16 kHz mono float32 in
    [-1, 1] — the format produced by `dikta.engines.audio.AudioFileLoader`.
    """

    @property
    def name(self) -> str:
        """Short identifier for this engine and its configuration."""
        ...

    def transcribe(self, samples: np.ndarray, language: str | None = None) -> TranscriptionResult:
        """Transcribe `samples`.

        Args:
            samples: 16 kHz mono float32 audio in [-1, 1].
            language: ISO 639-1 code (e.g. "en", "sv") to force, or None to
                auto-detect.

        Raises:
            TranscriptionError: the engine failed to produce a result.
        """
        ...
