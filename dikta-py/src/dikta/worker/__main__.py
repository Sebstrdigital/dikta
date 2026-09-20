"""Entry point for `python -m dikta.worker`: the debrief worker subprocess.

The very first thing this module does, before importing anything else, is
move the process's real stdout file descriptor out of the way so fd 1 (and
therefore `sys.stdout`, plus any raw `os.write(1, ...)` or C-level stdout
write from a dependency such as ctranslate2) points at stderr instead. Only
`_PROTOCOL_STREAM` -- a dedicated file object opened on a *duplicate* of the
original stdout fd, captured before the swap -- still writes to the real
stdout our parent process reads. This guarantees protocol lines
(`dikta.worker.protocol.Event`, one per line) are the ONLY thing that ever
reaches the parent's stdout pipe, no matter how loudly a dependency
misbehaves.

Reads one JSON `DebriefRequest` from stdin, runs it, and writes one JSON
`Event` per line to the protocol stream (flushed after each line) until the
run finishes. Exits with `child.run`'s returned status code.
"""

from __future__ import annotations

import os
import sys

#: Duplicate of the original stdout fd, reserved for protocol lines. Must
#: be captured, and fd 1 redirected, before importing anything below --
#: `dikta.worker.child` pulls in audio/STT/summarizer engines that could
#: write to stdout as a side effect of loading or running (e.g.
#: ctranslate2's own C++ logging).
_PROTOCOL_FD = os.dup(1)
os.dup2(2, 1)
sys.stdout = sys.stderr
_PROTOCOL_STREAM = os.fdopen(_PROTOCOL_FD, "w", encoding="utf-8", buffering=1)

from dikta.worker import child  # noqa: E402 - must come after the stdout redirect above
from dikta.worker.protocol import DebriefRequest, Event  # noqa: E402


def _emit(event: Event) -> None:
    _PROTOCOL_STREAM.write(event.model_dump_json())
    _PROTOCOL_STREAM.write("\n")
    _PROTOCOL_STREAM.flush()


def main() -> int:
    raw = sys.stdin.read()
    request = DebriefRequest.model_validate_json(raw)
    return child.run(request, _emit)


if __name__ == "__main__":
    sys.exit(main())
