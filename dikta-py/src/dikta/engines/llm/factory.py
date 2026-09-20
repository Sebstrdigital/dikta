"""Constructs a `Summarizer` engine (or chain of engines) by configuration kind.

Port of `DebriefSummarizerFactory` / `DebriefEngineKind`
(`Services/Debrief/DebriefSummarizer.swift:301-330`). The Swift
`foundationModels` case (macOS 26+ on-device model) has no Python
equivalent and is intentionally omitted — see port-spec section 7/15.3.
"""

from __future__ import annotations

from enum import StrEnum

from dikta.engines.llm.base import Summarizer
from dikta.engines.llm.chained import ChainedSummarizer
from dikta.engines.llm.heuristic import HeuristicSummarizer
from dikta.engines.llm.ollama import OllamaSummarizer

__all__ = ["EngineKind", "DEFAULT_OLLAMA_MODEL", "DEFAULT_OLLAMA_BASE_URL", "make_summarizer"]

#: Mirrors `AppConfig.defaultOllamaModel` (`Models/AppConfig.swift:103`).
DEFAULT_OLLAMA_MODEL = "qwen3:4b"

#: Mirrors `OllamaDebriefSummarizer`'s default `baseURL` init parameter.
DEFAULT_OLLAMA_BASE_URL = "http://127.0.0.1:11434"


class EngineKind(StrEnum):
    """Which summarizer engine(s) to use. No `FOUNDATION_MODELS` case — see module docstring."""

    AUTO = "auto"
    OLLAMA = "ollama"
    HEURISTIC = "heuristic"


def make_summarizer(
    kind: EngineKind,
    ollama_model: str = DEFAULT_OLLAMA_MODEL,
    ollama_base_url: str = DEFAULT_OLLAMA_BASE_URL,
) -> Summarizer:
    """Build the summarizer engine for `kind`.

    `EngineKind.AUTO` returns a `ChainedSummarizer` trying `Ollama` first,
    then falling back to the always-available `Heuristic` engine, which is
    always last and always available — guaranteeing `AUTO` never fully
    fails.
    """
    if kind is EngineKind.HEURISTIC:
        return HeuristicSummarizer()
    if kind is EngineKind.OLLAMA:
        return OllamaSummarizer(model=ollama_model, base_url=ollama_base_url)
    return ChainedSummarizer(
        [
            OllamaSummarizer(model=ollama_model, base_url=ollama_base_url),
            HeuristicSummarizer(),
        ]
    )
