"""Protocol shared by all debrief summarizer engines.

Port of the `DebriefSummarizer` protocol
(`Services/Debrief/DebriefSummarizer.swift:9-14`). Synchronous here — the
Swift original's `async` methods have no equivalent since this pipeline
runs in a worker subprocess, not an event loop.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from dikta.core.debrief.model import DebriefSummary

__all__ = ["Summarizer"]


@runtime_checkable
class Summarizer(Protocol):
    """Turns a transcript into a structured `DebriefSummary`."""

    @property
    def name(self) -> str:
        """Short identifier for this engine and its configuration."""
        ...

    def is_available(self) -> bool:
        """Whether this engine can currently be used (e.g. its backend is reachable)."""
        ...

    def summarize(self, transcript: str, language: str) -> DebriefSummary:
        """Summarize `transcript` (spoken in `language`, e.g. "en"/"sv").

        Raises:
            SummarizerError: (or a subclass) on failure.
        """
        ...
