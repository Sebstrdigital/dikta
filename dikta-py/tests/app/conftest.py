"""Shared fixtures for `tests/app`.

`QT_QPA_PLATFORM` is forced to `offscreen` before PySide6 is ever imported,
so the whole suite runs headless (CI has no display).
"""

from __future__ import annotations

import os
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PySide6.QtCore import QSettings
from PySide6.QtWidgets import QApplication

from dikta.app import main_window as main_window_module
from dikta.pipeline.file_debrief import Stage
from dikta.worker.client import WorkerCancelled, WorkerError
from dikta.worker.protocol import DebriefRequest, Event, ResultEvent, StageEvent

FIXED_RENDERED_TEXT = "Summary: fixture rendered text."
FIXED_TRANSCRIPT = "This is the fixture transcript."

#: Where `QSettings("Dikta", "DiktaPy")` lands on macOS with the platform's
#: native backend. Used only to assert the redirection below actually
#: worked — this file must never be created or touched by this test run.
#: Deliberately "DiktaPy", not "Dikta": the Swift macOS app already owns
#: `com.dikta.Dikta.plist` (it holds Sparkle's update state), so this
#: Python port uses a distinct organization/application pair and never
#: touches that file at all — unlike `com.dikta.Dikta.plist`, nothing else
#: on this machine writes to `com.dikta.DiktaPy.plist`, so an mtime/
#: existence check against it can't collide with an unrelated live app.
_REAL_DIKTAPY_PLIST = Path.home() / "Library" / "Preferences" / "com.dikta.DiktaPy.plist"


@pytest.fixture(scope="session")
def qapp() -> QApplication:
    """A single `QApplication` shared by the whole test session."""
    app = QApplication.instance()
    if app is None:
        app = QApplication([])
    return app


def _plist_mtime() -> float | None:
    try:
        return _REAL_DIKTAPY_PLIST.stat().st_mtime
    except OSError:
        return None


class _RedirectedQSettings(QSettings):
    """`QSettings` subclass whose `(organization, application)` constructor is redirected.

    `QSettings(organization, application)` — the convenience overload
    `MainWindow` uses — is documented to always construct with
    `NativeFormat`/`UserScope`, ignoring `QSettings.setDefaultFormat()`
    entirely; only the explicit-format overload
    (`QSettings(format, scope, organization, application)`) honors a
    custom path. Confirmed empirically during development: with
    `setDefaultFormat(IniFormat)` + `setPath(...)` both active,
    `QSettings("Dikta", "DiktaPy").format()` still came back
    `NativeFormat`, and a value set through it landed in the real
    `~/Library/Preferences/com.dikta.DiktaPy.plist` instead of the scratch
    ini file. This subclass routes the 2-arg call through the
    explicit-format overload instead, so the redirection actually applies.
    """

    def __init__(self, organization: str, application: str = "", parent: object = None) -> None:
        super().__init__(
            QSettings.Format.IniFormat, QSettings.Scope.UserScope, organization, application, parent
        )


@pytest.fixture(scope="session", autouse=True)
def qsettings_scratch(tmp_path_factory: pytest.TempPathFactory):
    """Redirect every `QSettings` in this session to an ini file, not the real one.

    Patches `dikta.app.main_window.QSettings` (the name `MainWindow.__init__`
    actually calls) to `_RedirectedQSettings` for the whole session — see
    that class's docstring for why `setDefaultFormat`/`setPath` alone don't
    work for the 2-arg constructor it uses. Session-scoped (not per-test),
    with a finalizer that undoes the patch. Since `com.dikta.DiktaPy.plist`
    is used by nothing else on this machine (unlike the Swift app's own
    `com.dikta.Dikta.plist`), a session-start/session-end check on it — no
    live-app interference possible — backs up the claim that nothing here
    ever touched the real file: either it still doesn't exist, or (if it
    already existed from some prior manual run) its mtime is unchanged.
    """
    plist_existed_before = _REAL_DIKTAPY_PLIST.exists() if sys.platform == "darwin" else False
    plist_mtime_before = _plist_mtime() if plist_existed_before else None

    scratch_dir = tmp_path_factory.mktemp("qsettings")
    QSettings.setPath(QSettings.Format.IniFormat, QSettings.Scope.UserScope, str(scratch_dir))

    mp = pytest.MonkeyPatch()
    mp.setattr(main_window_module, "QSettings", _RedirectedQSettings)

    yield scratch_dir

    mp.undo()

    if sys.platform == "darwin":
        if plist_existed_before:
            assert _plist_mtime() == plist_mtime_before, (
                f"tests/app touched the real DiktaPy settings file ({_REAL_DIKTAPY_PLIST}) — "
                "QSettings redirection failed"
            )
        else:
            assert not _REAL_DIKTAPY_PLIST.exists(), (
                f"tests/app created the real DiktaPy settings file ({_REAL_DIKTAPY_PLIST}) — "
                "QSettings redirection failed"
            )


@pytest.fixture(autouse=True)
def _fresh_settings(qsettings_scratch: Path) -> None:
    """Clear the (redirected) `Dikta`/`DiktaPy` settings before each test.

    `qsettings_scratch` only points `QSettings` at a scratch ini file once
    for the whole session; without this, a value one test persists (e.g. a
    language choice) would leak into the next test's `MainWindow()`.
    """
    _RedirectedQSettings("Dikta", "DiktaPy").clear()


class _FakeRunner:
    """Emits the four pipeline stages, then returns a fixed `ResultEvent`.

    `rendered_text`/`transcript`/`folder` are public so tests can assert
    against them without re-importing the module-level constants.
    """

    rendered_text = FIXED_RENDERED_TEXT
    transcript = FIXED_TRANSCRIPT

    def __init__(self, folder: Path, detected_language: str | None = None) -> None:
        self.folder = folder
        self.detected_language = detected_language

    def run(self, request: DebriefRequest, on_event: Callable[[Event], None]) -> ResultEvent:
        for stage in Stage:
            on_event(StageEvent(stage=stage))
            time.sleep(0.01)
        return ResultEvent(
            transcript=self.transcript,
            rendered_text=self.rendered_text,
            summary_json="{}",
            folder=self.folder,
            engine_name="fake",
            detected_language=self.detected_language,
        )

    def cancel(self) -> None:  # pragma: no cover - nothing to cancel, run() is synchronous
        pass


@pytest.fixture
def fake_runner(tmp_path: Path) -> _FakeRunner:
    return _FakeRunner(tmp_path)


@pytest.fixture
def fake_runner_with_language(tmp_path: Path) -> _FakeRunner:
    """A `_FakeRunner` whose `ResultEvent.detected_language` is set (here: "sv")."""
    return _FakeRunner(tmp_path, detected_language="sv")


class _FailingRunner:
    """Reports `Stage.LOADING`, then raises `WorkerError(kind, message)`."""

    def __init__(self, kind: str, message: str) -> None:
        self._kind = kind
        self._message = message

    def run(self, request: DebriefRequest, on_event: Callable[[Event], None]) -> ResultEvent:
        on_event(StageEvent(stage=Stage.LOADING))
        raise WorkerError(self._kind, self._message)

    def cancel(self) -> None:  # pragma: no cover - nothing to cancel, run() is synchronous
        pass


@pytest.fixture
def failing_runner() -> Callable[[str, str], _FailingRunner]:
    """Factory: `failing_runner(kind, message)` builds a runner that fails that way."""
    return _FailingRunner


class _CrashingRunner:
    """Raises a plain, non-protocol exception — simulates a genuinely unexpected bug."""

    def run(self, request: DebriefRequest, on_event: Callable[[Event], None]) -> ResultEvent:
        raise RuntimeError("kaboom")

    def cancel(self) -> None:  # pragma: no cover - nothing to cancel, run() is synchronous
        pass


@pytest.fixture
def crashing_runner() -> _CrashingRunner:
    return _CrashingRunner()


class _SlowRunner:
    """Blocks in `run()` until `cancel()` is called, then raises `WorkerCancelled`."""

    def __init__(self) -> None:
        self._cancel_event = threading.Event()

    def run(self, request: DebriefRequest, on_event: Callable[[Event], None]) -> ResultEvent:
        on_event(StageEvent(stage=Stage.TRANSCRIBING))
        self._cancel_event.wait()
        raise WorkerCancelled()

    def cancel(self) -> None:
        self._cancel_event.set()


@pytest.fixture
def slow_runner() -> _SlowRunner:
    return _SlowRunner()


class _StuckRunner:
    """`cancel()` is a no-op; `run()` only unblocks when the test sets `release_event`.

    Models a runner whose cancellation can't actually interrupt it (e.g. a
    subprocess that ignores `terminate()`), so `DebriefJob.shutdown()`'s
    bounded-wait give-up path can be exercised deterministically.
    """

    def __init__(self) -> None:
        self.release_event = threading.Event()

    def run(self, request: DebriefRequest, on_event: Callable[[Event], None]) -> ResultEvent:
        on_event(StageEvent(stage=Stage.TRANSCRIBING))
        self.release_event.wait()
        raise WorkerCancelled()

    def cancel(self) -> None:
        pass  # deliberately does NOT unblock run()


@pytest.fixture
def stuck_runner() -> _StuckRunner:
    return _StuckRunner()


class _RunRecordingRunner:
    """Records whether `run()` was ever actually invoked — for cancel-before-start races."""

    def __init__(self) -> None:
        self.run_called = False

    def run(self, request: DebriefRequest, on_event: Callable[[Event], None]) -> ResultEvent:
        self.run_called = True
        raise AssertionError("run() was called despite cancellation before it started")

    def cancel(self) -> None:
        pass


@pytest.fixture
def run_recording_runner() -> _RunRecordingRunner:
    return _RunRecordingRunner()
