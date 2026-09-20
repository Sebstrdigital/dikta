"""Tests for `DropZone`.

`QMimeData` has no parent, so a temporary built inline and passed straight
into a `QDragEnterEvent`/`QDropEvent` constructor gets garbage-collected as
soon as the constructor call returns, leaving the event with a dangling
pointer (segfaults on `event.mimeData()`). Every test therefore binds the
`QMimeData` to a local name that stays alive for the whole test body.

`DropZone` requires the dropped path to actually be a file (not just have a
supported extension, since a directory can share an audio-like suffix), so
these tests create real files/directories under `tmp_path` rather than
referencing paths that don't exist on disk.
"""

from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QEvent, QMimeData, QPoint, QPointF, Qt, QUrl
from PySide6.QtGui import QDragEnterEvent, QDropEvent

from dikta.app.drop_zone import DropZone


def _mime_for(*paths: Path | str) -> QMimeData:
    mime = QMimeData()
    mime.setUrls([QUrl.fromLocalFile(str(p)) for p in paths])
    return mime


def _drag_enter_event(mime: QMimeData) -> QDragEnterEvent:
    return QDragEnterEvent(
        QPoint(0, 0),
        Qt.DropAction.CopyAction,
        mime,
        Qt.MouseButton.NoButton,
        Qt.KeyboardModifier.NoModifier,
    )


def _drop_event(mime: QMimeData) -> QDropEvent:
    return QDropEvent(
        QPointF(0, 0),
        Qt.DropAction.CopyAction,
        mime,
        Qt.MouseButton.NoButton,
        Qt.KeyboardModifier.NoModifier,
        QEvent.Type.Drop,
    )


def _make_file(tmp_path: Path, name: str) -> Path:
    path = tmp_path / name
    path.write_bytes(b"not real audio, extension is all that matters here")
    return path


def test_drag_enter_accepts_supported_extension_lowercase(qapp, tmp_path) -> None:
    zone = DropZone()
    audio = _make_file(tmp_path, "recording.m4a")
    mime = _mime_for(audio)
    event = _drag_enter_event(mime)
    zone.dragEnterEvent(event)
    assert event.isAccepted()


def test_drag_enter_accepts_supported_extension_uppercase(qapp, tmp_path) -> None:
    zone = DropZone()
    audio = _make_file(tmp_path, "recording.WAV")
    mime = _mime_for(audio)
    event = _drag_enter_event(mime)
    zone.dragEnterEvent(event)
    assert event.isAccepted()


def test_drag_enter_rejects_unsupported_extension(qapp, tmp_path) -> None:
    zone = DropZone()
    notes = _make_file(tmp_path, "notes.txt")
    mime = _mime_for(notes)
    event = _drag_enter_event(mime)
    zone.dragEnterEvent(event)
    assert not event.isAccepted()


def test_drag_enter_rejects_directory_with_audio_extension(qapp, tmp_path) -> None:
    zone = DropZone()
    directory = tmp_path / "x.mp4"
    directory.mkdir()
    mime = _mime_for(directory)
    event = _drag_enter_event(mime)
    zone.dragEnterEvent(event)
    assert not event.isAccepted()


def test_drag_enter_rejects_multiple_files(qapp, tmp_path) -> None:
    zone = DropZone()
    one = _make_file(tmp_path, "one.m4a")
    two = _make_file(tmp_path, "two.m4a")
    mime = _mime_for(one, two)
    event = _drag_enter_event(mime)
    zone.dragEnterEvent(event)
    assert not event.isAccepted()


def test_drag_enter_rejects_non_local_url(qapp) -> None:
    zone = DropZone()
    mime = QMimeData()
    mime.setUrls([QUrl("http://example.com/recording.m4a")])
    event = _drag_enter_event(mime)
    zone.dragEnterEvent(event)
    assert not event.isAccepted()


def test_drop_emits_file_dropped_exactly_once(qapp, tmp_path) -> None:
    zone = DropZone()
    received: list[Path] = []
    zone.file_dropped.connect(received.append)

    audio = _make_file(tmp_path, "recording.m4a")
    mime = _mime_for(audio)
    event = _drop_event(mime)
    zone.dropEvent(event)

    assert event.isAccepted()
    assert received == [audio]


def test_drop_rejects_directory_and_does_not_emit(qapp, tmp_path) -> None:
    zone = DropZone()
    received: list[Path] = []
    zone.file_dropped.connect(received.append)

    directory = tmp_path / "x.mp4"
    directory.mkdir()
    mime = _mime_for(directory)
    event = _drop_event(mime)
    zone.dropEvent(event)

    assert not event.isAccepted()
    assert received == []


def test_drop_rejects_unsupported_extension_and_does_not_emit(qapp, tmp_path) -> None:
    zone = DropZone()
    received: list[Path] = []
    zone.file_dropped.connect(received.append)

    notes = _make_file(tmp_path, "notes.txt")
    mime = _mime_for(notes)
    event = _drop_event(mime)
    zone.dropEvent(event)

    assert not event.isAccepted()
    assert received == []


def test_drop_shows_hint_for_unsupported_extension(qapp, tmp_path) -> None:
    zone = DropZone()
    notes = _make_file(tmp_path, "notes.txt")
    mime = _mime_for(notes)
    event = _drop_event(mime)
    zone.dropEvent(event)
    assert zone._label.text() == "Unsupported file type: .txt"


def test_drop_rejects_multiple_files_and_does_not_emit(qapp, tmp_path) -> None:
    zone = DropZone()
    received: list[Path] = []
    zone.file_dropped.connect(received.append)

    one = _make_file(tmp_path, "one.m4a")
    two = _make_file(tmp_path, "two.m4a")
    mime = _mime_for(one, two)
    event = _drop_event(mime)
    zone.dropEvent(event)

    assert not event.isAccepted()
    assert received == []


def test_busy_drop_zone_rejects_drag_and_drop(qapp, tmp_path) -> None:
    zone = DropZone()
    zone.set_busy(True)
    received: list[Path] = []
    zone.file_dropped.connect(received.append)

    audio = _make_file(tmp_path, "recording.m4a")

    enter_mime = _mime_for(audio)
    enter_event = _drag_enter_event(enter_mime)
    zone.dragEnterEvent(enter_event)
    assert not enter_event.isAccepted()

    drop_mime = _mime_for(audio)
    drop_event = _drop_event(drop_mime)
    zone.dropEvent(drop_event)
    assert not drop_event.isAccepted()
    assert received == []
