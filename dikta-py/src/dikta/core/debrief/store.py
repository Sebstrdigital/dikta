"""Per-session folder writer for Call Debrief sessions.

Python port of ``DebriefStore`` (``dikta-macos/Dikta/Services/Debrief/DebriefStore.swift``).
Writes each debrief session (audio, transcript, summary) to its own
timestamped folder under a root directory (``~/Documents/Dikta`` by
default).

Scope note: the Swift original also exposes a two-track (``me.wav`` /
``them.wav``) streaming-writer API (``DebriefTrack``, ``audioURL(for:)``,
``hasTrack``, ``makeStreamingWriter``) for the live-call capture path.
That surface is intentionally not ported here — it is out of scope for
the file-import path this module serves.
"""

from __future__ import annotations

import logging
import os
import shutil
import wave
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from uuid import uuid4

import numpy as np

logger = logging.getLogger("dikta.core.debrief.store")

#: Sample rate written by `DebriefStore.write_audio`, matching
#: `AudioFileLoader.targetSampleRate` on the Swift side.
_SAMPLE_RATE_HZ = 16_000

#: PCM scale factor for float-to-int16 conversion. Matches Swift's
#: `Int16.max` (32767), used to scale *both* the positive and negative
#: sample range, so a sample of exactly -1.0 maps to -32767, not the
#: full-range -32768.
_INT16_MAX = 32767


@dataclass(frozen=True)
class SessionPaths:
    """Paths to the files that make up a single debrief session."""

    folder: Path

    @property
    def audio(self) -> Path:
        return self.folder / "audio.wav"

    @property
    def transcript(self) -> Path:
        return self.folder / "transcript.txt"

    @property
    def summary(self) -> Path:
        return self.folder / "summary.txt"

    def original_for(self, source: Path) -> Path:
        """Destination for a byte-copy of an imported source file.

        Preserves `source`'s lowercased extension (`original.m4a`); a
        source with no extension copies to a plain `original` file.
        """
        ext = source.suffix[1:].lower() if source.suffix else ""
        name = f"original.{ext}" if ext else "original"
        return self.folder / name


def default_root() -> Path:
    """Default root folder for debrief sessions: `~/Documents/Dikta`."""
    return Path.home() / "Documents" / "Dikta"


class DebriefStore:
    """Writes each debrief session to its own timestamped folder."""

    def __init__(
        self,
        root: Path | None = None,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._root = root if root is not None else default_root()
        self._clock = clock if clock is not None else datetime.now

    def create_session(self, date: datetime | None = None) -> SessionPaths:
        """Creates a new session folder named after `date` (or now).

        The folder name is `%Y-%m-%d_%H-%M-%S` in local time — matching
        Swift's `TimeZone.current` formatter. A naive `date`/`clock()`
        result is treated as already-local (used as given); a
        timezone-aware one is converted to local time first via
        `astimezone()`. If a folder with that name already exists under
        the root, `-2`, `-3`, etc. is appended until a free name is found.
        """
        resolved = date if date is not None else self._clock()
        if resolved.tzinfo is not None:
            resolved = resolved.astimezone()
        base_name = resolved.strftime("%Y-%m-%d_%H-%M-%S")

        candidate = base_name
        suffix = 2
        while (self._root / candidate).exists():
            candidate = f"{base_name}-{suffix}"
            suffix += 1

        folder = self._root / candidate
        folder.mkdir(parents=True)
        logger.debug("created debrief session folder %s", folder)
        return SessionPaths(folder=folder)

    def write_audio(self, samples: np.ndarray, paths: SessionPaths) -> None:
        """Writes 16 kHz mono Float32 `samples` as a 16-bit PCM mono WAV.

        `samples` must be 1-D, or 2-D with shape `(n, 1)` (squeezed to
        1-D); anything else raises `ValueError`. A NaN anywhere in
        `samples` also raises `ValueError` — the Swift original traps on
        it (`Int16(Float.nan)` is a runtime crash), so silently writing
        zeros would hide a bug rather than port the behavior.

        Each sample is clamped to [-1, 1], scaled by `Int16.max` (32767)
        and rounded half-away-from-zero — matching the Swift original's
        `Int16((clamped * Float(Int16.max)).rounded())`, whose default
        rounding rule is away-from-zero (unlike Python/NumPy's default
        round-half-to-even). No dithering.
        """
        arr = np.asarray(samples, dtype=np.float32)
        if arr.ndim == 2 and arr.shape[1] == 1:
            arr = arr.reshape(-1)
        if arr.ndim != 1:
            raise ValueError(
                f"write_audio expects 1-D samples (or shape (n, 1)), got shape {arr.shape}"
            )
        if np.isnan(arr).any():
            raise ValueError("write_audio samples contain NaN")

        clamped = np.clip(arr, -1.0, 1.0)
        scaled = clamped.astype(np.float64) * _INT16_MAX
        rounded = np.copysign(np.floor(np.abs(scaled) + 0.5), scaled)
        pcm = rounded.astype("<i2")  # little-endian int16, per AVLinearPCMIsBigEndianKey=false

        with wave.open(str(paths.audio), "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(_SAMPLE_RATE_HZ)
            wav_file.writeframes(pcm.tobytes())

    def copy_original(self, source: Path, paths: SessionPaths) -> Path:
        """Byte-copies `source` next to `audio.wav` as `original.<ext>`.

        Removes any existing file at the destination first. If `source`
        already *is* the destination (re-copying a file already at
        `original.<ext>` inside this session folder), returns it as-is
        without unlinking or copying.
        """
        destination = paths.original_for(source)
        if source.resolve() == destination.resolve():
            return destination
        if destination.exists():
            destination.unlink()
        shutil.copyfile(source, destination)
        return destination

    def write_transcript(self, text: str, paths: SessionPaths) -> None:
        """Writes `text` as UTF-8 to `paths.transcript`, atomically."""
        _atomic_write_text(text, paths.transcript)

    def write_summary(self, text: str, paths: SessionPaths) -> None:
        """Writes `text` as UTF-8 to `paths.summary`, atomically."""
        _atomic_write_text(text, paths.summary)


def _atomic_write_text(text: str, target: Path) -> None:
    """Writes `text` to `target` via a same-folder temp file + `os.replace`.

    Opened with `newline=""` so `\\n` in `text` is written verbatim
    (no platform newline translation, matching Swift's `String.write`).
    On any failure the temp file is removed before the exception
    propagates, so a failed write never leaves a stray temp file behind.
    """
    tmp = target.with_name(f".{target.name}.{uuid4().hex}.tmp")
    try:
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        os.replace(tmp, target)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise
