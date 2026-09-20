"""Tests for `dikta.core.debrief.sanitizer`, ported from `TranscriptSanitizerTests`
(`DiktaTests/DebriefPipelineTests.swift:144-169`).
"""

from __future__ import annotations

import pytest

from dikta.core.debrief.sanitizer import is_effectively_empty, matched_silence_indicator


@pytest.mark.parametrize(
    "text",
    ["", "   ", "\n\n", "[BLANK_AUDIO]", "[silence]", " [ Silence ] ", "(silence)", "[NO SPEECH]"],
)
def test_is_effectively_empty_for_blank_and_markers(text: str) -> None:
    assert is_effectively_empty(text) is True


@pytest.mark.parametrize(
    "text",
    [
        "We met with the supplier today.",
        "Okej så vi träffade leverantören idag.",
        "silence is golden, but this isn't blank",
    ],
)
def test_is_effectively_empty_for_real_speech(text: str) -> None:
    assert is_effectively_empty(text) is False


def test_matched_silence_indicator_names_the_marker() -> None:
    assert matched_silence_indicator("[BLANK_AUDIO]") == "[blank_audio]"
    assert matched_silence_indicator(" [ Silence ] ") == "[ silence ]"
    assert matched_silence_indicator("(silence)") == "(silence)"
    assert matched_silence_indicator("[NO SPEECH]") == "[no speech]"
    assert matched_silence_indicator("real content") is None
