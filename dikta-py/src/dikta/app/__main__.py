"""Entry point for `python -m dikta.app`."""

from __future__ import annotations

import sys

from dikta.app.main import main

if __name__ == "__main__":
    sys.exit(main())
