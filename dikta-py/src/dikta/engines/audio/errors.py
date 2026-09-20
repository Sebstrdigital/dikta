"""Errors raised by :mod:`dikta.engines.audio`.

Mirrors ``AudioFileLoaderError`` from the macOS Swift implementation
(``dikta-macos/Dikta/Services/Debrief/AudioFileLoader.swift``), including
its message wording, so error text stays consistent across ports.
"""

from __future__ import annotations

from pathlib import Path

__all__ = [
    "AudioFileError",
    "AudioFileUnreadable",
    "AudioFileUnsupportedFormat",
    "AudioConversionFailed",
    "AudioFileEmpty",
]


class AudioFileError(Exception):
    """Base class for all audio file loading errors."""


class AudioFileUnreadable(AudioFileError):
    """The file does not exist or could not be opened."""

    def __init__(self, path: Path | str) -> None:
        self.path = Path(path)
        super().__init__(f"Could not read audio file: {self.path.name}")


class AudioFileUnsupportedFormat(AudioFileError):
    """The file extension is not in :data:`SUPPORTED_EXTENSIONS`."""

    def __init__(self, path: Path | str) -> None:
        self.path = Path(path)
        super().__init__(f"Unsupported audio format: {self.path.name}")


class AudioConversionFailed(AudioFileError):
    """Decoding or resampling the file failed."""

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"Audio conversion failed: {reason}")


class AudioFileEmpty(AudioFileError):
    """The file decoded successfully but contains zero samples."""

    def __init__(self, path: Path | str) -> None:
        self.path = Path(path)
        super().__init__(f"Audio file contains no samples: {self.path.name}")
