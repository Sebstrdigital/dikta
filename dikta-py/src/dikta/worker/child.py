"""Code that runs inside the debrief worker subprocess.

Never let a traceback reach stdout — stdout is reserved for the JSON-lines
protocol (`dikta.worker.protocol`); logging is configured here to go to
stderr instead.
"""

from __future__ import annotations

import logging
import os
import sys
import time
from collections.abc import Callable

from dikta.core.debrief.store import DebriefStore
from dikta.engines.audio.errors import AudioFileError
from dikta.engines.audio.loader import AudioFileLoader
from dikta.engines.llm.errors import EmptyTranscript, SummarizerError
from dikta.engines.llm.factory import make_summarizer
from dikta.engines.stt.base import TranscriptionError
from dikta.engines.stt.fake import FakeSpeechToText
from dikta.engines.stt.faster_whisper_engine import FasterWhisperEngine
from dikta.pipeline.file_debrief import FileDebriefPipeline, Stage, TranscriptionTimeout
from dikta.worker.protocol import (
    DebriefRequest,
    ErrorEvent,
    ErrorKind,
    Event,
    ResultEvent,
    StageEvent,
)

__all__ = ["run"]

_log = logging.getLogger("dikta.worker.child")

#: Process exit codes for each `ErrorEvent.kind` other than "unexpected",
#: which always exits 1.
_EXIT_CODES: dict[ErrorKind, int] = {
    "empty_transcript": 3,
    "transcription_timeout": 4,
    "summarizer": 5,
    "audio_file": 6,
    "transcription": 7,
}


def _configure_logging() -> None:
    """Send all logging to stderr; stdout is reserved for protocol lines.

    A no-op if the root logger already has handlers (e.g. `run` was called
    in-process from the CLI's `--in-process` mode rather than from a fresh
    subprocess), matching `logging.basicConfig`'s own default behavior.
    """
    logging.basicConfig(stream=sys.stderr, level=logging.INFO)


def _build_stt(request: DebriefRequest):
    if request.stt_engine == "fake":
        delay = request.fake_stt_delay
        text = request.fake_stt_text or ""
        stray = request.debug_stray_stdout

        if delay > 0 or stray:

            def _responder(samples, language, _delay=delay, _text=text, _stray=stray):
                if _stray:
                    # Deliberately misbehave, to prove the worker's stdout
                    # hygiene catches both a Python-level print (which
                    # `_configure_logging`'s stderr redirect alone would
                    # NOT stop, since `print` writes to `sys.stdout`
                    # directly) and a raw fd-1 write (standing in for a
                    # C-level library writing straight to stdout, e.g.
                    # ctranslate2 -- `dikta.worker.__main__` dup2s fd 1
                    # onto stderr before anything else runs).
                    print("STRAY")
                    os.write(1, b"RAW STRAY\n")
                if _delay > 0:
                    time.sleep(_delay)
                return _text

            return FakeSpeechToText(responder=_responder)
        return FakeSpeechToText(text=text)
    return FasterWhisperEngine(
        model=request.stt_model,
        device=request.stt_device,
        compute_type=request.stt_compute_type,
        candidate_languages=request.candidate_languages,
        offline=request.offline,
    )


def run(request: DebriefRequest, emit: Callable[[Event], None]) -> int:
    """Run one debrief request, emitting protocol events via `emit`.

    Returns the process exit code (0 on success, see `_EXIT_CODES`
    otherwise).
    """
    _configure_logging()

    loader = AudioFileLoader()
    stt = _build_stt(request)
    summarizer = make_summarizer(
        request.engine_kind,
        ollama_model=request.ollama_model,
        ollama_base_url=request.ollama_base_url,
    )
    store = DebriefStore(root=request.store_root)
    pipeline = FileDebriefPipeline(
        loader=loader,
        stt=stt,
        summarizer=summarizer,
        store=store,
        transcription_timeout=request.transcription_timeout,
    )

    def on_stage(stage: Stage) -> None:
        emit(StageEvent(stage=stage))

    try:
        result = pipeline.run_file(request.file, language=request.language, on_stage=on_stage)
    except EmptyTranscript as exc:
        return _emit_error(emit, "empty_transcript", str(exc))
    except TranscriptionTimeout as exc:
        return _emit_error(emit, "transcription_timeout", str(exc))
    except AudioFileError as exc:
        return _emit_error(emit, "audio_file", str(exc))
    except TranscriptionError as exc:
        return _emit_error(emit, "transcription", str(exc))
    except SummarizerError as exc:
        return _emit_error(emit, "summarizer", str(exc))
    except Exception as exc:  # noqa: BLE001 - last resort: never let a traceback reach stdout
        _log.exception("unexpected error in debrief worker")
        return _emit_error(emit, "unexpected", str(exc))

    emit(
        ResultEvent(
            transcript=result.transcript,
            rendered_text=result.rendered_text,
            summary_json=result.summary.to_json(),
            folder=result.paths.folder,
            engine_name=result.engine_name,
            detected_language=result.detected_language,
            issues=list(result.issues),
        )
    )
    return 0


def _emit_error(emit: Callable[[Event], None], kind: ErrorKind, message: str) -> int:
    try:
        emit(ErrorEvent(kind=kind, message=message))
    except (BrokenPipeError, OSError):
        # The parent already went away (e.g. it was cancelled) -- nothing
        # left to report to; still exit with the kind's mapped code.
        pass
    return _EXIT_CODES.get(kind, 1)
