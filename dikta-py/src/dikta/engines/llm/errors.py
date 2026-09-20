"""Errors raised by debrief summarizer engines.

Pure re-export of `dikta.core.debrief.errors` — the canonical definitions
live in `core/` (see that module's docstring for why), but engine code
imports them from here for a natural `engines.llm.errors.X` path.
"""

from __future__ import annotations

from dikta.core.debrief.errors import (
    BadResponse,
    EmptyTranscript,
    SummarizerError,
    SummarizerHTTPError,
    SummarizerTimeout,
    SummarizerUnavailable,
)

__all__ = [
    "SummarizerError",
    "SummarizerUnavailable",
    "EmptyTranscript",
    "BadResponse",
    "SummarizerHTTPError",
    "SummarizerTimeout",
]
