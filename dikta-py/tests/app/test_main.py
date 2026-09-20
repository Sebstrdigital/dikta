"""Tests for the `python -m dikta.app` entry point."""

from __future__ import annotations

from PySide6.QtCore import QTimer
from PySide6.QtWidgets import QApplication

from dikta.app.main import main


def test_main_shows_window_and_returns_exec_code(qapp) -> None:
    """`main()` blocks in `app.exec()`; closing the window (here, via a timer) unblocks it."""
    QTimer.singleShot(50, QApplication.instance().quit)
    exit_code = main([])
    assert exit_code == 0
