"""Debrief summarizer engines: protocol, implementations, and factory."""

from __future__ import annotations

from dikta.engines.llm.base import Summarizer
from dikta.engines.llm.chained import ChainedSummarizer
from dikta.engines.llm.errors import (
    BadResponse,
    EmptyTranscript,
    SummarizerError,
    SummarizerHTTPError,
    SummarizerTimeout,
    SummarizerUnavailable,
)
from dikta.engines.llm.factory import (
    DEFAULT_OLLAMA_BASE_URL,
    DEFAULT_OLLAMA_MODEL,
    EngineKind,
    make_summarizer,
)
from dikta.engines.llm.fake import FakeSummarizer
from dikta.engines.llm.heuristic import HeuristicSummarizer
from dikta.engines.llm.ollama import OllamaSummarizer

__all__ = [
    "Summarizer",
    "ChainedSummarizer",
    "SummarizerError",
    "SummarizerUnavailable",
    "EmptyTranscript",
    "BadResponse",
    "SummarizerHTTPError",
    "SummarizerTimeout",
    "EngineKind",
    "DEFAULT_OLLAMA_MODEL",
    "DEFAULT_OLLAMA_BASE_URL",
    "make_summarizer",
    "FakeSummarizer",
    "HeuristicSummarizer",
    "OllamaSummarizer",
]
