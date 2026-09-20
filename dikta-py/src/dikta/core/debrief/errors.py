"""Errors raised by debrief summarizer engines.

Port of `DebriefSummarizerError` (`Services/Debrief/DebriefSummarizer.swift:9-43`).
Message text mirrors the Swift `errorDescription` strings so error text
stays consistent across ports.

Lives under `core.debrief` (not `engines.llm`) because `core.debrief.parser`
needs these types and `core/` must never import from `engines/`. See
`dikta.engines.llm.errors` for the (re-exported) public entry point engine
code imports.
"""

from __future__ import annotations

__all__ = [
    "SummarizerError",
    "SummarizerUnavailable",
    "EmptyTranscript",
    "BadResponse",
    "SummarizerHTTPError",
    "SummarizerTimeout",
]


class SummarizerError(Exception):
    """Base class for all debrief summarizer errors."""


class SummarizerUnavailable(SummarizerError):
    """The engine could not be reached, or has no usable model configured."""

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"Summarizer unavailable: {reason}")


class EmptyTranscript(SummarizerError):
    """The transcript was blank (or a silence marker) with nothing to summarize."""

    def __init__(self) -> None:
        super().__init__("Transcript is empty.")


class BadResponse(SummarizerError):
    """The engine's raw output could not be parsed into a `DebriefSummary`."""

    def __init__(self, excerpt: str) -> None:
        self.excerpt = excerpt
        super().__init__(f"Summarizer returned an unparsable response: {excerpt}")


class SummarizerHTTPError(SummarizerError):
    """The engine's HTTP backend returned a non-200 status."""

    def __init__(self, status: int) -> None:
        self.status = status
        super().__init__(f"Summarizer HTTP request failed with status {status}.")


class SummarizerTimeout(SummarizerError):
    """The engine did not respond within its configured timeout."""

    def __init__(self) -> None:
        super().__init__("Summarizer timed out.")
