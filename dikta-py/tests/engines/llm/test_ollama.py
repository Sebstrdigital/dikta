"""Tests for `dikta.engines.llm.ollama`.

Ported from `OllamaDebriefSummarizerTests` and
`OllamaDebriefSummarizerModelMatchesTests` (`DiktaTests/DebriefSummaryTests.swift`).
All requests go through `httpx.MockTransport` — no real network calls.
"""

from __future__ import annotations

import json
from collections.abc import Callable

import httpx
import pytest

from dikta.core.debrief.prompts import system_prompt, user_prompt
from dikta.engines.llm.errors import (
    BadResponse,
    EmptyTranscript,
    SummarizerHTTPError,
    SummarizerTimeout,
    SummarizerUnavailable,
)
from dikta.engines.llm.ollama import OllamaSummarizer


def _client(handler: Callable[[httpx.Request], httpx.Response]) -> httpx.Client:
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_is_available_true_when_model_listed() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"models": [{"name": "qwen3:4b"}, {"name": "llama3:8b"}]})

    summarizer = OllamaSummarizer(model="qwen3", client=_client(handler))
    assert summarizer.is_available() is True


def test_is_available_false_when_model_not_listed() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"models": [{"name": "llama3:8b"}]})

    summarizer = OllamaSummarizer(model="qwen3", client=_client(handler))
    assert summarizer.is_available() is False


def test_is_available_false_on_non200() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, text="unavailable")

    summarizer = OllamaSummarizer(model="qwen3", client=_client(handler))
    assert summarizer.is_available() is False


def test_summarize_parses_canned_chat_response() -> None:
    payload = {"summary": "Recap.", "decisions": ["A"], "actionItems": [], "openQuestions": []}
    content = json.dumps(payload)

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"message": {"role": "assistant", "content": content}})

    summarizer = OllamaSummarizer(model="qwen3:4b", client=_client(handler))
    result = summarizer.summarize("We talked about things.", "en")
    assert result.summary == "Recap."
    assert result.decisions == ["A"]


def test_summarize_throws_http_on_non200() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, text="server error")

    summarizer = OllamaSummarizer(model="qwen3:4b", client=_client(handler))
    with pytest.raises(SummarizerHTTPError) as exc_info:
        summarizer.summarize("We talked about things.", "en")
    assert exc_info.value.status == 503


def test_summarize_throws_empty_transcript() -> None:
    calls: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return httpx.Response(200, json={"message": {"role": "assistant", "content": "{}"}})

    summarizer = OllamaSummarizer(model="qwen3:4b", client=_client(handler))
    with pytest.raises(EmptyTranscript):
        summarizer.summarize("   \n  ", "en")
    assert calls == []  # no HTTP call made


def test_summarize_malformed_json_body_throws_bad_response() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"not json at all")

    summarizer = OllamaSummarizer(model="qwen3:4b", client=_client(handler))
    with pytest.raises(BadResponse):
        summarizer.summarize("We talked about things.", "en")


def test_summarize_other_url_error_maps_to_unavailable() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    summarizer = OllamaSummarizer(model="qwen3:4b", client=_client(handler))
    with pytest.raises(SummarizerUnavailable):
        summarizer.summarize("We talked about things.", "en")


def test_summarize_timed_out_url_error_maps_to_timeout() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.TimeoutException("timed out", request=request)

    summarizer = OllamaSummarizer(model="qwen3:4b", client=_client(handler))
    with pytest.raises(SummarizerTimeout):
        summarizer.summarize("We talked about things.", "en")


def test_summarize_request_body_matches_expected_shape() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.content)
        captured["url_path"] = request.url.path
        message = {"role": "assistant", "content": '{"summary": "x"}'}
        return httpx.Response(200, json={"message": message})

    summarizer = OllamaSummarizer(model="qwen3:4b", client=_client(handler))
    transcript = "We talked about things."
    summarizer.summarize(transcript, "en")

    assert captured["url_path"] == "/api/chat"

    body = captured["body"]
    assert body["model"] == "qwen3:4b"
    assert body["stream"] is False
    assert body["format"] == "json"
    assert body["options"]["temperature"] == 0
    assert len(body["messages"]) == 2
    assert body["messages"][0]["role"] == "system"
    assert body["messages"][0]["content"] == system_prompt("en")
    assert body["messages"][1]["role"] == "user"
    assert body["messages"][1]["content"] == user_prompt(transcript, "en")


def test_is_available_issues_request_with_two_second_timeout() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["timeout"] = request.extensions.get("timeout")
        return httpx.Response(200, json={"models": []})

    # Summarizer-level timeout is 180s (used for /api/chat); is_available's
    # own GET /api/tags must use its own fixed 2s timeout regardless.
    summarizer = OllamaSummarizer(model="qwen3:4b", timeout=180.0, client=_client(handler))
    summarizer.is_available()

    assert captured["timeout"] == {"connect": 2.0, "read": 2.0, "write": 2.0, "pool": 2.0}


@pytest.mark.parametrize(
    ("server_name", "configured_model", "expected"),
    [
        ("llama3:70b", "llama3:8b", False),
        ("llama3:8b", "llama3", True),
        ("llama3:8b", "llama3:8b", True),
        ("mistral:7b", "llama3", False),
    ],
)
def test_model_matches(server_name: str, configured_model: str, expected: bool) -> None:
    assert OllamaSummarizer.model_matches(server_name, configured_model) is expected


def test_close_closes_an_owned_client() -> None:
    summarizer = OllamaSummarizer(model="qwen3:4b")  # no injected client -> owns its own
    client = summarizer._client
    assert client.is_closed is False
    summarizer.close()
    assert client.is_closed is True


def test_close_does_not_close_an_injected_client() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"models": []})

    injected = _client(handler)
    summarizer = OllamaSummarizer(model="qwen3:4b", client=injected)
    summarizer.close()
    assert injected.is_closed is False


def test_context_manager_closes_an_owned_client() -> None:
    with OllamaSummarizer(model="qwen3:4b") as summarizer:
        client = summarizer._client
        assert client.is_closed is False
    assert client.is_closed is True
