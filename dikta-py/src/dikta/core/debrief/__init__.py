"""Domain model and pure-logic helpers for the meeting debrief feature."""

from __future__ import annotations

from dikta.core.debrief.errors import (
    BadResponse,
    EmptyTranscript,
    SummarizerError,
    SummarizerHTTPError,
    SummarizerTimeout,
    SummarizerUnavailable,
)
from dikta.core.debrief.model import ActionItem, DebriefSummary
from dikta.core.debrief.parser import parse_summary
from dikta.core.debrief.prompts import system_prompt, user_prompt
from dikta.core.debrief.render import render_plain_text
from dikta.core.debrief.sanitizer import is_effectively_empty
from dikta.core.debrief.store import DebriefStore, SessionPaths, default_root

__all__ = [
    "ActionItem",
    "DebriefSummary",
    "parse_summary",
    "render_plain_text",
    "system_prompt",
    "user_prompt",
    "is_effectively_empty",
    "SummarizerError",
    "SummarizerUnavailable",
    "EmptyTranscript",
    "BadResponse",
    "SummarizerHTTPError",
    "SummarizerTimeout",
    "DebriefStore",
    "SessionPaths",
    "default_root",
]
