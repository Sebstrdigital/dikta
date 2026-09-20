"""Runs one debrief request on a background `QThread`, reporting progress via signals.

`Runner.run()` (see `dikta.app.main_window.Runner`) is a blocking call, so it
must never run on the GUI thread. `DebriefJob` owns a `QThread` + a small
worker `QObject` moved onto it; the worker's signals are relayed back to
`DebriefJob`'s own signals (always delivered on the thread that owns
`DebriefJob`, since Qt auto-queues connections across thread affinities),
so callers never touch widgets from the worker thread themselves.
"""

from __future__ import annotations

import logging
import threading
from typing import Any

from PySide6.QtCore import QObject, QThread, Signal

from dikta.worker.client import WorkerCancelled, WorkerError
from dikta.worker.protocol import DebriefRequest, Event, ResultEvent, StageEvent

__all__ = ["DebriefJob"]

_log = logging.getLogger("dikta.app.debrief_job")

#: How long `shutdown()` waits for the background thread to stop before
#: retrying `cancel()` once, and how long it waits after that retry.
#: Bounded so `MainWindow.closeEvent` can never hang forever on a runner
#: whose `cancel()` doesn't actually unblock it.
_SHUTDOWN_FIRST_WAIT_MS = 5_000
_SHUTDOWN_RETRY_WAIT_MS = 2_000


class _Worker(QObject):
    """Lives on the background thread; makes the one blocking `runner.run()` call."""

    stage_changed = Signal(str)
    finished = Signal(object)
    failed = Signal(str, str)
    cancelled = Signal()

    def __init__(self, request: DebriefRequest, runner: Any) -> None:
        super().__init__()
        self._request = request
        self._runner = runner
        #: Set from `DebriefJob.cancel()`, possibly from the GUI thread
        #: before this worker's `run()` slot has even been invoked yet —
        #: `threading.Event` is the cross-thread-safe primitive for that.
        self._cancel_event = threading.Event()

    def mark_cancelled(self) -> None:
        """Record a cancellation request. Safe to call before `run()` executes."""
        self._cancel_event.set()

    def run(self) -> None:
        if self._cancel_event.is_set():
            # Cancelled before we ever got to call `runner.run()` — honor
            # it immediately rather than starting work that's already
            # unwanted.
            _log.info("debrief worker cancelled before start: file=%s", self._request.file.name)
            self.cancelled.emit()
            return

        _log.info("debrief worker thread starting: file=%s", self._request.file.name)

        def on_event(event: Event) -> None:
            if isinstance(event, StageEvent):
                self.stage_changed.emit(str(event.stage))

        try:
            result = self._runner.run(self._request, on_event)
        except WorkerCancelled:
            self.cancelled.emit()
        except WorkerError as exc:
            self.failed.emit(exc.kind, exc.message)
        except Exception as exc:  # noqa: BLE001 - any other failure surfaces as "unexpected"
            _log.exception("debrief job failed unexpectedly")
            self.failed.emit("unexpected", str(exc))
        else:
            self.finished.emit(result)


class DebriefJob(QObject):
    """Runs a `DebriefRequest` against a `Runner` on a background thread.

    Emits exactly one of `finished`, `failed`, `cancelled` per `start()`
    call, always on the thread `DebriefJob` itself lives on. Once a job
    reaches one of those terminal states, it schedules the deletion of its
    `QThread`, its worker, and itself via `deleteLater()` — never by
    relying on Python's refcounting, since the last reference to a
    `QThread` could otherwise be dropped from any thread, and `deleteLater`
    guarantees each delete happens on the owning object's own thread.
    """

    stage_changed = Signal(str)
    finished = Signal(object)
    failed = Signal(str, str)
    cancelled = Signal()

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.qthread: QThread | None = None
        self._worker: _Worker | None = None
        self._runner: Any = None

    def start(self, request: DebriefRequest, runner: Any) -> None:
        """Start `runner.run(request, ...)` on a fresh background thread."""
        self._runner = runner
        self.qthread = QThread()
        self._worker = _Worker(request, runner)
        self._worker.moveToThread(self.qthread)

        self.qthread.started.connect(self._worker.run)
        self._worker.stage_changed.connect(self.stage_changed)
        self._worker.finished.connect(self._on_finished)
        self._worker.failed.connect(self._on_failed)
        self._worker.cancelled.connect(self._on_cancelled)

        self.qthread.start()

    def cancel(self) -> None:
        """Ask the running `Runner` to cancel. No-op if nothing is running.

        Safe to call before the worker thread has even reached its `run()`
        slot yet (the worker's own cancel flag survives and is checked
        first thing when it does), or while `runner.run()` is already
        blocked (the runner's own `cancel()` is expected to unblock it).
        """
        if self._worker is not None:
            self._worker.mark_cancelled()
        if self._runner is not None:
            self._runner.cancel()

    def shutdown(self) -> None:
        """Cancel any running job and wait (bounded) for its thread to stop.

        Called from `MainWindow.closeEvent`. Retries `cancel()` once if the
        thread hasn't stopped after `_SHUTDOWN_FIRST_WAIT_MS` (in case the
        first call raced a runner that wasn't ready to receive it yet). If
        the thread *still* hasn't stopped after that retry — a runner whose
        `cancel()` can't actually unblock it — this gives up: it logs a
        warning, disconnects the worker's signals so a late emission can't
        reach an already-closed window, and returns. It deliberately never
        calls `QThread.terminate()` (killing a thread mid-syscall can
        corrupt process state), and keeps `self.qthread`/`self._worker`
        referenced in that case so neither is garbage-collected out from
        under the still-running thread.
        """
        thread = self.qthread
        if thread is None:
            return

        self.cancel()
        thread.quit()
        if thread.wait(_SHUTDOWN_FIRST_WAIT_MS):
            self._finalize_stopped_thread()
            return

        self.cancel()
        if thread.wait(_SHUTDOWN_RETRY_WAIT_MS):
            self._finalize_stopped_thread()
            return

        _log.warning(
            "debrief worker thread did not stop within the shutdown grace period; "
            "abandoning wait without terminating it"
        )
        self._disconnect_worker_signals()

    def _on_finished(self, result: ResultEvent) -> None:
        self.finished.emit(result)
        self._finalize()

    def _on_failed(self, kind: str, message: str) -> None:
        self.failed.emit(kind, message)
        self._finalize()

    def _on_cancelled(self) -> None:
        self.cancelled.emit()
        self._finalize()

    def _finalize(self) -> None:
        """Stop the background thread (already idle by this point) and clean up."""
        thread = self.qthread
        if thread is not None:
            thread.quit()
            thread.wait()
        self._finalize_stopped_thread()

    def _finalize_stopped_thread(self) -> None:
        """Clear refs and schedule deletion for a thread that has already stopped."""
        thread = self.qthread
        worker = self._worker
        self.qthread = None
        self._worker = None
        if thread is not None:
            thread.deleteLater()
        if worker is not None:
            worker.deleteLater()
        self.deleteLater()

    def _disconnect_worker_signals(self) -> None:
        worker = self._worker
        if worker is None:
            return
        for signal, slot in (
            (worker.stage_changed, self.stage_changed),
            (worker.finished, self._on_finished),
            (worker.failed, self._on_failed),
            (worker.cancelled, self._on_cancelled),
        ):
            try:
                signal.disconnect(slot)
            except (RuntimeError, TypeError):
                pass  # already disconnected, or the underlying object is gone
