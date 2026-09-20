"""Parent-process side of the JSON-lines debrief worker protocol.

Spawns `python -m dikta.worker` as a subprocess (see
`dikta.worker.__main__`), feeds it one `DebriefRequest` on stdin, and reads
back a stream of protocol events from stdout until a `ResultEvent` or
`ErrorEvent` arrives.
"""

from __future__ import annotations

import logging
import subprocess
import sys
import threading
from collections.abc import Callable

from pydantic import ValidationError

from dikta.worker.protocol import DebriefRequest, ErrorEvent, Event, ResultEvent, parse_event

__all__ = ["WorkerClient", "WorkerError", "WorkerCancelled"]

_log = logging.getLogger("dikta.worker.client")

#: Logger name the child subprocess itself logs under (see
#: `dikta.worker.child._configure_logging`) — `_drain_stderr` forwards each
#: raw stderr line here live, under the same name, so it reads as if the
#: child's own logging reached this process directly.
_child_log = logging.getLogger("dikta.worker.child")

#: How much of the child's stderr to surface when it exits without ever
#: sending a `ResultEvent`/`ErrorEvent` (e.g. it crashed before importing
#: `dikta.worker.child` at all).
_STDERR_TAIL_BYTES = 2048


class WorkerError(Exception):
    """The worker subprocess reported a structured failure (an `ErrorEvent`)."""

    def __init__(self, kind: str, message: str, exit_code: int | None = None) -> None:
        self.kind = kind
        self.message = message
        self.exit_code = exit_code
        super().__init__(f"{kind}: {message}")


class WorkerCancelled(Exception):
    """The run was cancelled via `WorkerClient.cancel()` before it finished."""


class WorkerClient:
    """Runs one debrief request at a time in a `dikta.worker` subprocess.

    Not safe to call `run()` concurrently from multiple threads (there is
    one subprocess slot); `cancel()` is safe to call from another thread
    while a `run()` is in progress, before a `run()` has been called at
    all, or in the brief window between the two.

    **Cancellation is permanent (single-use):** `cancel()` latches
    `_cancelled` and `run()` never clears it, so once a `WorkerClient` has
    been cancelled, every current or future `run()` call raises
    `WorkerCancelled` immediately (without spawning a process, for a
    `run()` that hadn't started yet). Construct a new `WorkerClient` for
    another run.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._process: subprocess.Popen[str] | None = None
        self._cancelled = False

    def run(
        self,
        request: DebriefRequest,
        on_event: Callable[[Event], None] | None = None,
    ) -> ResultEvent:
        """Run `request` in a fresh subprocess, forwarding each event to `on_event`.

        Returns the `ResultEvent` on success. Raises `WorkerError` if the
        worker reports an `ErrorEvent` (or exits without a result), or
        `WorkerCancelled` if `cancel()` was called before or during the
        run (see the class docstring for cancellation's single-use
        semantics).
        """
        with self._lock:
            # Checking-and-spawning under the same lock `cancel()` uses to
            # check-and-terminate means the two can never interleave: a
            # `cancel()` that already ran before we get the lock is caught
            # right here (no process spawned); a `cancel()` that runs
            # after we release it below always sees `self._process`
            # already assigned, so it terminates the real subprocess (see
            # `cancel()`) instead of racing this method's setup.
            if self._cancelled:
                raise WorkerCancelled()
            process = subprocess.Popen(  # noqa: S603 - fixed argv, no shell, no untrusted input
                [sys.executable, "-m", "dikta.worker"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
            )
            self._process = process

        stderr_chunks: list[str] = []
        stderr_thread = threading.Thread(
            target=_drain_stderr, args=(process, stderr_chunks), daemon=True
        )
        stderr_thread.start()

        try:
            assert process.stdin is not None
            process.stdin.write(request.model_dump_json())
            process.stdin.close()
        except (BrokenPipeError, OSError):
            pass  # the child may have already exited; surfaced by the checks below

        result: ResultEvent | None = None
        error: WorkerError | None = None
        try:
            assert process.stdout is not None
            # Drain stdout all the way to EOF (the child closing it, i.e.
            # exiting) rather than stopping at the first Result/ErrorEvent:
            # `wait()` below must never run while stdout is still unread,
            # or a child still trying to flush a large buffered write could
            # deadlock against a parent that stopped reading.
            for line in process.stdout:
                line = line.strip()
                if not line:
                    continue
                event = _parse_event_or_none(line)
                if event is None:
                    continue
                if on_event is not None:
                    on_event(event)
                if isinstance(event, ResultEvent) and result is None:
                    result = event
                elif isinstance(event, ErrorEvent) and error is None:
                    error = WorkerError(event.kind, event.message)
        finally:
            process.wait()
            stderr_thread.join(timeout=5)

        if self._cancelled:
            raise WorkerCancelled()
        if result is not None:
            return result
        if error is not None:
            error.exit_code = process.returncode
            raise error

        tail = "".join(stderr_chunks)[-_STDERR_TAIL_BYTES:]
        raise WorkerError("unexpected", tail, exit_code=process.returncode)

    def cancel(self) -> None:
        """Cancel this client permanently.

        Terminates the running subprocess, if any (escalating to `kill()`
        after 2s), and latches `_cancelled` so every current or future
        `run()` call raises `WorkerCancelled`. Safe to call before `run()`
        has been called at all -- there is simply no process to terminate
        yet, but the next `run()` still raises immediately.
        """
        with self._lock:
            self._cancelled = True
            process = self._process
        if process is None or process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)


def _parse_event_or_none(line: str) -> Event | None:
    """Parse one stdout line into an `Event`, or `None` if it isn't one.

    A line that fails to parse (not JSON, or a JSON object with an
    `event` value we don't recognize — e.g. a hypothetical future
    `"progress"` event an older client doesn't know about yet) is logged
    at DEBUG and skipped rather than raised: the protocol stream is meant
    to be forward-compatible, and a single malformed/unknown line should
    never take down an otherwise-successful run.
    """
    try:
        return parse_event(line)
    except (ValidationError, ValueError) as exc:
        _log.debug("worker stdout: skipping unparseable/unknown protocol line: %s (%s)", line, exc)
        return None


def _drain_stderr(process: subprocess.Popen[str], chunks: list[str]) -> None:
    """Continuously read the child's stderr so it never blocks on a full pipe buffer.

    Each line is forwarded live to `_child_log` at INFO -- so the child's
    own logging (e.g. `FasterWhisperEngine`'s language-detection decision)
    is visible in this process's log stream as it happens, not only
    recoverable from `chunks`' tail on failure -- and still appended to
    `chunks`, which backs the failure-tail message in `run()`.
    """
    assert process.stderr is not None
    for line in process.stderr:
        chunks.append(line)
        _child_log.info(line.rstrip("\n"))
