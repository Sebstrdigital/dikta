"""Tests for `MainWindow`, driven with fake `Runner`s from `conftest.py`."""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from pathlib import Path

from PySide6.QtWidgets import QApplication

from dikta.app import debrief_job as debrief_job_module
from dikta.app import main_window as main_window_module
from dikta.app.debrief_job import DebriefJob
from dikta.app.main_window import MainWindow
from dikta.engines.llm.factory import EngineKind


def _wait_until(predicate: Callable[[], bool], timeout_s: float = 5.0) -> None:
    """Pump the Qt event loop until `predicate()` is true, or fail after `timeout_s`."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        QApplication.processEvents()
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError(f"condition not met within {timeout_s}s")


def _make_audio_file(tmp_path: Path, name: str = "recording.m4a") -> Path:
    path = tmp_path / name
    path.write_bytes(b"not real audio, extension is all that matters here")
    return path


# -- successful / failing / cancelling runs -----------------------------------


def test_successful_run_updates_ui(qapp, fake_runner, tmp_path) -> None:
    audio = _make_audio_file(tmp_path)
    window = MainWindow(runner_factory=lambda: fake_runner)

    sv_index = window._language_combo.findData("sv")
    window._language_combo.setCurrentIndex(sv_index)

    observed_stages: list[str] = []
    original_on_stage_changed = window._on_stage_changed

    def _spy(stage: str) -> None:
        observed_stages.append(stage)
        original_on_stage_changed(stage)

    window._on_stage_changed = _spy

    window._drop_zone.file_dropped.emit(audio)
    _wait_until(lambda: window._last_result is not None)

    assert observed_stages == ["loading", "transcribing", "summarizing", "saving"]
    assert window._text_view.toPlainText() == fake_runner.rendered_text
    assert window._open_folder_button.isEnabled()
    assert window.current_request is not None
    assert window.current_request.file == audio
    assert window.current_request.language == "sv"


def test_successful_run_with_detected_language_logs_and_updates_status(
    qapp, fake_runner_with_language, tmp_path, caplog
) -> None:
    audio = _make_audio_file(tmp_path)
    window = MainWindow(runner_factory=lambda: fake_runner_with_language)

    with caplog.at_level(logging.INFO, logger="dikta.app.main_window"):
        window._drop_zone.file_dropped.emit(audio)
        _wait_until(lambda: window._last_result is not None)

    assert window._status_label.text() == "Done (language: sv)"
    assert any(
        str(fake_runner_with_language.folder) in record.message and "sv" in record.message
        for record in caplog.records
    )


def test_failing_run_with_empty_transcript_shows_plain_message(
    qapp, failing_runner, tmp_path
) -> None:
    audio = _make_audio_file(tmp_path)
    runner = failing_runner("empty_transcript", "no speech detected")
    window = MainWindow(runner_factory=lambda: runner)

    window._drop_zone.file_dropped.emit(audio)
    _wait_until(lambda: window._status_label.text() != "")

    assert window._status_label.text() == "No speech was detected in that file."
    assert not window._drop_zone.is_busy
    assert window._job is None


def test_crashing_runner_reports_unexpected_and_leaves_busy_state(
    qapp, crashing_runner, tmp_path
) -> None:
    audio = _make_audio_file(tmp_path)
    window = MainWindow(runner_factory=lambda: crashing_runner)

    window._drop_zone.file_dropped.emit(audio)
    _wait_until(lambda: window._status_label.text() != "")

    assert window._status_label.text() == "Something went wrong: kaboom"
    assert not window._cancel_button.isEnabled()
    assert not window._progress_bar.isVisibleTo(window)
    assert not window._drop_zone.is_busy
    assert window._job is None


def test_cancel_stops_background_thread_and_reenables_drop_zone(
    qapp, slow_runner, tmp_path
) -> None:
    audio = _make_audio_file(tmp_path)
    window = MainWindow(runner_factory=lambda: slow_runner)

    window._drop_zone.file_dropped.emit(audio)
    job = window._job
    assert job is not None
    qthread = job.qthread
    assert qthread is not None

    _wait_until(lambda: window._cancel_button.isEnabled())
    window._cancel_button.click()

    # `qthread` gets `deleteLater()`'d once the job finalizes, and further
    # event-loop pumps (each `_wait_until` call processes events) can
    # actually carry out that deferred delete — so the "thread stopped"
    # check on the live `QThread` object must happen in this one
    # `_wait_until` call and not be re-touched afterwards.
    _wait_until(lambda: not qthread.isRunning(), timeout_s=3.0)
    _wait_until(lambda: not window._drop_zone.is_busy, timeout_s=3.0)
    _wait_until(lambda: window._status_label.text() == "Cancelled", timeout_s=3.0)

    assert window._job is None


# -- closeEvent / shutdown() bounded-wait behavior -----------------------------


def test_close_with_cancelable_runner_returns_quickly(qapp, slow_runner, tmp_path) -> None:
    """`slow_runner.cancel()` actually unblocks `run()`, so `close()` should be fast."""
    audio = _make_audio_file(tmp_path)
    window = MainWindow(runner_factory=lambda: slow_runner)
    window._drop_zone.file_dropped.emit(audio)
    assert window._job is not None

    start = time.monotonic()
    window.close()
    elapsed = time.monotonic() - start

    assert elapsed < 1.0
    assert window._job is None


def test_close_with_stuck_runner_gives_up_within_bounded_time(
    qapp, stuck_runner, tmp_path, monkeypatch
) -> None:
    """`shutdown()` must never block the GUI thread unboundedly.

    `stuck_runner.cancel()` is deliberately a no-op, so `shutdown()` is
    forced down its give-up path. The production wait budgets
    (`_SHUTDOWN_FIRST_WAIT_MS`/`_SHUTDOWN_RETRY_WAIT_MS`, ~5s + ~2s) are
    patched down here so this test exercises the same bounded
    retry-then-give-up code path without burning ~7s of real wall-clock
    time in the suite.
    """
    monkeypatch.setattr(debrief_job_module, "_SHUTDOWN_FIRST_WAIT_MS", 150)
    monkeypatch.setattr(debrief_job_module, "_SHUTDOWN_RETRY_WAIT_MS", 150)

    audio = _make_audio_file(tmp_path)
    window = MainWindow(runner_factory=lambda: stuck_runner)
    window._drop_zone.file_dropped.emit(audio)
    job = window._job
    assert job is not None
    qthread = job.qthread
    assert qthread is not None

    # Wait for `stuck_runner.run()` to have actually started and reached
    # its blocking wait (it reports this stage right before blocking) —
    # otherwise `close()` could race the worker's own pre-start
    # cancellation check and skip calling `run()` altogether, which would
    # falsely "pass" without ever exercising the give-up path this test
    # targets.
    _wait_until(lambda: window._status_label.text() == "Transcribing…", timeout_s=2.0)

    start = time.monotonic()
    window.close()
    elapsed = time.monotonic() - start

    assert elapsed < 2.0  # bounded by the patched ~0.3s budget, not unbounded
    assert qthread.isRunning()  # cancel() was a no-op — the thread is still blocked

    # Release it now so the thread actually ends and nothing is torn down
    # (app teardown, GC) while a QThread is still alive underneath it.
    stuck_runner.release_event.set()
    _wait_until(lambda: not qthread.isRunning(), timeout_s=3.0)


def test_close_immediately_after_drop_never_calls_run(
    qapp, run_recording_runner, tmp_path
) -> None:
    """Closing before the worker thread ever reaches `run()` must skip `runner.run()`.

    Relies on ordinary CPython/GIL scheduling: `close()` runs with no
    intervening blocking call after `file_dropped.emit()`, so in practice
    the background thread never gets a chance to start executing before
    the main thread's cancellation flag is set.
    """
    audio = _make_audio_file(tmp_path)
    window = MainWindow(runner_factory=lambda: run_recording_runner)

    window._drop_zone.file_dropped.emit(audio)
    job = window._job
    assert job is not None

    window.close()

    _wait_until(lambda: job.qthread is None or not job.qthread.isRunning(), timeout_s=3.0)
    assert run_recording_runner.run_called is False


# -- transcript toggle ---------------------------------------------------------


def test_transcript_toggle_resets_before_new_run(qapp, fake_runner, tmp_path) -> None:
    """A stale 'Show summary' label from a previous run must never survive a new drop."""
    first_audio = _make_audio_file(tmp_path, "one.m4a")
    window = MainWindow(runner_factory=lambda: fake_runner)

    window._drop_zone.file_dropped.emit(first_audio)
    _wait_until(lambda: window._last_result is not None)

    window._transcript_toggle.setChecked(True)
    assert window._transcript_toggle.text() == "Show summary"
    assert window._text_view.toPlainText() == fake_runner.transcript

    second_audio = _make_audio_file(tmp_path, "two.m4a")
    window._drop_zone.file_dropped.emit(second_audio)

    # The reset happens synchronously as part of starting the new job —
    # no need to wait for it to finish to observe the label/checked state.
    assert not window._transcript_toggle.isChecked()
    assert window._transcript_toggle.text() == "Show transcript"

    _wait_until(lambda: window._last_result is not None)
    assert window._text_view.toPlainText() == fake_runner.rendered_text


# -- DebriefJob lifecycle / cleanup ---------------------------------------------


def test_debriefjob_children_do_not_accumulate_across_runs(qapp, fake_runner, tmp_path) -> None:
    window = MainWindow(runner_factory=lambda: fake_runner)

    for name in ("one.m4a", "two.m4a"):
        audio = _make_audio_file(tmp_path, name)
        window._drop_zone.file_dropped.emit(audio)
        _wait_until(lambda: window._last_result is not None)
        # Give the event loop a chance to process the finished job's
        # deferred deleteLater() before the next run starts.
        for _ in range(5):
            QApplication.processEvents()

    assert len(window.findChildren(DebriefJob)) <= 1


# -- engine / language selection and persistence --------------------------------


def test_engine_combo_heuristic_is_used_in_request(qapp, fake_runner, tmp_path) -> None:
    audio = _make_audio_file(tmp_path)
    window = MainWindow(runner_factory=lambda: fake_runner)

    heuristic_index = window._engine_combo.findData(EngineKind.HEURISTIC)
    window._engine_combo.setCurrentIndex(heuristic_index)

    window._drop_zone.file_dropped.emit(audio)
    _wait_until(lambda: window._last_result is not None)

    assert window.current_request is not None
    assert window.current_request.engine_kind == EngineKind.HEURISTIC


def test_language_defaults_to_english_when_nothing_stored(qapp) -> None:
    window = MainWindow()

    assert window._language_combo.currentText() == "English"
    assert window._selected_language() == "en"


def test_language_choice_persists_across_windows(qapp) -> None:
    first = MainWindow()
    sv_index = first._language_combo.findData("sv")
    first._language_combo.setCurrentIndex(sv_index)
    first.close()

    second = MainWindow()
    assert second._language_combo.currentText() == "Svenska"
    assert second._selected_language() == "sv"


def test_engine_choice_persists_across_windows(qapp) -> None:
    first = MainWindow()
    heuristic_index = first._engine_combo.findData(EngineKind.HEURISTIC)
    first._engine_combo.setCurrentIndex(heuristic_index)
    first.close()

    second = MainWindow()
    assert second._engine_combo.currentText() == "Heuristic"


def test_restore_settings_ignores_garbage_language_value(qapp) -> None:
    # `main_window_module.QSettings` (not the raw import) — `qsettings_scratch`
    # patches that name to a subclass that actually honors the ini
    # redirection; see that fixture's docstring for why the raw 2-arg
    # `QSettings(organization, application)` constructor doesn't.
    settings = main_window_module.QSettings("Dikta", "DiktaPy")
    settings.setValue(main_window_module._SETTINGS_LANGUAGE_KEY, "not-a-lang")
    window = MainWindow()
    assert window._language_combo.currentText() == "English"


def test_restore_settings_ignores_garbage_engine_value(qapp) -> None:
    settings = main_window_module.QSettings("Dikta", "DiktaPy")
    settings.setValue(main_window_module._SETTINGS_ENGINE_KEY, "not-an-engine")
    window = MainWindow()
    assert window._engine_combo.currentText() == "Auto"


# -- dev-only STT model combo ---------------------------------------------------


def test_dev_stt_combo_hidden_by_default(qapp, monkeypatch) -> None:
    monkeypatch.delenv("DIKTA_DEV", raising=False)
    window = MainWindow()
    assert window._dev_mode is False
    assert not window._stt_model_combo.isVisibleTo(window)


def test_dev_stt_combo_shown_with_dikta_dev_env(qapp, monkeypatch) -> None:
    monkeypatch.setenv("DIKTA_DEV", "1")
    window = MainWindow()
    assert window._dev_mode is True
    assert window._stt_model_combo.isVisibleTo(window)


# -- request building ------------------------------------------------------------


def test_store_root_is_forwarded_into_request(qapp, fake_runner, tmp_path) -> None:
    custom_root = tmp_path / "custom-store"
    audio = _make_audio_file(tmp_path)
    window = MainWindow(runner_factory=lambda: fake_runner, store_root=custom_root)

    window._drop_zone.file_dropped.emit(audio)
    _wait_until(lambda: window._last_result is not None)

    assert window.current_request is not None
    assert window.current_request.store_root == custom_root


# -- result actions ---------------------------------------------------------------


def test_copy_summary_puts_rendered_text_on_clipboard(qapp, fake_runner, tmp_path) -> None:
    audio = _make_audio_file(tmp_path)
    window = MainWindow(runner_factory=lambda: fake_runner)

    window._drop_zone.file_dropped.emit(audio)
    _wait_until(lambda: window._last_result is not None)

    window._copy_button.click()
    assert QApplication.clipboard().text() == fake_runner.rendered_text
