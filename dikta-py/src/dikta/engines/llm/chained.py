"""Chained summarizer that tries engines in order, falling through on failure.

Port of `ChainedDebriefSummarizer` (`Services/Debrief/DebriefSummarizer.swift:336-383`).

Python is synchronous here — the pipeline runs in a worker subprocess, not
an event loop — so there is no task-cancellation concept to port. The Swift
original's `Task.checkCancellation()` / immediate-`CancellationError`-
rethrow behavior between engines has no equivalent and is intentionally
omitted.
"""

from __future__ import annotations

from collections.abc import Sequence

from dikta.core.debrief.model import DebriefSummary
from dikta.engines.llm.base import Summarizer
from dikta.engines.llm.errors import EmptyTranscript, SummarizerUnavailable

__all__ = ["ChainedSummarizer"]


class ChainedSummarizer:
    """Tries each engine in order; returns the first successful result."""

    name = "Chained"

    def __init__(self, engines: Sequence[Summarizer]) -> None:
        self._engines = list(engines)
        self.last_used_engine_name: str | None = None

    @property
    def engine_names(self) -> list[str]:
        """Engine names in try order (diagnostic helper)."""
        return [engine.name for engine in self._engines]

    def is_available(self) -> bool:
        """True iff any engine (in order) reports itself available."""
        return any(engine.is_available() for engine in self._engines)

    def summarize(self, transcript: str, language: str) -> DebriefSummary:
        """Try each available engine in order; return the first success.

        An empty (post-trim) `transcript` raises `EmptyTranscript`
        immediately, before touching any engine. Otherwise, unavailable
        engines are skipped; any other error from an engine is recorded and
        the next engine is tried. If every engine is skipped or fails, the
        last recorded error is re-raised, else `SummarizerUnavailable`.
        """
        if not transcript.strip():
            raise EmptyTranscript()

        last_error: Exception | None = None
        for engine in self._engines:
            if not engine.is_available():
                continue
            try:
                result = engine.summarize(transcript, language)
            except Exception as exc:  # noqa: BLE001 - any engine failure falls through
                last_error = exc
                continue
            self.last_used_engine_name = engine.name
            return result

        self.last_used_engine_name = None
        if last_error is not None:
            raise last_error
        raise SummarizerUnavailable("No summarizer engine is available.")
