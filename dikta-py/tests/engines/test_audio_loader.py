from __future__ import annotations

import wave
from pathlib import Path

import av
import numpy as np
import pytest

from dikta.engines.audio.errors import (
    AudioConversionFailed,
    AudioFileEmpty,
    AudioFileError,
    AudioFileUnreadable,
    AudioFileUnsupportedFormat,
)
from dikta.engines.audio.loader import TARGET_SAMPLE_RATE, AudioFileLoader


def _write_wav(path: Path, sample_rate: int, channels: list[np.ndarray]) -> None:
    """Write a 16-bit PCM WAV from one float32 array (values in [-1, 1]) per channel."""
    n_channels = len(channels)
    n_frames = len(channels[0]) if channels else 0
    interleaved = np.zeros(n_frames * n_channels, dtype=np.int16)
    for i, channel in enumerate(channels):
        interleaved[i::n_channels] = (np.clip(channel, -1.0, 1.0) * 32767).astype(np.int16)
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(n_channels)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(interleaved.tobytes())


def _sine(
    frequency: float, duration_s: float, sample_rate: int, amplitude: float = 1.0
) -> np.ndarray:
    t = np.arange(int(duration_s * sample_rate)) / sample_rate
    return (amplitude * np.sin(2 * np.pi * frequency * t)).astype(np.float32)


def _silence(duration_s: float, sample_rate: int) -> np.ndarray:
    return np.zeros(int(duration_s * sample_rate), dtype=np.float32)


def _constant(value: float, duration_s: float, sample_rate: int) -> np.ndarray:
    return np.full(int(duration_s * sample_rate), value, dtype=np.float32)


def _encode_aac_m4a(path: Path, samples: np.ndarray, sample_rate: int) -> None:
    """Encode a mono float32 array to AAC-in-M4A directly via PyAV.

    Avoids shelling out to the system `ffmpeg` binary (broken on this
    machine — it SIGABRTs on a missing `libass` dylib), by using PyAV's own
    bundled encoder instead: open an output container, add an "aac" stream,
    and feed it fixed-size frames in the codec's own sample format.
    """
    container = av.open(str(path), mode="w", format="mp4")
    stream = container.add_stream("aac", rate=sample_rate)
    stream.layout = "mono"
    frame_size = stream.frame_size or 1024

    pts = 0
    for start in range(0, len(samples), frame_size):
        chunk = samples[start : start + frame_size].astype(np.float32)
        frame = av.AudioFrame.from_ndarray(
            chunk.reshape(1, -1), format=str(stream.format.name), layout="mono"
        )
        frame.sample_rate = sample_rate
        frame.pts = pts
        pts += chunk.shape[0]
        for packet in stream.encode(frame):
            container.mux(packet)
    for packet in stream.encode():  # flush
        container.mux(packet)
    container.close()


class TestLoad:
    def test_mono_8khz_sine_resamples_to_16khz(self, tmp_path: Path) -> None:
        wav_path = tmp_path / "mono.wav"
        _write_wav(wav_path, 8000, [_sine(440.0, 1.0, 8000, amplitude=0.5)])

        samples = AudioFileLoader().load(wav_path)

        assert samples.dtype == np.float32
        assert samples.ndim == 1
        assert abs(len(samples) - TARGET_SAMPLE_RATE) <= TARGET_SAMPLE_RATE * 0.01
        assert np.max(np.abs(samples)) == pytest.approx(0.5, abs=0.05)

    def test_stereo_antiphase_constant_downmixes_toward_silence(self, tmp_path: Path) -> None:
        # L=+0.4, R=-0.4: a "take the first channel" reader would report
        # +0.4 throughout; averaging cancels the two toward zero.
        wav_path = tmp_path / "antiphase.wav"
        left = _constant(0.4, 0.5, 44100)
        right = _constant(-0.4, 0.5, 44100)
        _write_wav(wav_path, 44100, [left, right])

        samples = AudioFileLoader().load(wav_path)

        assert np.mean(np.abs(samples)) < 0.02

    def test_stereo_sine_on_left_silence_on_right_halves_amplitude(self, tmp_path: Path) -> None:
        # Proves averaging rather than "always take the first channel": a
        # first-channel-only reader would report peak ~0.4, not ~0.2.
        wav_path = tmp_path / "left_only.wav"
        left = _sine(440.0, 0.5, 44100, amplitude=0.4)
        right = _silence(0.5, 44100)
        _write_wav(wav_path, 44100, [left, right])

        samples = AudioFileLoader().load(wav_path)

        assert np.max(np.abs(samples)) == pytest.approx(0.2, abs=0.05)

    def test_stereo_identical_channels_downmix_without_gain_or_clipping(
        self, tmp_path: Path
    ) -> None:
        # L == R at high amplitude: an average-downmix reproduces the same
        # signal at unity gain (peak ~0.9, no clipping). A power-preserving
        # mix (~1/sqrt(2) per channel) would instead push this to ~1.27 and
        # clip, which is the bug this test guards against.
        wav_path = tmp_path / "identical.wav"
        channel = _sine(440.0, 0.5, 44100, amplitude=0.9)
        _write_wav(wav_path, 44100, [channel, channel.copy()])

        samples = AudioFileLoader().load(wav_path)

        assert np.max(np.abs(samples)) == pytest.approx(0.9, abs=0.05)

    def test_uppercase_extension_is_accepted(self, tmp_path: Path) -> None:
        wav_path = tmp_path / "shout.WAV"
        _write_wav(wav_path, 8000, [_sine(440.0, 0.2, 8000, amplitude=0.5)])

        samples = AudioFileLoader().load(wav_path)

        assert samples.size > 0

    def test_unsupported_extension_rejected_before_open(self, tmp_path: Path) -> None:
        # Content is garbage, not real audio. If the loader opened the file
        # before checking its extension, this would fail as Unreadable or
        # AudioConversionFailed instead of UnsupportedFormat.
        txt_path = tmp_path / "notes.txt"
        txt_path.write_bytes(b"\x00\xff not audio data at all \x01\x02")

        with pytest.raises(AudioFileUnsupportedFormat):
            AudioFileLoader().load(txt_path)

    def test_missing_file_is_unreadable(self, tmp_path: Path) -> None:
        missing = tmp_path / "does-not-exist.wav"

        with pytest.raises(AudioFileUnreadable):
            AudioFileLoader().load(missing)

    def test_zero_frame_wav_is_empty(self, tmp_path: Path) -> None:
        wav_path = tmp_path / "empty.wav"
        _write_wav(wav_path, 16000, [np.array([], dtype=np.float32)])

        with pytest.raises(AudioFileEmpty):
            AudioFileLoader().load(wav_path)

    def test_garbage_bytes_with_wav_extension_is_an_audio_file_error(self, tmp_path: Path) -> None:
        # Observed behavior: PyAV can't find a valid audio stream in the
        # garbage bytes, which the loader surfaces as AudioFileUnreadable
        # (the same path as "couldn't open the file at all"). Asserting the
        # AudioFileError base class keeps this test from being brittle if
        # a future FFmpeg version instead fails during decode
        # (AudioConversionFailed) for this input.
        wav_path = tmp_path / "garbage.wav"
        wav_path.write_bytes(bytes(range(256)) * 4)

        with pytest.raises(AudioFileError) as exc_info:
            AudioFileLoader().load(wav_path)
        assert isinstance(exc_info.value, (AudioFileUnreadable, AudioConversionFailed))


class TestDuration:
    def test_duration_of_one_second_clip(self, tmp_path: Path) -> None:
        wav_path = tmp_path / "one_second.wav"
        _write_wav(wav_path, 8000, [_sine(440.0, 1.0, 8000, amplitude=0.5)])

        duration = AudioFileLoader().duration(wav_path)

        assert duration == pytest.approx(1.0, abs=0.05)

    def test_falls_back_to_container_duration_when_stream_duration_is_none(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wav_path = tmp_path / "one_second.wav"
        _write_wav(wav_path, 8000, [_sine(440.0, 1.0, 8000, amplitude=0.5)])
        # Class-level patch: PyAV's Stream/Container are Cython extension
        # types whose `duration` is a read-only property, so an instance
        # attribute can't be overridden — only the class property can.
        monkeypatch.setattr(av.audio.stream.AudioStream, "duration", property(lambda self: None))

        duration = AudioFileLoader().duration(wav_path)

        assert duration == pytest.approx(1.0, abs=0.05)

    def test_falls_back_to_decode_count_when_no_duration_metadata_at_all(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wav_path = tmp_path / "one_second.wav"
        _write_wav(wav_path, 8000, [_sine(440.0, 1.0, 8000, amplitude=0.5)])
        monkeypatch.setattr(av.audio.stream.AudioStream, "duration", property(lambda self: None))
        monkeypatch.setattr(
            av.container.input.InputContainer, "duration", property(lambda self: None)
        )

        duration = AudioFileLoader().duration(wav_path)

        assert duration == pytest.approx(1.0, abs=0.05)


class TestM4ARoundTrip:
    def test_m4a_encoded_sine_loads_within_tolerance(self, tmp_path: Path) -> None:
        sample_rate = 44100
        sine = _sine(440.0, 1.0, sample_rate, amplitude=0.5)
        # Fade the first/last 20ms so the sharp sine<->silence discontinuity
        # doesn't trigger AAC's pre-echo/ringing artifact, which otherwise
        # transiently overshoots the source amplitude right at the edges.
        fade_samples = int(0.02 * sample_rate)
        fade = np.linspace(0.0, 1.0, fade_samples, dtype=np.float32)
        sine[:fade_samples] *= fade
        sine[-fade_samples:] *= fade[::-1]

        m4a_path = tmp_path / "source.m4a"
        try:
            _encode_aac_m4a(m4a_path, sine, sample_rate)
        except Exception as exc:  # noqa: BLE001 - report exact error if aac is unavailable
            pytest.skip(f"PyAV's bundled ffmpeg cannot encode AAC: {exc}")

        samples = AudioFileLoader().load(m4a_path)

        # AAC encoders pad the stream with codec priming/delay samples (a
        # fixed number of frames at the encoder's own frame size), so the
        # decoded length isn't exactly 1.0s * TARGET_SAMPLE_RATE — measured
        # ~16347 samples (~1.02s) for a 1.0s source with this encoder.
        assert TARGET_SAMPLE_RATE * 0.98 <= len(samples) <= TARGET_SAMPLE_RATE * 1.12
        assert np.max(np.abs(samples)) == pytest.approx(0.5, abs=0.15)
