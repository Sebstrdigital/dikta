"""Tests for the `dikta` CLI (`dikta.cli`)."""

from __future__ import annotations

import json
import wave
from pathlib import Path

import numpy as np
import pytest

from dikta.cli import _parse_candidate_languages, main

_TRANSCRIPT = "we agreed to ship on friday and I will send the invoice"


def _write_wav(path: Path, seconds: float = 1.0, sample_rate: int = 16_000) -> None:
    n = int(seconds * sample_rate)
    pcm = np.zeros(n, dtype=np.int16)
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm.tobytes())


def test_debrief_in_process_prints_rendered_summary_and_exits_zero(tmp_path, capsys):
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    exit_code = main(
        [
            "debrief",
            str(wav_path),
            "--fake-stt-text",
            _TRANSCRIPT,
            "--engine",
            "heuristic",
            "--root",
            str(tmp_path / "store"),
            "--in-process",
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 0
    assert "MEETING DEBRIEF" in captured.out


def test_debrief_via_worker_subprocess_prints_rendered_summary(tmp_path, capsys):
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    exit_code = main(
        [
            "debrief",
            str(wav_path),
            "--fake-stt-text",
            _TRANSCRIPT,
            "--engine",
            "heuristic",
            "--root",
            str(tmp_path / "store"),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 0
    assert "MEETING DEBRIEF" in captured.out


def test_debrief_json_output_parses(tmp_path, capsys):
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    exit_code = main(
        [
            "debrief",
            str(wav_path),
            "--fake-stt-text",
            _TRANSCRIPT,
            "--engine",
            "heuristic",
            "--root",
            str(tmp_path / "store"),
            "--in-process",
            "--json",
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 0
    payload = json.loads(captured.out)
    assert payload["event"] == "result"
    assert "rendered_text" in payload


def test_debrief_missing_file_exits_2(tmp_path):
    exit_code = main(["debrief", str(tmp_path / "missing.wav")])

    assert exit_code == 2


@pytest.mark.parametrize("language", ["sv", "en", "id", "swe"])
def test_debrief_accepts_any_iso_639_shaped_language_code(tmp_path, capsys, language):
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    exit_code = main(
        [
            "debrief",
            str(wav_path),
            "--language",
            language,
            "--fake-stt-text",
            _TRANSCRIPT,
            "--engine",
            "heuristic",
            "--root",
            str(tmp_path / "store"),
            "--in-process",
        ]
    )

    assert exit_code == 0


@pytest.mark.parametrize("language", ["", "e", "english", "sv1", "SV", "sv-SE"])
def test_debrief_rejects_malformed_language_code_exits_2(tmp_path, language):
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    exit_code = main(["debrief", str(wav_path), "--language", language])

    assert exit_code == 2


def test_gui_dispatches_to_app_main(monkeypatch):
    """`dikta gui` must call `dikta.app.main.main([])` -- and nothing else, so this test never
    actually starts Qt.
    """
    calls: list[list[str]] = []

    def _fake_gui_main(argv: list[str]) -> int:
        calls.append(argv)
        return 0

    monkeypatch.setattr("dikta.app.main.main", _fake_gui_main)

    exit_code = main(["gui"])

    assert exit_code == 0
    assert calls == [[]]


def test_debrief_unsupported_extension_exits_2(tmp_path):
    txt_path = tmp_path / "notes.txt"
    txt_path.write_text("hello")

    exit_code = main(["debrief", str(txt_path)])

    assert exit_code == 2


# -- --candidates parsing --------------------------------------------------------


def test_parse_candidate_languages_all_returns_none():
    assert _parse_candidate_languages("all") is None


def test_parse_candidate_languages_comma_separated_returns_list():
    assert _parse_candidate_languages("en,sv") == ["en", "sv"]


def test_parse_candidate_languages_rejects_invalid_code():
    with pytest.raises(ValueError):
        _parse_candidate_languages("en,SV")


def test_debrief_defaults_to_en_sv_candidates(tmp_path, capsys):
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    exit_code = main(
        [
            "debrief",
            str(wav_path),
            "--fake-stt-text",
            _TRANSCRIPT,
            "--engine",
            "heuristic",
            "--root",
            str(tmp_path / "store"),
            "--in-process",
        ]
    )

    assert exit_code == 0


def test_debrief_accepts_candidates_all(tmp_path, capsys):
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    exit_code = main(
        [
            "debrief",
            str(wav_path),
            "--candidates",
            "all",
            "--fake-stt-text",
            _TRANSCRIPT,
            "--engine",
            "heuristic",
            "--root",
            str(tmp_path / "store"),
            "--in-process",
        ]
    )

    assert exit_code == 0


def test_debrief_accepts_offline_flag(tmp_path, capsys):
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    exit_code = main(
        [
            "debrief",
            str(wav_path),
            "--offline",
            "--fake-stt-text",
            _TRANSCRIPT,
            "--engine",
            "heuristic",
            "--root",
            str(tmp_path / "store"),
            "--in-process",
        ]
    )

    assert exit_code == 0


def test_debrief_rejects_invalid_candidates_code_exits_2(tmp_path):
    wav_path = tmp_path / "input.wav"
    _write_wav(wav_path)

    exit_code = main(
        [
            "debrief",
            str(wav_path),
            "--candidates",
            "en,SV",
            "--fake-stt-text",
            _TRANSCRIPT,
            "--engine",
            "heuristic",
            "--root",
            str(tmp_path / "store"),
            "--in-process",
        ]
    )

    assert exit_code == 2
