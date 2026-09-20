"""Load audio files into 16 kHz mono float32 samples for Whisper.

Python/PyAV port of ``AudioFileLoader.swift``
(``dikta-macos/Dikta/Services/Debrief/AudioFileLoader.swift``). Multi-channel
input is downmixed to mono by **averaging all channels**, matching the
Swift original exactly (it has to average by hand, because
``AVAudioConverter`` silently drops every channel but the first when given
an explicit mono destination format with no channel map). This loader
deliberately avoids asking PyAV's resampler to do the channel remap itself:
``libswresample``'s default multi-channel-to-mono matrix is a
power-preserving mix (~1/sqrt(2) per channel for stereo, not 0.5/0.5), which
changes gain and can clip material where the channels are similar. Instead
the resampler is only asked to change sample rate/format, keeping the
source's own channel layout, and this module does the channel average by
hand with ``numpy`` afterward — the same operation the Swift version
performs explicitly.
"""

from __future__ import annotations

import logging
from pathlib import Path

import av
import numpy as np

from dikta.engines.audio.errors import (
    AudioConversionFailed,
    AudioFileEmpty,
    AudioFileUnreadable,
    AudioFileUnsupportedFormat,
)

__all__ = ["SUPPORTED_EXTENSIONS", "TARGET_SAMPLE_RATE", "AudioFileLoader"]

_log = logging.getLogger("dikta.engines.audio")

#: File extensions this loader accepts (lowercase, no leading dot).
#: Mirrors ``AudioFileLoader.supportedExtensions`` in the Swift original.
SUPPORTED_EXTENSIONS: frozenset[str] = frozenset(
    {"m4a", "mp3", "wav", "caf", "aiff", "aif", "mp4", "m4b", "flac"}
)

#: Sample rate Whisper expects.
TARGET_SAMPLE_RATE = 16_000


def _validate_extension(path: Path) -> None:
    """Raise :class:`AudioFileUnsupportedFormat` unless `path`'s extension is supported.

    Called before the file is opened, so an unsupported format is rejected
    without ever touching disk I/O beyond the extension check itself.
    """
    extension = path.suffix.lstrip(".").lower()
    if extension not in SUPPORTED_EXTENSIONS:
        raise AudioFileUnsupportedFormat(path)


def _open_container(path: Path) -> av.container.InputContainer:
    """Open `path` as a PyAV container, raising `AudioFileUnreadable` on any failure."""
    if not path.exists():
        raise AudioFileUnreadable(path)
    try:
        return av.open(str(path))
    except Exception as exc:  # noqa: BLE001 - any PyAV/FFmpeg failure means "unreadable"
        raise AudioFileUnreadable(path) from exc


def _first_audio_stream(
    container: av.container.InputContainer, path: Path
) -> av.audio.stream.AudioStream:
    """Return the container's first audio stream, or raise `AudioFileUnreadable`."""
    try:
        return next(iter(container.streams.audio))
    except StopIteration as exc:
        raise AudioFileUnreadable(path) from exc


def _frame_to_mono_array(frame: av.AudioFrame) -> np.ndarray:
    """Downmix a resampled `AudioFrame` (any channel count) to mono by averaging.

    `frame` keeps the source's own channel layout (the resampler is never
    asked to remap channels — see the module docstring for why), so
    `to_ndarray()` returns a `(channels, samples)` array for multi-channel
    planar audio, or occasionally a flat 1-D array for a single channel.
    Averaging over the channel axis is what `AudioFileLoader.swift` does by
    hand; for a single channel it's a no-op.
    """
    array = np.asarray(frame.to_ndarray(), dtype=np.float32)
    if array.ndim == 1:
        return array
    return array.mean(axis=0, dtype=np.float32)


class AudioFileLoader:
    """Loads audio files into 16 kHz mono float32 sample arrays."""

    def load(self, path: Path | str) -> np.ndarray:
        """Load `path` and return its audio as 16 kHz mono float32 samples in [-1, 1].

        Raises:
            AudioFileUnsupportedFormat: `path`'s extension isn't supported.
            AudioFileUnreadable: the file is missing or PyAV can't open/read it.
            AudioConversionFailed: decoding or resampling raised an error.
            AudioFileEmpty: the file decoded successfully but has zero samples.
        """
        path = Path(path)
        _validate_extension(path)
        container = _open_container(path)
        try:
            stream = _first_audio_stream(container, path)
            # `layout` is omitted so the resampler keeps the source's own
            # channel layout (no automatic downmix) and only changes
            # format/rate; `_frame_to_mono_array` does the channel average
            # by hand afterward, matching the Swift original.
            resampler = av.AudioResampler(format="fltp", rate=TARGET_SAMPLE_RATE)
            chunks: list[np.ndarray] = []
            try:
                for frame in container.decode(stream):
                    for resampled in resampler.resample(frame):
                        chunks.append(_frame_to_mono_array(resampled))
                # Flush: libswresample buffers samples internally and may hold
                # back a partial block until told there is no more input.
                for resampled in resampler.resample(None):
                    chunks.append(_frame_to_mono_array(resampled))
            except Exception as exc:  # noqa: BLE001 - any decode/resample failure
                raise AudioConversionFailed(str(exc)) from exc
        finally:
            container.close()

        chunks = [chunk for chunk in chunks if chunk.size > 0]
        if not chunks:
            raise AudioFileEmpty(path)
        samples = np.concatenate(chunks).astype(np.float32, copy=False)
        if samples.size == 0:
            raise AudioFileEmpty(path)
        _log.debug(
            "loaded %d samples (%.2fs) from %s",
            samples.size,
            samples.size / TARGET_SAMPLE_RATE,
            path,
        )
        return samples

    def duration(self, path: Path | str) -> float:
        """Return the duration of the audio at `path`, in seconds.

        Uses the container/stream-reported duration when available, falling
        back to decoding the file and summing frame sample counts.

        Raises:
            AudioFileUnsupportedFormat: `path`'s extension isn't supported,
                or the stream has no usable sample rate.
            AudioFileUnreadable: the file is missing or PyAV can't open/read it.
            AudioConversionFailed: the decode-count fallback raised an error.
        """
        path = Path(path)
        _validate_extension(path)
        container = _open_container(path)
        try:
            stream = _first_audio_stream(container, path)

            if stream.duration is not None and stream.time_base is not None:
                return float(stream.duration * stream.time_base)
            if container.duration is not None:
                return container.duration / 1_000_000  # av.TIME_BASE is microseconds

            total_samples = 0
            sample_rate = stream.sample_rate or 0
            try:
                for frame in container.decode(stream):
                    total_samples += frame.samples
                    sample_rate = frame.sample_rate or sample_rate
            except Exception as exc:  # noqa: BLE001
                raise AudioConversionFailed(str(exc)) from exc
            if sample_rate <= 0:
                raise AudioFileUnsupportedFormat(path)
            return total_samples / sample_rate
        finally:
            container.close()
