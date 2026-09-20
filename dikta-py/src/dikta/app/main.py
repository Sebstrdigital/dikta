"""GUI entry point: `python -m dikta.app` (a `dikta gui` CLI subcommand wires to this later)."""

from __future__ import annotations

import logging
import sys

from PySide6.QtWidgets import QApplication

from dikta.app.main_window import MainWindow

__all__ = ["main"]


def main(argv: list[str] | None = None) -> int:
    """Show the debrief window and run the Qt event loop until it closes."""
    if not logging.getLogger().hasHandlers():
        # Only when nothing else configured logging yet (e.g. launched as
        # `dikta gui`, not via `--in-process`/tests, which may already have
        # a handler installed) -- never overrides a caller's own setup.
        logging.basicConfig(
            level=logging.INFO,
            stream=sys.stderr,
            format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        )

    args = sys.argv if argv is None else argv
    app = QApplication.instance() or QApplication(args)
    app.setApplicationName("Dikta")

    window = MainWindow()
    window.show()

    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
