"""In-memory `Summarizer` fake for tests."""

from __future__ import annotations

from dikta.core.debrief.model import DebriefSummary

__all__ = ["FakeSummarizer"]


class FakeSummarizer:
    """A `Summarizer` that returns a canned result or raises a canned error.

    Every call is recorded in `calls` as `(transcript, language)`.
    """

    def __init__(
        self,
        result: DebriefSummary | None = None,
        error: Exception | None = None,
        available: bool = True,
        name: str = "fake",
    ) -> None:
        self.result = result if result is not None else DebriefSummary(summary="")
        self.error = error
        self.available = available
        self.name = name
        self.calls: list[tuple[str, str]] = []

    def is_available(self) -> bool:
        return self.available

    def summarize(self, transcript: str, language: str) -> DebriefSummary:
        self.calls.append((transcript, language))
        if self.error is not None:
            raise self.error
        return self.result

    @property
    def summarize_call_count(self) -> int:
        return len(self.calls)
