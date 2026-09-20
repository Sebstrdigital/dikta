"""Enforces the layering rule: `dikta.core` must never import `dikta.engines`.

Runs in a fresh subprocess so `sys.modules` reflects only what importing
`dikta.core.debrief` itself pulls in — no leakage from other test modules
that happen to import `dikta.engines.*` earlier in the same process.
"""

from __future__ import annotations

import subprocess
import sys


def test_importing_core_debrief_never_imports_engines() -> None:
    code = (
        "import dikta.core.debrief, sys; "
        "assert not any(m.startswith('dikta.engines') for m in sys.modules), "
        "[m for m in sys.modules if m.startswith('dikta.engines')]"
    )
    result = subprocess.run(
        [sys.executable, "-c", code],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr
