"""The debrief worker: runs `FileDebriefPipeline` in a subprocess via a JSON-lines protocol."""

from __future__ import annotations

from dikta.worker.client import WorkerCancelled, WorkerClient, WorkerError
from dikta.worker.protocol import (
    DebriefRequest,
    ErrorEvent,
    Event,
    LogEvent,
    ResultEvent,
    StageEvent,
    parse_event,
)

__all__ = [
    "WorkerClient",
    "WorkerError",
    "WorkerCancelled",
    "DebriefRequest",
    "Event",
    "StageEvent",
    "ResultEvent",
    "ErrorEvent",
    "LogEvent",
    "parse_event",
]
