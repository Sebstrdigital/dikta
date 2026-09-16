#!/usr/bin/env python3
"""Fetch a fixed, seeded 20-clip sample per language from google/fleurs.

Downloads sv_se and en_us test-split clips via HF `datasets` streaming (so the
whole split is never pulled to disk), writes 16kHz mono WAVs to
bench/data/{sv,en}/NNN.wav, and a bench/data/{sv,en}/refs.jsonl reference file.

Deterministic: fixed seed (42), windowed shuffle, first 20 taken. Idempotent:
skips a language if its refs.jsonl already lists 20 clips that exist on disk.

Licence: FLEURS is CC-BY-4.0 (https://huggingface.co/datasets/google/fleurs).
Downloaded audio lives in bench/data/, which is gitignored.
"""

import json
import sys
from pathlib import Path

from datasets import Audio, load_dataset
import soundfile as sf

SEED = 42
N_CLIPS = 20
SHUFFLE_BUFFER = 1000
SAMPLE_RATE = 16000

LANGS = {
    "sv": "sv_se",
    "en": "en_us",
}

BENCH_DIR = Path(__file__).resolve().parent
DATA_DIR = BENCH_DIR / "data"


def already_fetched(lang_dir: Path) -> bool:
    refs_path = lang_dir / "refs.jsonl"
    if not refs_path.exists():
        return False
    lines = [l for l in refs_path.read_text().splitlines() if l.strip()]
    if len(lines) != N_CLIPS:
        return False
    for line in lines:
        rec = json.loads(line)
        if not (lang_dir / rec["file"]).exists():
            return False
    return True


def fetch_language(lang_code: str, fleurs_config: str) -> None:
    lang_dir = DATA_DIR / lang_code
    lang_dir.mkdir(parents=True, exist_ok=True)

    if already_fetched(lang_dir):
        print(f"[{lang_code}] already have {N_CLIPS} clips, skipping")
        return

    print(f"[{lang_code}] streaming google/fleurs config={fleurs_config} split=test")
    ds = load_dataset("google/fleurs", fleurs_config, split="test", streaming=True)
    ds = ds.cast_column("audio", Audio(sampling_rate=SAMPLE_RATE))
    ds = ds.shuffle(seed=SEED, buffer_size=SHUFFLE_BUFFER)

    refs = []
    taken = 0
    for item in ds:
        if taken >= N_CLIPS:
            break
        audio = item["audio"]
        array = audio["array"]
        reference = item.get("raw_transcription") or item.get("transcription") or ""
        if not reference.strip():
            continue  # skip clips with no reference text

        file_name = f"{taken + 1:03d}.wav"
        out_path = lang_dir / file_name
        sf.write(str(out_path), array, SAMPLE_RATE, subtype="PCM_16")
        refs.append({"file": file_name, "reference": reference})
        taken += 1

    if taken < N_CLIPS:
        print(f"[{lang_code}] WARNING: only found {taken}/{N_CLIPS} usable clips", file=sys.stderr)

    refs_path = lang_dir / "refs.jsonl"
    with refs_path.open("w") as f:
        for rec in refs:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    print(f"[{lang_code}] wrote {taken} clips to {lang_dir}")


def main() -> None:
    for lang_code, fleurs_config in LANGS.items():
        fetch_language(lang_code, fleurs_config)


if __name__ == "__main__":
    main()
