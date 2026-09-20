"""Detect silence-marker transcripts that shouldn't be summarized.

Port of `TranscriptSanitizer` (`Services/TranscriptSanitizer.swift`, 34
lines, complete). Applied in the pipeline after the raw transcript is
written to disk but before summarization — see spec section 13.
"""

from __future__ import annotations

__all__ = ["SILENCE_INDICATORS", "matched_silence_indicator", "is_effectively_empty"]

#: Substrings (lowercase) that indicate a Whisper "no speech" marker rather
#: than real transcribed content. Checked in this order; the first match
#: wins. Mirrors `silenceIndicators` (`TranscriptSanitizer.swift`).
SILENCE_INDICATORS: tuple[str, ...] = (
    "[silence]",
    "[blank_audio]",
    "[no speech]",
    "(silence)",
    "[ silence ]",
)


def matched_silence_indicator(text: str) -> str | None:
    """Return the first `SILENCE_INDICATORS` entry found as a substring of `text`, or `None`."""
    lowered = text.lower().strip()
    for indicator in SILENCE_INDICATORS:
        if indicator in lowered:
            return indicator
    return None


def is_effectively_empty(text: str) -> bool:
    """True if `text` is blank after trimming, or contains a silence marker."""
    lowered = text.lower().strip()
    if not lowered:
        return True
    return matched_silence_indicator(text) is not None
