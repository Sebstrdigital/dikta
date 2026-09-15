# DiktaBench

STT benchmark harness for Dikta. sv + en WER, RTF, load time. Repeatable.

## What's here

- `../Bench/main.swift` — SPM executable `DiktaBench`. Loads a WhisperKit model
  by raw repo/variant string, transcribes every clip in a dir, writes
  `{file, text, seconds_audio, seconds_wall, model_load_seconds}` JSON lines.
- `fetch_clips.py` — pulls a fixed seeded 20-clip sample per language from
  `google/fleurs` (sv_se, en_us, test split) via HF streaming. Idempotent.
- `score.py` — normalises text (lowercase, strip punctuation, collapse
  whitespace, NFC, keeps åäö), computes aggregate WER with `jiwer`, prints a
  table, writes a timestamped summary JSON per run.
- `run.sh` — runs the whole pipeline: fetch -> transcribe -> score -> report.

## Run it

```
cd dikta-macos/bench
./run.sh
```

No args = default pair (`openai_whisper-small` on both languages). Or pass
your own repo/variant pairs:

```
./run.sh argmaxinc/whisperkit-coreml openai_whisper-small \
         argmaxinc/whisperkit-coreml openai_whisper-large-v3-v20240930_turbo_632MB
```

First run: creates a venv in `.venv/` (gitignored), installs deps, downloads
20 sv + 20 en clips into `data/` (gitignored), builds `DiktaBench`, downloads
the WhisperKit model itself (~500MB+, cached by WhisperKit after first pull).

## Where results land

- Raw per-clip transcripts: `results/raw-<variant>-<lang>.jsonl` (gitignored).
- Scored summary per run: `results/<timestamp>-<variant>-<lang>.json`
  (gitignored — regenerate, don't commit).
- Final table printed to stdout at the end of `run.sh`. Re-print anytime with
  `python3 score.py report` (reads every summary in `results/`).

Table columns: model | lang | WER (aggregate, punctuation-stripped) | median
RTF (`seconds_wall / seconds_audio`) | model load seconds.

## Run just one piece

```
source .venv/bin/activate
python3 fetch_clips.py                 # clips only
swift run DiktaBench --repo argmaxinc/whisperkit-coreml \
    --variant openai_whisper-small --language sv \
    --audio-dir data/sv --out results/raw-small-sv.jsonl
python3 score.py score --results results/raw-small-sv.jsonl \
    --refs data/sv/refs.jsonl --model openai_whisper-small --lang sv
python3 score.py report
```

## Licence

FLEURS is CC-BY-4.0 (https://huggingface.co/datasets/google/fleurs). Clips
and refs live in `data/`, gitignored — re-fetch with `fetch_clips.py`, don't
commit audio.

## Notes

- `DiktaBench` is a separate SPM executable target, not linked against the
  `Dikta` app target (SPM won't let one executable depend on another). It
  takes model identity as raw `--repo`/`--variant` strings, not the
  `WhisperModel` enum, so it doesn't collide with in-progress changes to that
  enum.
- Transcript text from `DiktaBench` is raw (segments trimmed and joined, no
  control-token stripping in Swift). `score.py`'s normaliser strips Whisper
  control tokens (`<|startoftranscript|>`, `<|en|>`, `<|0.00|>`, `<|endoftext|>`,
  ...) before WER — without this, WER inflates massively (measured: sv small
  74% -> 24%, en small 58% -> 10%) because the tokens get counted as literal
  words. Normalisation runs once, identically, on both reference and
  hypothesis, so the comparison stays honest.
- WER is aggregate (total edit distance over total reference words across the
  whole set), not mean-of-per-file. Matches
  `docs/review-2026-09/stt-landscape-2026-09.md`.
