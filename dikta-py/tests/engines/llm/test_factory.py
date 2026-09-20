"""Tests for `dikta.engines.llm.factory`, ported from `DebriefSummarizerFactoryTests`
(`DiktaTests/DebriefSummaryTests.swift`).
"""

from __future__ import annotations

import pytest

from dikta.engines.llm.chained import ChainedSummarizer
from dikta.engines.llm.factory import EngineKind, make_summarizer
from dikta.engines.llm.heuristic import HeuristicSummarizer
from dikta.engines.llm.ollama import OllamaSummarizer


def test_heuristic_kind_returns_heuristic_summarizer() -> None:
    summarizer = make_summarizer(EngineKind.HEURISTIC)
    assert isinstance(summarizer, HeuristicSummarizer)


def test_ollama_kind_returns_ollama_summarizer() -> None:
    summarizer = make_summarizer(EngineKind.OLLAMA, ollama_model="llama3")
    assert isinstance(summarizer, OllamaSummarizer)
    assert summarizer.model == "llama3"


def test_auto_kind_returns_chain_ending_in_heuristic() -> None:
    summarizer = make_summarizer(EngineKind.AUTO)
    assert isinstance(summarizer, ChainedSummarizer)
    assert summarizer.engine_names[-1] == "Heuristic"
    assert "Ollama" in summarizer.engine_names


@pytest.mark.skip(
    reason="out of scope: DebriefSummarizerFactoryTests."
    "test_autoKind_startsWithFoundationModelsWhenAvailableOnThisOS — macOS 26+ on-device "
    "Foundation Models engine has no Python equivalent; EngineKind has no FOUNDATION_MODELS case."
)
def test_auto_kind_starts_with_foundation_models_when_available_on_this_os() -> None:
    pass
