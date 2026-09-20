"""Tests for `DebriefStore`, ported from `DiktaTests/DebriefStoreTests.swift`.

Not ported: `testAudioURLForTrackUsesMeAndThemFilenames`,
`testHasTrackIsFalseBeforeTheTrackFileExists`,
`testMakeStreamingWriterCreatesFileImmediatelyButHasTrackStaysFalseUntilFramesAreFlushed`,
and `testMakeStreamingWriterForBothTracksRoundTripsIndependently`. Those
cover the two-track (`me.wav`/`them.wav`) live-capture streaming API
(`DebriefTrack`, `audioURL(for:)`, `hasTrack`, `makeStreamingWriter`),
which is out of scope for the file-import `DebriefStore` port and has no
Python counterpart here.
"""

from __future__ import annotations

import wave
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import pytest

from dikta.core.debrief.store import DebriefStore, SessionPaths, default_root
from dikta.engines.audio.loader import AudioFileLoader

_FIXED_DATE = datetime(2026, 9, 17, 14, 30, 5)


def _fixed_clock() -> datetime:
    return _FIXED_DATE


def _make_store(tmp_path: Path) -> DebriefStore:
    return DebriefStore(root=tmp_path, clock=_fixed_clock)


def _sine_samples(
    count: int, amplitude: float, frequency: float = 440.0, sample_rate: float = 16000.0
) -> np.ndarray:
    t = np.arange(count) / sample_rate
    return (amplitude * np.sin(2.0 * np.pi * frequency * t)).astype(np.float32)


class TestCreateSession:
    def test_create_session_uses_expected_folder_name_pattern(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)

        paths = store.create_session(date=_FIXED_DATE)

        assert paths.folder.name == "2026-09-17_14-30-05"
        assert paths.folder.exists()

    def test_create_session_appends_suffix_on_collision(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)

        first = store.create_session(date=_FIXED_DATE)
        second = store.create_session(date=_FIXED_DATE)
        third = store.create_session(date=_FIXED_DATE)

        assert first.folder.name == "2026-09-17_14-30-05"
        assert second.folder.name == "2026-09-17_14-30-05-2"
        assert third.folder.name == "2026-09-17_14-30-05-3"

    def test_create_session_converts_timezone_aware_date_to_local(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)
        aware = datetime(2026, 9, 17, 14, 30, 5, tzinfo=UTC)
        expected_name = aware.astimezone().strftime("%Y-%m-%d_%H-%M-%S")

        paths = store.create_session(date=aware)

        assert paths.folder.name == expected_name

    def test_create_session_uses_injected_clock_when_date_omitted(self, tmp_path: Path) -> None:
        calls: list[None] = []

        def clock() -> datetime:
            calls.append(None)
            return datetime(2030, 1, 2, 3, 4, 5)

        store = DebriefStore(root=tmp_path, clock=clock)

        paths = store.create_session()

        assert paths.folder.name == "2030-01-02_03-04-05"
        assert calls == [None]


class TestWriteAudio:
    def test_write_audio_produces_wav_with_matching_sample_count(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)
        paths = store.create_session()
        samples = _sine_samples(16000, amplitude=0.5)

        store.write_audio(samples, paths)
        loaded = AudioFileLoader().load(paths.audio)

        assert len(loaded) == len(samples)

    def test_write_audio_round_trips_samples_within_int16_tolerance(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)
        paths = store.create_session()
        samples = _sine_samples(16000, amplitude=0.5)

        store.write_audio(samples, paths)
        loaded = AudioFileLoader().load(paths.audio)

        tolerance = 1.0 / 32768 * 2
        assert len(loaded) == len(samples)
        assert np.max(np.abs(loaded - samples)) <= tolerance

    def test_write_audio_wav_format_and_clamping(self, tmp_path: Path) -> None:
        """Extra: asserts the literal WAV header/frames `write_audio` produces,
        and that out-of-range samples clamp to Int16.max (32767) rather than
        wrapping or hitting the full negative range (-32768)."""
        store = _make_store(tmp_path)
        paths = store.create_session()
        known = np.array([0.0, 0.5, -0.5, 1.0, -1.0], dtype=np.float32)
        # 0.5 * 32767 = 16383.5, rounds away from zero to +-16384; 1.0/-1.0
        # scale exactly to +-32767 (Int16.max, not the full negative range).
        expected = np.array([0, 16384, -16384, 32767, -32767], dtype=np.int64)

        store.write_audio(known, paths)

        with wave.open(str(paths.audio), "rb") as wav_file:
            assert wav_file.getframerate() == 16000
            assert wav_file.getnchannels() == 1
            assert wav_file.getsampwidth() == 2
            assert wav_file.getnframes() == len(known)
            frames = wav_file.readframes(wav_file.getnframes())
        pcm = np.frombuffer(frames, dtype="<i2")
        assert pcm.astype(np.int64).tolist() == expected.tolist()

        clamp_samples = np.array([1.5, -1.5], dtype=np.float32)
        store.write_audio(clamp_samples, paths)
        with wave.open(str(paths.audio), "rb") as wav_file:
            frames = wav_file.readframes(wav_file.getnframes())
        clamped_pcm = np.frombuffer(frames, dtype="<i2")
        # Both clamp to the Int16.max-scaled range: +1.5 clamps to +1.0 ->
        # 32767, -1.5 clamps to -1.0 -> -32767 (not the full-range -32768),
        # matching the Swift original's `clamped * Float(Int16.max)`.
        assert clamped_pcm.tolist() == [32767, -32767]

    def test_write_audio_accepts_column_shape(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)
        paths = store.create_session()
        samples = _sine_samples(4000, amplitude=0.5).reshape(-1, 1)

        store.write_audio(samples, paths)
        loaded = AudioFileLoader().load(paths.audio)

        assert len(loaded) == samples.shape[0]

    def test_write_audio_rejects_invalid_shape(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)
        paths = store.create_session()
        samples = np.zeros((2, 3), dtype=np.float32)

        with pytest.raises(ValueError):
            store.write_audio(samples, paths)

    def test_write_audio_rejects_nan(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)
        paths = store.create_session()
        samples = np.array([0.0, np.nan, 0.5], dtype=np.float32)

        with pytest.raises(ValueError):
            store.write_audio(samples, paths)


class TestSessionPathsOriginalFor:
    def test_original_for_preserves_lowercased_extension(self, tmp_path: Path) -> None:
        paths = SessionPaths(folder=tmp_path)

        assert paths.original_for(Path("import.M4A")) == tmp_path / "original.m4a"

    def test_original_for_with_no_extension_has_no_dot(self, tmp_path: Path) -> None:
        paths = SessionPaths(folder=tmp_path)

        assert paths.original_for(Path("import")) == tmp_path / "original"


class TestCopyOriginalAudio:
    def test_copy_original_audio_preserves_extension(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)
        paths = store.create_session()
        source = tmp_path / "import.m4a"
        source.write_bytes(bytes([0x00, 0x01, 0x02, 0x03]))

        destination = store.copy_original(source, paths)

        expected = paths.folder / "original.m4a"
        assert destination == expected
        assert expected.exists()
        assert expected.read_bytes() == source.read_bytes()

    def test_copy_original_audio_replaces_pre_existing_destination(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)
        paths = store.create_session()
        destination = paths.folder / "original.m4a"
        destination.write_bytes(bytes([0xFF, 0xFF]))
        source = tmp_path / "import.m4a"
        source.write_bytes(bytes([0x00, 0x01, 0x02, 0x03]))

        result = store.copy_original(source, paths)

        assert result == destination
        assert destination.read_bytes() == source.read_bytes()

    def test_copy_original_audio_source_already_at_destination_is_noop(
        self, tmp_path: Path
    ) -> None:
        store = _make_store(tmp_path)
        paths = store.create_session()
        destination = paths.folder / "original.m4a"
        content = bytes([0x01, 0x02, 0x03])
        destination.write_bytes(content)

        result = store.copy_original(destination, paths)

        assert result == destination
        assert destination.read_bytes() == content


class TestWriteTranscriptAndSummary:
    def test_write_transcript_round_trips_utf8_including_swedish(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)
        paths = store.create_session()
        text = "Mötet handlade om åäö och budgeten för kvartalet."

        store.write_transcript(text, paths)

        assert paths.transcript.read_text(encoding="utf-8") == text

    def test_write_summary_round_trips_utf8_including_swedish(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)
        paths = store.create_session()
        text = "Sammanfattning: vi enades om att fördubbla resurserna i höst."

        store.write_summary(text, paths)

        assert paths.summary.read_text(encoding="utf-8") == text

    def test_atomic_write_leaves_no_temp_file(self, tmp_path: Path) -> None:
        store = _make_store(tmp_path)
        paths = store.create_session()

        store.write_transcript("hej", paths)
        store.write_summary("hej", paths)

        remaining = sorted(p.name for p in paths.folder.iterdir())
        assert remaining == ["summary.txt", "transcript.txt"]

    def test_atomic_write_removes_temp_file_on_replace_failure(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        store = _make_store(tmp_path)
        paths = store.create_session()

        def failing_replace(*_args: object, **_kwargs: object) -> None:
            raise OSError("simulated replace failure")

        monkeypatch.setattr("dikta.core.debrief.store.os.replace", failing_replace)

        with pytest.raises(OSError):
            store.write_transcript("hej", paths)

        assert list(paths.folder.iterdir()) == []


class TestDefaultRoot:
    def test_default_root_is_documents_dikta(self) -> None:
        assert default_root() == Path.home() / "Documents" / "Dikta"
