"""Speech-to-text engines."""

from __future__ import annotations

from dikta.engines.stt.base import (
    SpeechToText,
    TranscriptionError,
    TranscriptionResult,
    TranscriptSegment,
)
from dikta.engines.stt.fake import FakeSpeechToText
from dikta.engines.stt.faster_whisper_engine import FasterWhisperEngine

__all__ = [
    "SpeechToText",
    "TranscriptionError",
    "TranscriptionResult",
    "TranscriptSegment",
    "FakeSpeechToText",
    "FasterWhisperEngine",
]
