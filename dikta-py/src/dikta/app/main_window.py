"""The drop-zone debrief window: pick a recording, watch progress, read the summary."""

from __future__ import annotations

import logging
import os
from collections.abc import Callable
from pathlib import Path
from typing import Protocol

from PySide6.QtCore import QSettings, QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from dikta.app.debrief_job import DebriefJob
from dikta.app.drop_zone import DropZone
from dikta.engines.llm.factory import EngineKind
from dikta.worker.protocol import DebriefRequest, Event, ResultEvent

__all__ = ["MainWindow", "Runner"]

_log = logging.getLogger("dikta.app.main_window")

#: Maps `StageEvent.stage` values to the text shown on the status line.
_STAGE_LABELS = {
    "loading": "Loading audio…",
    "transcribing": "Transcribing…",
    "summarizing": "Summarizing…",
    "saving": "Saving…",
}

#: Fixed status-line text for `ErrorEvent.kind` values that don't use their
#: own `message` (either because it's an internal detail, or because a
#: shorter, calmer phrasing reads better than the raw error text).
_ERROR_MESSAGES = {
    "empty_transcript": "No speech was detected in that file.",
    "transcription_timeout": "Transcription took too long and was stopped.",
}

#: Only shown when `DIKTA_DEV=1` — lets a developer force a specific
#: faster-whisper model size without editing code.
_DEV_STT_MODELS = ["tiny", "small", "medium", "large-v3-turbo"]

_SETTINGS_LANGUAGE_KEY = "language"
_SETTINGS_ENGINE_KEY = "engine"

#: `_selected_language()`'s fallback -- used when nothing is stored yet, or
#: the stored value doesn't match a combo item (a garbage/future value).
#: There's no "auto" choice: the STT engine still auto-detects on its own
#: when `--language`/`DebriefRequest.language` is left unset, but the GUI
#: always requests an explicit language rather than relying on that (see
#: `FasterWhisperEngine`'s candidate-restricted auto-detect, which the CLI
#: uses when its own `--language` is omitted).
_DEFAULT_LANGUAGE = "en"


class Runner(Protocol):
    """What `MainWindow` needs from a worker: run a request, report events, allow cancel.

    `dikta.worker.client.WorkerClient` satisfies this; tests substitute a
    fake so the window is testable without spawning a real subprocess.
    """

    def run(self, request: DebriefRequest, on_event: Callable[[Event], None]) -> ResultEvent: ...

    def cancel(self) -> None: ...


def _default_runner() -> Runner:
    """Build the real `WorkerClient`.

    Imported lazily so `dikta.app` keeps importing even in an environment
    where `dikta.worker.client` can't be imported (e.g. its own
    dependencies are unavailable) — that only breaks the default runner
    factory, not window construction or tests using an injected runner.
    """
    from dikta.worker.client import WorkerClient

    return WorkerClient()


def _error_message(kind: str, message: str) -> str:
    """Plain status-line text for an `ErrorEvent`, by `kind`."""
    if kind in _ERROR_MESSAGES:
        return _ERROR_MESSAGES[kind]
    if kind == "audio_file":
        return message
    return f"Something went wrong: {message}"


class MainWindow(QMainWindow):
    """Drop a debrief recording, watch it transcribe and summarize, read the result."""

    def __init__(
        self,
        runner_factory: Callable[[], Runner] | None = None,
        store_root: Path | None = None,
    ) -> None:
        super().__init__()
        self.setWindowTitle("Dikta — Debrief")
        self._runner_factory = runner_factory or _default_runner
        self._store_root = store_root
        self._dev_mode = os.environ.get("DIKTA_DEV") == "1"
        # "DiktaPy", not "Dikta": the Swift macOS app already uses
        # QSettings("Dikta", "Dikta")-equivalent NSUserDefaults storage at
        # ~/Library/Preferences/com.dikta.Dikta.plist (it holds Sparkle's
        # update state) — this Python port must never write into that file.
        self._settings = QSettings("Dikta", "DiktaPy")
        self._job: DebriefJob | None = None
        self.current_request: DebriefRequest | None = None
        self._last_result: ResultEvent | None = None

        self._build_ui()
        self._restore_settings()

    # -- UI construction -----------------------------------------------------

    def _build_ui(self) -> None:
        central = QWidget(self)
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)

        layout.addLayout(self._build_top_row(central))

        self._drop_zone = DropZone(central)
        self._drop_zone.file_dropped.connect(self._on_file_dropped)
        layout.addWidget(self._drop_zone, 1)

        self._status_label = QLabel("", central)
        layout.addWidget(self._status_label)

        self._progress_bar = QProgressBar(central)
        self._progress_bar.setRange(0, 0)  # indeterminate
        self._progress_bar.setVisible(False)
        layout.addWidget(self._progress_bar)

        self._cancel_button = QPushButton("Cancel", central)
        self._cancel_button.setEnabled(False)
        self._cancel_button.clicked.connect(self._on_cancel_clicked)
        layout.addWidget(self._cancel_button)

        self._text_view = QPlainTextEdit(central)
        self._text_view.setReadOnly(True)
        layout.addWidget(self._text_view, 2)

        layout.addLayout(self._build_bottom_row(central))

    def _build_top_row(self, parent: QWidget) -> QHBoxLayout:
        row = QHBoxLayout()

        self._language_combo = QComboBox(parent)
        self._language_combo.addItem("English", "en")
        self._language_combo.addItem("Svenska", "sv")
        self._language_combo.currentIndexChanged.connect(self._save_settings)
        row.addWidget(QLabel("Language:", parent))
        row.addWidget(self._language_combo)

        self._engine_combo = QComboBox(parent)
        self._engine_combo.addItem("Auto", EngineKind.AUTO)
        self._engine_combo.addItem("Ollama", EngineKind.OLLAMA)
        self._engine_combo.addItem("Heuristic", EngineKind.HEURISTIC)
        self._engine_combo.currentIndexChanged.connect(self._save_settings)
        row.addWidget(QLabel("Engine:", parent))
        row.addWidget(self._engine_combo)

        stt_label = QLabel("STT model:", parent)
        self._stt_model_combo = QComboBox(parent)
        for model in _DEV_STT_MODELS:
            self._stt_model_combo.addItem(model, model)
        stt_label.setVisible(self._dev_mode)
        self._stt_model_combo.setVisible(self._dev_mode)
        row.addWidget(stt_label)
        row.addWidget(self._stt_model_combo)

        row.addStretch(1)
        return row

    def _build_bottom_row(self, parent: QWidget) -> QHBoxLayout:
        row = QHBoxLayout()

        self._copy_button = QPushButton("Copy summary", parent)
        self._copy_button.setEnabled(False)
        self._copy_button.clicked.connect(self._on_copy_clicked)
        row.addWidget(self._copy_button)

        self._open_folder_button = QPushButton("Open folder", parent)
        self._open_folder_button.setEnabled(False)
        self._open_folder_button.clicked.connect(self._on_open_folder_clicked)
        row.addWidget(self._open_folder_button)

        self._transcript_toggle = QPushButton("Show transcript", parent)
        self._transcript_toggle.setEnabled(False)
        self._transcript_toggle.setCheckable(True)
        self._transcript_toggle.toggled.connect(self._on_transcript_toggled)
        row.addWidget(self._transcript_toggle)

        row.addStretch(1)
        return row

    # -- settings --------------------------------------------------------------

    def _restore_settings(self) -> None:
        language = self._settings.value(_SETTINGS_LANGUAGE_KEY, _DEFAULT_LANGUAGE)
        index = self._language_combo.findData(language)
        if index < 0:
            _log.warning("ignoring invalid stored language: %r", language)
            index = self._language_combo.findData(_DEFAULT_LANGUAGE)
        self._language_combo.setCurrentIndex(index)

        engine_raw = self._settings.value(_SETTINGS_ENGINE_KEY, str(EngineKind.AUTO))
        try:
            engine = EngineKind(engine_raw)
        except ValueError:
            _log.warning("ignoring invalid stored engine kind: %r", engine_raw)
            engine = EngineKind.AUTO
        index = self._engine_combo.findData(engine)
        if index >= 0:
            self._engine_combo.setCurrentIndex(index)

    def _save_settings(self) -> None:
        self._settings.setValue(_SETTINGS_LANGUAGE_KEY, self._language_combo.currentData())
        self._settings.setValue(_SETTINGS_ENGINE_KEY, str(self._engine_combo.currentData()))

    # -- request building --------------------------------------------------------

    def _selected_language(self) -> str:
        return self._language_combo.currentData()

    def _build_request(self, file: Path) -> DebriefRequest:
        kwargs: dict[str, object] = {
            "file": file,
            "language": self._selected_language(),
            "engine_kind": EngineKind(self._engine_combo.currentData()),
            # `candidate_languages` is left at `DebriefRequest`'s default
            # (["en", "sv"]) here -- no GUI widget drives it yet.
            # TODO: once this window grows a "Write in" language list like
            # the macOS app's, that selection should drive this instead.
        }
        if self._dev_mode:
            kwargs["stt_model"] = self._stt_model_combo.currentData()
        if self._store_root is not None:
            kwargs["store_root"] = self._store_root
        return DebriefRequest(**kwargs)

    # -- job lifecycle --------------------------------------------------------

    def _on_file_dropped(self, path: Path) -> None:
        if self._job is not None:
            return
        request = self._build_request(path)
        self.current_request = request

        # Reset the toggle (which may synchronously fire `_on_transcript_toggled`
        # if it was checked) *before* clearing `_last_result`, and before
        # disabling it — `_on_transcript_toggled` never early-returns, so this
        # ordering only matters for which text it briefly shows, not for
        # leaving the button's label inverted.
        self._transcript_toggle.setChecked(False)
        self._transcript_toggle.setEnabled(False)
        self._last_result = None

        self._text_view.clear()
        self._status_label.setText("")
        self._copy_button.setEnabled(False)
        self._open_folder_button.setEnabled(False)
        self._set_running(True)

        _log.info(
            "starting debrief job: file=%s language=%s engine=%s stt_model=%s "
            "candidate_languages=%s",
            request.file.name,
            request.language,
            request.engine_kind,
            request.stt_model,
            request.candidate_languages,
        )

        job = DebriefJob(self)
        job.stage_changed.connect(self._on_stage_changed)
        job.finished.connect(self._on_job_finished)
        job.failed.connect(self._on_job_failed)
        job.cancelled.connect(self._on_job_cancelled)
        self._job = job
        job.start(request, self._runner_factory())

    def _on_stage_changed(self, stage: str) -> None:
        _log.info("stage: %s", stage)
        self._status_label.setText(_STAGE_LABELS.get(stage, stage))

    def _on_job_finished(self, result: ResultEvent) -> None:
        _log.info(
            "debrief finished: folder=%s engine=%s language=%s",
            result.folder,
            result.engine_name,
            result.detected_language,
        )
        self._last_result = result
        status = "Done"
        if result.detected_language is not None:
            status = f"Done (language: {result.detected_language})"
        self._status_label.setText(status)
        self._set_running(False)
        self._text_view.setPlainText(result.rendered_text)
        self._copy_button.setEnabled(True)
        self._open_folder_button.setEnabled(True)
        self._transcript_toggle.setEnabled(True)
        self._job = None

    def _on_job_failed(self, kind: str, message: str) -> None:
        _log.warning("debrief failed: kind=%s message=%s", kind, message)
        self._status_label.setText(_error_message(kind, message))
        self._set_running(False)
        self._job = None

    def _on_job_cancelled(self) -> None:
        file_name = self.current_request.file.name if self.current_request is not None else None
        _log.warning("debrief cancelled: file=%s", file_name)
        self._status_label.setText("Cancelled")
        self._set_running(False)
        self._job = None

    def _set_running(self, running: bool) -> None:
        self._progress_bar.setVisible(running)
        self._cancel_button.setEnabled(running)
        self._drop_zone.set_busy(running)

    def _on_cancel_clicked(self) -> None:
        if self._job is not None:
            self._job.cancel()

    # -- result actions --------------------------------------------------------

    def _on_copy_clicked(self) -> None:
        if self._last_result is not None:
            QApplication.clipboard().setText(self._last_result.rendered_text)

    def _on_open_folder_clicked(self) -> None:
        if self._last_result is not None:
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(self._last_result.folder)))

    def _on_transcript_toggled(self, checked: bool) -> None:
        # Never early-returns: the button's label always matches `checked`,
        # even with no result yet (the text view just shows nothing in that
        # case), so a reset via `setChecked(False)` can never leave the
        # label showing the opposite of what's actually displayed.
        if checked:
            self._transcript_toggle.setText("Show summary")
            text = self._last_result.transcript if self._last_result is not None else ""
        else:
            self._transcript_toggle.setText("Show transcript")
            text = self._last_result.rendered_text if self._last_result is not None else ""
        self._text_view.setPlainText(text)

    # -- window lifecycle --------------------------------------------------------

    def closeEvent(self, event) -> None:  # noqa: N802 - Qt override
        if self._job is not None:
            _log.debug("cancelling running job on window close")
            self._job.shutdown()
            self._job = None
        super().closeEvent(event)
