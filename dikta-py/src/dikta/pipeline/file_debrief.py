"""File-import whole-recording debrief pipeline.

Port of `DebriefPipeline.run(samples:...)` (short-recording branch) and the
shared `finishTranscribedDebrief` tail
(`dikta-macos/Dikta/Services/Debrief/DebriefPipeline.swift`). See
port-spec section 13 for the exact ordered steps this replicates.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

import numpy as np

from dikta.core.debrief.model import DebriefSummary
from dikta.core.debrief.render import render_plain_text
from dikta.core.debrief.sanitizer import is_effectively_empty
from dikta.core.debrief.store import DebriefStore, SessionPaths
from dikta.engines.audio.loader import TARGET_SAMPLE_RATE
from dikta.engines.llm.base import Summarizer
from dikta.engines.llm.errors import EmptyTranscript
from dikta.engines.stt.base import SpeechToText, TranscriptionResult

__all__ = [
    "Stage",
    "TranscriptionTimeout",
    "DebriefResult",
    "render_language",
    "FileDebriefPipeline",
]

_log = logging.getLogger("dikta.pipeline.file_debrief")

#: Recordings longer than this switch to chunked transcription in the Swift
#: app (`ChunkingConfig.targetChunkSeconds`, out of scope here — see
#: port-spec section 13). v0 of this port always transcribes the whole
#: recording in one call regardless of length; we only log when it happens.
_CHUNKING_THRESHOLD_SECONDS = 300.0


class Stage(StrEnum):
    """A step of the debrief pipeline, reported via `on_stage` callbacks."""

    LOADING = "loading"
    TRANSCRIBING = "transcribing"
    SUMMARIZING = "summarizing"
    SAVING = "saving"


class TranscriptionTimeout(Exception):
    """Raised when `SpeechToText.transcribe` doesn't finish within the configured timeout.

    The transcription runs in a background **daemon** thread that cannot be
    safely killed once started (Python has no API to cancel a running
    thread) — on timeout the thread is simply abandoned; being a daemon
    thread it never blocks interpreter/process exit even if it goes on
    running (or sleeping) well past the timeout. Its eventual result (if
    any) is discarded.
    """


@dataclass(frozen=True)
class DebriefResult:
    """The result of running the debrief pipeline on one recording."""

    transcript: str
    summary: DebriefSummary
    rendered_text: str
    paths: SessionPaths
    engine_name: str
    #: The language the STT engine detected/used, independent of what was
    #: requested (`None` if the engine didn't report one). See
    #: `FileDebriefPipeline._finish` for how this feeds language fallback.
    detected_language: str | None = None
    issues: tuple[str, ...] = ()


def render_language(code: str | None) -> str:
    """Return `code` unchanged if it's exactly "sv" or "en"; anything else (including `None`)
    falls back to "en".

    Mirrors `DebriefPipeline.renderLanguage(for:)`.
    """
    return code if code in ("sv", "en") else "en"


class FileDebriefPipeline:
    """Runs a whole recording through load -> transcribe -> summarize -> save.

    Only the in-scope whole-recording path (port-spec section 13) is
    implemented here: recordings longer than `_CHUNKING_THRESHOLD_SECONDS`
    are NOT chunked, they are transcribed in a single call.
    """

    def __init__(
        self,
        loader,
        stt: SpeechToText,
        summarizer: Summarizer,
        store: DebriefStore,
        transcription_timeout: float = 1800.0,
    ) -> None:
        self._loader = loader
        self._stt = stt
        self._summarizer = summarizer
        self._store = store
        self._transcription_timeout = transcription_timeout

    def run_file(
        self,
        path: Path,
        language: str | None = None,
        on_stage: Callable[[Stage], None] | None = None,
    ) -> DebriefResult:
        """Load `path` from disk, then run it through `run_samples`, passing it through as
        `original_file` so a byte-copy is preserved alongside the resampled audio.
        """
        _fire(on_stage, Stage.LOADING)
        samples = self._loader.load(path)
        return self.run_samples(samples, language, original_file=path, on_stage=on_stage)

    def run_samples(
        self,
        samples: np.ndarray,
        language: str | None = None,
        original_file: Path | None = None,
        on_stage: Callable[[Stage], None] | None = None,
    ) -> DebriefResult:
        """Run already-loaded 16 kHz mono float32 `samples` through the pipeline.

        Ordered steps mirror port-spec section 13: create the session
        folder first (so a partially-failed run still leaves the recording
        on disk), write the resampled audio, optionally copy the original
        source file, then transcribe (racing a timeout) before handing off
        to `_finish` for the sanitize/summarize/render/save tail.
        """
        paths = self._store.create_session()
        self._store.write_audio(samples, paths)
        if original_file is not None:
            self._store.copy_original(original_file, paths)

        duration_s = len(samples) / TARGET_SAMPLE_RATE
        if duration_s > _CHUNKING_THRESHOLD_SECONDS:
            # The Swift app switches to chunked/live-session transcription
            # above this threshold (out of scope here, see port-spec
            # section 13) — v0 of this port transcribes the whole
            # recording in one call regardless of length.
            _log.info(
                "recording is %.1fs (> %.0fs chunking threshold); "
                "transcribing whole file without chunking",
                duration_s,
                _CHUNKING_THRESHOLD_SECONDS,
            )

        _fire(on_stage, Stage.TRANSCRIBING)
        transcription = self._transcribe_with_timeout(samples, language)
        return self._finish(
            transcription.text, transcription.language, paths, language, on_stage
        )

    def _transcribe_with_timeout(
        self, samples: np.ndarray, language: str | None
    ) -> TranscriptionResult:
        outcome: dict[str, object] = {}

        def _target() -> None:
            try:
                outcome["result"] = self._stt.transcribe(samples, language)
            except BaseException as exc:  # noqa: BLE001 - re-raised on the calling thread below
                outcome["error"] = exc

        # A plain daemon thread, not a `ThreadPoolExecutor`: the futures
        # module registers an atexit hook that JOINS every still-running
        # worker thread before the interpreter is allowed to exit, which
        # would make a timed-out transcription hang process shutdown for
        # however long the abandoned transcription takes to finish (see
        # `TranscriptionTimeout`'s docstring). A daemon thread has no such
        # hook and is simply dropped on exit.
        thread = threading.Thread(target=_target, daemon=True)
        thread.start()
        thread.join(timeout=self._transcription_timeout)
        if thread.is_alive():
            raise TranscriptionTimeout(
                f"Transcription did not finish within {self._transcription_timeout}s"
            )
        if "error" in outcome:
            raise outcome["error"]  # type: ignore[misc]
        return outcome["result"]  # type: ignore[return-value]

    def _finish(
        self,
        transcript: str,
        detected_language: str | None,
        paths: SessionPaths,
        requested_language: str | None,
        on_stage: Callable[[Stage], None] | None,
    ) -> DebriefResult:
        """The shared tail: write transcript, reject silence, summarize, render, save.

        Mirrors `finishTranscribedDebrief` (port-spec section 13); the
        `issues`/`summarize`-closure overrides that path also has are
        always their in-scope defaults (`[]` / `None`) here.

        `requested_language` (the caller-supplied `language`) wins when
        given; otherwise falls back to `detected_language` (what the STT
        engine itself detected/used, e.g. faster-whisper's auto-detection)
        before `render_language` resolves it to "sv"/"en" for both the
        summarizer call and the rendered text.
        """
        self._store.write_transcript(transcript, paths)
        if is_effectively_empty(transcript):
            raise EmptyTranscript()

        _fire(on_stage, Stage.SUMMARIZING)
        effective_language = requested_language or detected_language
        lang = render_language(effective_language)
        produced = self._summarizer.summarize(transcript, lang)
        summary = produced.normalized().validated(transcript)
        rendered = render_plain_text(summary, lang)

        _fire(on_stage, Stage.SAVING)
        self._store.write_summary(rendered, paths)

        last_used = getattr(self._summarizer, "last_used_engine_name", None)
        engine_name = last_used if last_used is not None else self._summarizer.name

        return DebriefResult(
            transcript=transcript,
            summary=summary,
            rendered_text=rendered,
            paths=paths,
            engine_name=engine_name,
            detected_language=detected_language,
        )


def _fire(on_stage: Callable[[Stage], None] | None, stage: Stage) -> None:
    if on_stage is not None:
        on_stage(stage)
