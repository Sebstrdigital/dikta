"""Tests for `WorkerClient`, driving the real `dikta.worker` subprocess (no mocks)."""

from __future__ import annotations

import logging
import subprocess
import sys
import threading
import time
import wave
from pathlib import Path

import numpy as np
import pytest

from dikta.core.debrief.model import DebriefSummary
from dikta.engines.llm.factory import EngineKind
from dikta.worker.client import WorkerCancelled, WorkerClient, WorkerError, _parse_event_or_none
from dikta.worker.protocol import DebriefRequest, ResultEvent, StageEvent, parse_event


def _write_wav(path: Path, seconds: float = 1.0, sample_rate: int = 16_000) -> None:
    n = int(seconds * sample_rate)
    pcm = np.zeros(n, dtype=np.int16)
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm.tobytes())


def _wait_until(predicate, timeout: float = 5.0, interval: float = 0.02) -> bool:
    """Poll `predicate` until it's true or `timeout` elapses; returns whether it became true."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def test_worker_client_runs_a_full_debrief_and_reports_stage_order(tmp_path):
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    events = []
    request = DebriefRequest(
        file=wav_path,
        stt_engine="fake",
        fake_stt_text="we agreed to ship on friday",
        engine_kind=EngineKind.HEURISTIC,
        store_root=tmp_path / "store",
    )

    result = WorkerClient().run(request, on_event=events.append)

    stage_events = [e for e in events if isinstance(e, StageEvent)]
    assert [e.stage for e in stage_events] == ["loading", "transcribing", "summarizing", "saving"]
    assert isinstance(result, ResultEvent)

    folder = result.folder
    assert (folder / "audio.wav").exists()
    assert (folder / "original.wav").exists()
    assert (folder / "transcript.txt").exists()
    assert (folder / "summary.txt").exists()

    summary = DebriefSummary.from_json(result.summary_json)
    assert isinstance(summary, DebriefSummary)


def test_worker_client_empty_transcript_raises_worker_error(tmp_path):
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    request = DebriefRequest(
        file=wav_path,
        stt_engine="fake",
        fake_stt_text="",
        engine_kind=EngineKind.HEURISTIC,
        store_root=tmp_path / "store",
    )

    with pytest.raises(WorkerError) as excinfo:
        WorkerClient().run(request)

    assert excinfo.value.kind == "empty_transcript"
    assert excinfo.value.exit_code == 3


def test_worker_client_nonexistent_file_raises_audio_file_error(tmp_path):
    request = DebriefRequest(
        file=tmp_path / "missing.wav",
        stt_engine="fake",
        fake_stt_text="hello",
        engine_kind=EngineKind.HEURISTIC,
        store_root=tmp_path / "store",
    )

    with pytest.raises(WorkerError) as excinfo:
        WorkerClient().run(request)

    assert excinfo.value.kind == "audio_file"


def test_worker_client_cancel_stops_a_running_subprocess(tmp_path):
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    request = DebriefRequest(
        file=wav_path,
        stt_engine="fake",
        fake_stt_text="hello",
        fake_stt_delay=10.0,
        engine_kind=EngineKind.HEURISTIC,
        store_root=tmp_path / "store",
    )

    client = WorkerClient()
    outcome: dict[str, Exception] = {}

    def _run() -> None:
        try:
            client.run(request)
        except Exception as exc:  # noqa: BLE001 - captured for the assertion below
            outcome["error"] = exc

    thread = threading.Thread(target=_run)
    thread.start()

    assert _wait_until(lambda: client._process is not None), "worker subprocess never started"
    process = client._process
    assert _wait_until(lambda: process.poll() is None, timeout=2.0), (
        "worker subprocess exited before it could be cancelled"
    )

    client.cancel()
    thread.join(timeout=3)

    assert not thread.is_alive()
    assert isinstance(outcome.get("error"), WorkerCancelled)
    assert client._process is not None
    assert client._process.poll() is not None


def test_worker_client_cancel_before_run_raises_without_spawning_a_process(monkeypatch, tmp_path):
    """`cancel()` called before `run()` has ever spawned a process must not be silently lost.

    Regression test: `run()` used to unconditionally reset `_cancelled = False` at its start,
    so a `cancel()` that arrived first was simply forgotten and the debrief proceeded anyway.
    """

    def _fail_if_called(*args, **kwargs):
        raise AssertionError("Popen must not be called on an already-cancelled WorkerClient")

    monkeypatch.setattr(subprocess, "Popen", _fail_if_called)

    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)
    request = DebriefRequest(
        file=wav_path,
        stt_engine="fake",
        fake_stt_text="hello",
        engine_kind=EngineKind.HEURISTIC,
        store_root=tmp_path / "store",
    )

    client = WorkerClient()
    client.cancel()

    with pytest.raises(WorkerCancelled):
        client.run(request)

    assert client._process is None


def test_worker_client_transcription_timeout_exits_promptly_via_real_subprocess(tmp_path):
    """A timed-out transcription must not delay process exit.

    Regression test for using a `ThreadPoolExecutor` for the timeout race:
    its atexit hook joins every still-running worker thread before the
    interpreter can exit, so an abandoned 8s-sleeping transcription would
    hang the child's shutdown for ~8s even though the `ErrorEvent` was
    already emitted. A daemon `threading.Thread` has no such hook.
    """
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    request = DebriefRequest(
        file=wav_path,
        stt_engine="fake",
        fake_stt_text="hello",
        fake_stt_delay=8.0,
        engine_kind=EngineKind.HEURISTIC,
        store_root=tmp_path / "store",
        transcription_timeout=0.5,
    )

    start = time.monotonic()
    with pytest.raises(WorkerError) as excinfo:
        WorkerClient().run(request)
    elapsed = time.monotonic() - start

    assert excinfo.value.kind == "transcription_timeout"
    assert excinfo.value.exit_code == 4
    assert elapsed < 3.0, f"WorkerClient.run() took {elapsed:.2f}s, expected well under 3s"


def test_worker_subprocess_stdout_only_ever_carries_protocol_lines(tmp_path):
    """Even a Python `print()` and a raw `os.write(1, ...)` from inside the child must not
    reach the parent's stdout pipe -- only `dikta.worker.__main__`'s dedicated protocol stream
    may write there. Drives the raw subprocess directly (not `WorkerClient`, which tolerantly
    skips unparseable lines and so wouldn't itself detect a stdout leak).
    """
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    request = DebriefRequest(
        file=wav_path,
        stt_engine="fake",
        fake_stt_text="hello there",
        engine_kind=EngineKind.HEURISTIC,
        store_root=tmp_path / "store",
        debug_stray_stdout=True,
    )

    proc = subprocess.run(
        [sys.executable, "-m", "dikta.worker"],
        input=request.model_dump_json(),
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert proc.returncode == 0
    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    assert lines, "expected at least one protocol line on stdout"
    for line in lines:
        parse_event(line)  # must not raise -- every stdout line is a valid protocol event

    assert "STRAY" not in proc.stdout
    assert "RAW STRAY" not in proc.stdout
    assert "STRAY" in proc.stderr
    assert "RAW STRAY" in proc.stderr


def test_worker_client_succeeds_despite_child_stray_stdout_writes(tmp_path):
    """`WorkerClient` still gets a clean `ResultEvent` when the child (mis)behaves this way."""
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    request = DebriefRequest(
        file=wav_path,
        stt_engine="fake",
        fake_stt_text="hello there",
        engine_kind=EngineKind.HEURISTIC,
        store_root=tmp_path / "store",
        debug_stray_stdout=True,
    )

    result = WorkerClient().run(request)

    assert isinstance(result, ResultEvent)
    assert result.transcript == "hello there"


def test_worker_client_forwards_child_stderr_live_under_child_logger_name(tmp_path, caplog):
    """The child's stray writes (redirected onto its real stderr, see
    `dikta.worker.__main__`) must be forwarded live under the "dikta.worker.child" logger
    name, not just recoverable from the failure-tail buffer on a crash.
    """
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    request = DebriefRequest(
        file=wav_path,
        stt_engine="fake",
        fake_stt_text="hello there",
        engine_kind=EngineKind.HEURISTIC,
        store_root=tmp_path / "store",
        debug_stray_stdout=True,
    )

    with caplog.at_level(logging.INFO, logger="dikta.worker.child"):
        result = WorkerClient().run(request)

    assert isinstance(result, ResultEvent)
    assert any(
        record.name == "dikta.worker.child" and "STRAY" in record.message
        for record in caplog.records
    )


def test_worker_client_large_result_round_trips_without_hanging(tmp_path):
    """A `ResultEvent` whose JSON line is well over 200 KB must not deadlock the parent/child
    pipe: the child's single `write()` of that line can exceed the OS pipe buffer, and the
    parent must keep reading (not `wait()` first) for the child to ever finish writing it.

    Every sentence hits the heuristic engine's "decided" marker and is never
    deduped (each item index is unique), so the rendered DECISIONS section --
    and therefore the whole `ResultEvent` JSON line written through the
    protocol pipe -- comfortably exceeds 200 KB. Relies on the suite's global
    120s pytest-timeout as the hang safety net; the explicit `elapsed`
    assertion below proves it didn't even come close.
    """
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    transcript = " ".join(f"We decided item{i:05d} is done." for i in range(8_000))
    request = DebriefRequest(
        file=wav_path,
        stt_engine="fake",
        fake_stt_text=transcript,
        engine_kind=EngineKind.HEURISTIC,
        store_root=tmp_path / "store",
    )

    start = time.monotonic()
    result = WorkerClient().run(request)
    elapsed = time.monotonic() - start

    assert isinstance(result, ResultEvent)
    assert len(result.rendered_text) > 200_000
    assert elapsed < 30.0, f"WorkerClient.run() took {elapsed:.2f}s, expected well under 30s"


def test_parse_event_or_none_skips_unknown_event_types():
    assert _parse_event_or_none('{"event": "progress", "pct": 10}') is None
    assert _parse_event_or_none("not json at all") is None


def test_parse_event_or_none_still_parses_known_events():
    event = _parse_event_or_none('{"event": "stage", "stage": "loading"}')

    assert isinstance(event, StageEvent)
    assert event.stage == "loading"
