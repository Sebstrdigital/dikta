"""Ollama-backed debrief summarizer.

Port of `OllamaDebriefSummarizer` (`Services/Debrief/OllamaDebriefSummarizer.swift`).
"""

from __future__ import annotations

from types import TracebackType

import httpx

from dikta.core.debrief.model import DebriefSummary
from dikta.core.debrief.parser import parse_summary
from dikta.core.debrief.prompts import system_prompt, user_prompt
from dikta.engines.llm.errors import (
    BadResponse,
    EmptyTranscript,
    SummarizerHTTPError,
    SummarizerTimeout,
    SummarizerUnavailable,
)

__all__ = ["OllamaSummarizer"]

_DEFAULT_BASE_URL = "http://127.0.0.1:11434"
_AVAILABILITY_TIMEOUT = 2.0


class OllamaSummarizer:
    """Summarizes transcripts via a local Ollama chat model.

    Accepts an injected `httpx.Client` so tests can supply
    `httpx.MockTransport` instead of hitting a real server.
    """

    name = "Ollama"

    def __init__(
        self,
        model: str,
        base_url: str = _DEFAULT_BASE_URL,
        timeout: float = 180.0,
        temperature: float = 0.0,
        client: httpx.Client | None = None,
    ) -> None:
        self.model = model
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.temperature = temperature
        # Only close the client on `close()`/context-manager exit if we
        # created it ourselves — an injected client (e.g. a test's
        # `httpx.MockTransport`-backed client) is owned by its caller.
        self._owns_client = client is None
        self._client = client or httpx.Client()

    def close(self) -> None:
        """Close the underlying HTTP client, if this instance owns it."""
        if self._owns_client:
            self._client.close()

    def __enter__(self) -> OllamaSummarizer:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()

    @staticmethod
    def model_matches(server_name: str, configured_model: str) -> bool:
        """Whether an Ollama-reported `server_name` satisfies `configured_model`.

        Exact match always counts. A tagged `configured_model` (e.g.
        `"llama3:8b"`) only matches that exact tag. An untagged
        `configured_model` (e.g. `"llama3"`) matches any `server_name` with
        that prefix followed by `":"`. Mirrors
        `modelMatches(serverName:configuredModel:)`
        (`OllamaDebriefSummarizer.swift:61-69`).
        """
        if server_name == configured_model:
            return True
        if ":" in configured_model:
            return False
        return server_name.startswith(configured_model + ":")

    def is_available(self) -> bool:
        """`GET /api/tags` (2s timeout); True iff any listed model satisfies `model_matches`."""
        try:
            response = self._client.get(f"{self.base_url}/api/tags", timeout=_AVAILABILITY_TIMEOUT)
        except httpx.HTTPError:
            return False
        if response.status_code != 200:
            return False
        try:
            data = response.json()
            names = [entry["name"] for entry in data["models"]]
        except (ValueError, KeyError, TypeError):
            return False
        return any(self.model_matches(name, self.model) for name in names)

    def summarize(self, transcript: str, language: str) -> DebriefSummary:
        """`POST /api/chat` with the debrief system/user prompts, then parse the response.

        Mirrors `summarize(transcript:language:)`
        (`OllamaDebriefSummarizer.swift:71-119`). `isLabeledTranscript` is
        always `False` here — the two-track detection this depends on is
        out of scope for this (single-track, file-import) port.

        Raises:
            EmptyTranscript: `transcript` is blank after trimming.
            SummarizerTimeout: the request exceeded `self.timeout`.
            SummarizerUnavailable: any other network/connection error.
            SummarizerHTTPError: the server responded with a non-200 status.
            BadResponse: the response body couldn't be decoded, or its
                `message.content` couldn't be parsed as a summary.
        """
        trimmed = transcript.strip()
        if not trimmed:
            raise EmptyTranscript()

        body = {
            "model": self.model,
            "stream": False,
            "format": "json",
            "options": {"temperature": self.temperature},
            "messages": [
                {"role": "system", "content": system_prompt(language)},
                {"role": "user", "content": user_prompt(trimmed, language)},
            ],
        }

        try:
            response = self._client.post(
                f"{self.base_url}/api/chat",
                json=body,
                timeout=self.timeout,
                headers={"Content-Type": "application/json"},
            )
        except httpx.TimeoutException as exc:
            raise SummarizerTimeout() from exc
        except httpx.HTTPError as exc:
            raise SummarizerUnavailable(str(exc)) from exc

        if response.status_code != 200:
            raise SummarizerHTTPError(response.status_code)

        try:
            data = response.json()
            content = data["message"]["content"]
        except (ValueError, KeyError, TypeError) as exc:
            raise BadResponse(str(exc)) from exc

        return parse_summary(content)
