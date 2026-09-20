"""Audio file loading for the transcription pipeline."""

from __future__ import annotations

from dikta.engines.audio.errors import (
    AudioConversionFailed,
    AudioFileEmpty,
    AudioFileError,
    AudioFileUnreadable,
    AudioFileUnsupportedFormat,
)
from dikta.engines.audio.loader import SUPPORTED_EXTENSIONS, TARGET_SAMPLE_RATE, AudioFileLoader

__all__ = [
    "AudioFileLoader",
    "SUPPORTED_EXTENSIONS",
    "TARGET_SAMPLE_RATE",
    "AudioFileError",
    "AudioFileUnreadable",
    "AudioFileUnsupportedFormat",
    "AudioConversionFailed",
    "AudioFileEmpty",
]
