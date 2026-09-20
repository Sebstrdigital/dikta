"""JSON-lines protocol between the parent process and the debrief worker subprocess.

One JSON object per line, UTF-8, no pretty-printing. The parent
(`dikta.worker.client.WorkerClient`) writes one `DebriefRequest` to the
child's stdin; the child (`dikta.worker.child`, run via
`dikta.worker.__main__`) writes a stream of `Event` lines to stdout, ending
in exactly one `ResultEvent` or `ErrorEvent`.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Annotated, Literal

from pydantic import BaseModel, Field, TypeAdapter, field_validator

from dikta.engines.llm.factory import DEFAULT_OLLAMA_BASE_URL, DEFAULT_OLLAMA_MODEL, EngineKind
from dikta.pipeline.file_debrief import Stage

__all__ = [
    "DebriefRequest",
    "ErrorKind",
    "StageEvent",
    "ResultEvent",
    "ErrorEvent",
    "LogEvent",
    "Event",
    "parse_event",
]

#: ISO 639-1/639-3 code shape, mirrored from `dikta.cli._LANGUAGE_CODE_PATTERN`
#: (not imported from there to avoid a `worker` -> `cli` dependency).
_LANGUAGE_CODE_PATTERN = re.compile(r"^[a-z]{2,3}$")

#: The `ErrorEvent.kind` values a worker child process can report, and the
#: exit codes `dikta.worker.child.run` maps them to (see that module).
ErrorKind = Literal[
    "empty_transcript",
    "transcription_timeout",
    "audio_file",
    "transcription",
    "summarizer",
    "unexpected",
]


class DebriefRequest(BaseModel):
    """What the parent sends the worker subprocess on stdin, as a single JSON object."""

    file: Path
    language: str | None = None
    stt_engine: Literal["faster-whisper", "fake"] = "faster-whisper"
    stt_model: str = "small"
    stt_device: str = "auto"
    stt_compute_type: str = "int8"
    #: Only used when `stt_engine == "fake"` — tests/bench only.
    fake_stt_text: str | None = None
    #: Artificial delay (seconds) the fake STT engine sleeps before
    #: returning `fake_stt_text` — tests only (e.g. exercising
    #: `WorkerClient.cancel()` against a slow-running child).
    fake_stt_delay: float = 0.0
    #: When true (and `stt_engine == "fake"`), the fake STT also does a
    #: Python-level `print()` and a raw `os.write(1, ...)` mid-transcribe —
    #: tests only, exercising the worker's stdout/protocol-pipe hygiene
    #: (`dikta.worker.__main__` redirects fd 1 away from these).
    debug_stray_stdout: bool = False
    engine_kind: EngineKind = EngineKind.AUTO
    ollama_model: str = DEFAULT_OLLAMA_MODEL
    ollama_base_url: str = DEFAULT_OLLAMA_BASE_URL
    store_root: Path | None = None
    transcription_timeout: float = 1800.0
    #: Restricts STT language auto-detection to these codes (the
    #: highest-probability one among them wins); `None` means unrestricted
    #: auto-detect across every language faster-whisper knows. Only
    #: consulted when `language` is `None`. See
    #: `dikta.engines.stt.faster_whisper_engine.FasterWhisperEngine`.
    candidate_languages: list[str] | None = ["en", "sv"]
    #: When true, `FasterWhisperEngine` never downloads an uncached STT
    #: model -- it raises instead of making the network call a
    #: `local_files_only=False` load would trigger. See
    #: `FasterWhisperEngine._load_model`.
    offline: bool = False

    @field_validator("candidate_languages")
    @classmethod
    def _validate_candidate_languages(cls, value: list[str] | None) -> list[str] | None:
        if value is None:
            return value
        for code in value:
            if not _LANGUAGE_CODE_PATTERN.fullmatch(code):
                raise ValueError(f"invalid candidate language code: {code!r}")
        return value


class StageEvent(BaseModel):
    """The pipeline has entered a new `Stage`."""

    event: Literal["stage"] = "stage"
    stage: Stage


class ResultEvent(BaseModel):
    """The debrief finished successfully."""

    event: Literal["result"] = "result"
    transcript: str
    rendered_text: str
    #: `DebriefSummary.to_json()` — the caller re-parses it with
    #: `DebriefSummary.from_json()`.
    summary_json: str
    folder: Path
    engine_name: str
    #: The language the STT engine detected/used, if it reported one and
    #: no `language` was requested. See `DebriefResult.detected_language`.
    detected_language: str | None = None
    issues: list[str] = []


class ErrorEvent(BaseModel):
    """The debrief failed. `kind` identifies which failure, for `WorkerError`/exit-code mapping."""

    event: Literal["error"] = "error"
    kind: ErrorKind
    message: str


class LogEvent(BaseModel):
    """A log line forwarded from the child process (optional; not required for a successful run)."""

    event: Literal["log"] = "log"
    level: str
    message: str


Event = Annotated[
    StageEvent | ResultEvent | ErrorEvent | LogEvent,
    Field(discriminator="event"),
]

_event_adapter: TypeAdapter[Event] = TypeAdapter(Event)


def parse_event(line: str) -> Event:
    """Parse one JSON-lines protocol line into its concrete `Event` type."""
    return _event_adapter.validate_json(line)
