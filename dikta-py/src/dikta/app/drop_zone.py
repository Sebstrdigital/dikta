"""Drag-and-drop / click-to-browse target for picking one debrief recording."""

from __future__ import annotations

import logging
from pathlib import Path

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtGui import QDragEnterEvent, QDropEvent
from PySide6.QtWidgets import QFileDialog, QFrame, QLabel, QVBoxLayout

from dikta.engines.audio.loader import SUPPORTED_EXTENSIONS

__all__ = ["DropZone"]

_log = logging.getLogger("dikta.app.drop_zone")

_IDLE_TEXT = "Drop a debrief recording here, or click to choose"
_BUSY_TEXT = "Working…"
_HINT_DURATION_MS = 3_000

_IDLE_STYLE = "DropZone { border: 2px dashed palette(mid); border-radius: 8px; }"
_HOVER_STYLE = "DropZone { border: 2px solid palette(highlight); border-radius: 8px; }"
_BUSY_STYLE = "DropZone { border: 2px dashed palette(mid); border-radius: 8px; }"


def _dialog_filter() -> str:
    """Build a `QFileDialog` name filter from `SUPPORTED_EXTENSIONS`."""
    patterns = " ".join(f"*.{ext}" for ext in sorted(SUPPORTED_EXTENSIONS))
    return f"Audio files ({patterns})"


def _single_local_path(event: QDragEnterEvent | QDropEvent) -> Path | None:
    """Return the one local file `Path` this event carries, or `None`.

    `None` covers every rejection case at once: no URLs, more than one URL,
    or a non-local URL (e.g. a browser drag of a remote link).
    """
    urls = event.mimeData().urls()
    if len(urls) != 1 or not urls[0].isLocalFile():
        return None
    return Path(urls[0].toLocalFile())


def _is_supported(path: Path) -> bool:
    """Extension in `SUPPORTED_EXTENSIONS` AND an actual file (not a directory).

    A directory can share an audio-like suffix (e.g. a bundle named
    `x.mp4`), so the extension check alone isn't enough.
    """
    if path.suffix.lstrip(".").lower() not in SUPPORTED_EXTENSIONS:
        return False
    return path.is_file()


class DropZone(QFrame):
    """A frame accepting drag-and-drop (or a click-to-browse) of one audio file.

    Emits `file_dropped(Path)` when a single file with a supported extension
    is dropped or chosen. Call `set_busy(True)` while a job is running to
    disable interaction and show a busy state.
    """

    file_dropped = Signal(Path)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setAcceptDrops(True)
        self._busy = False

        self._label = QLabel(_IDLE_TEXT, self)
        self._label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._label.setWordWrap(True)

        layout = QVBoxLayout(self)
        layout.addWidget(self._label)

        self._hint_timer = QTimer(self)
        self._hint_timer.setSingleShot(True)
        self._hint_timer.timeout.connect(self._clear_hint)

        self._apply_style(_IDLE_STYLE)

    @property
    def is_busy(self) -> bool:
        return self._busy

    def set_busy(self, busy: bool) -> None:
        """Enable/disable interaction and switch between idle and busy visuals."""
        self._busy = busy
        self.setEnabled(not busy)
        self._hint_timer.stop()
        if busy:
            self._label.setText(_BUSY_TEXT)
            self._apply_style(_BUSY_STYLE)
        else:
            self._label.setText(_IDLE_TEXT)
            self._apply_style(_IDLE_STYLE)

    def dragEnterEvent(self, event: QDragEnterEvent) -> None:  # noqa: N802 - Qt override
        if self._busy:
            event.ignore()
            return
        path = _single_local_path(event)
        if path is not None and _is_supported(path):
            event.acceptProposedAction()
            self._apply_style(_HOVER_STYLE)
        else:
            event.ignore()

    def dragLeaveEvent(self, event) -> None:  # noqa: N802 - Qt override
        if not self._busy:
            self._apply_style(_IDLE_STYLE)
        super().dragLeaveEvent(event)

    def dropEvent(self, event: QDropEvent) -> None:  # noqa: N802 - Qt override
        self._apply_style(_BUSY_STYLE if self._busy else _IDLE_STYLE)
        if self._busy:
            event.ignore()
            return
        path = _single_local_path(event)
        if path is None or not _is_supported(path):
            event.ignore()
            if path is not None:
                self._show_hint(f"Unsupported file type: {path.suffix.lower()}")
            return
        event.acceptProposedAction()
        _log.debug("file dropped: %s", path)
        self.file_dropped.emit(path)

    def mousePressEvent(self, event) -> None:  # noqa: N802 - Qt override
        if not self._busy and event.button() == Qt.MouseButton.LeftButton:
            self._browse()
        super().mousePressEvent(event)

    def _browse(self) -> None:
        file_name, _ = QFileDialog.getOpenFileName(self, "Choose a recording", "", _dialog_filter())
        if file_name:
            path = Path(file_name)
            _log.debug("file chosen: %s", path)
            self.file_dropped.emit(path)

    def _show_hint(self, text: str) -> None:
        self._label.setText(text)
        self._hint_timer.start(_HINT_DURATION_MS)

    def _clear_hint(self) -> None:
        if not self._busy:
            self._label.setText(_IDLE_TEXT)

    def _apply_style(self, stylesheet: str) -> None:
        self.setStyleSheet(stylesheet)
