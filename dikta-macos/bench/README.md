# DiktaBench

STT benchmark harness for Dikta. sv + en WER, RTF, load time. Repeatable.

## What's here

- `DiktaBench/main.swift` — SPM executable `DiktaBench`. `--engine whisper`
  (default) loads a WhisperKit model by raw repo/variant string; `--engine
  apple` drives Apple's on-device `DictationTranscriber` (Speech framework,
  macOS 26+) instead, ignoring `--repo`/`--variant`. Either way it transcribes
  every clip in a dir and writes
  `{file, text, seconds_audio, seconds_wall, model_load_seconds}` JSON lines.
- `fetch_clips.py` — pulls a fixed seeded 20-clip sample per language from
  `google/fleurs` (sv_se, en_us, test split) via HF streaming. Idempotent.
- `score.py` — normalises text (lowercase, strip punctuation, collapse
  whitespace, NFC, keeps åäö), computes aggregate WER with `jiwer`, prints a
  table, writes a timestamped summary JSON per run. Also has a `digits`
  subcommand for engines that apply inverse text normalization (see below).
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

The literal pair `apple apple` selects the Apple Dictation engine instead of a
WhisperKit repo/variant (macOS 26+ only):

```
./run.sh apple apple
```

It's scored and labelled as model `apple-dictation`, and can be combined with
WhisperKit pairs in the same invocation (`./run.sh apple apple argmaxinc/whisperkit-coreml openai_whisper-small`).

First run: creates a venv in `.venv/` (gitignored), installs deps, downloads
20 sv + 20 en clips into `data/` (gitignored), builds `DiktaBench`, downloads
the WhisperKit model itself (~500MB+, cached by WhisperKit after first pull).
The Apple engine instead does a one-time asset check/install per language via
`AssetInventory` (timed as `model_load_seconds`), no separate download step.

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

# Apple engine, one language:
swift run DiktaBench --engine apple --language sv \
    --audio-dir data/sv --out results/raw-apple-dictation-sv.jsonl
python3 score.py score --results results/raw-apple-dictation-sv.jsonl \
    --refs data/sv/refs.jsonl --model apple-dictation --lang sv

# Digit-count / ITN check (any engine, but written for Apple's ITN behaviour —
# see docs/review-2026-09/apple-dictation-engine-spec.md §5): reports how many
# clips have digits in the reference vs. the hypothesis, and WER restricted to
# clips whose reference has no digits.
python3 score.py digits --results results/raw-apple-dictation-sv.jsonl \
    --refs data/sv/refs.jsonl --model apple-dictation --lang sv
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
- Apple engine: builds a **fresh** `DictationTranscriber` + `SpeechAnalyzer`
  per clip (reusing one across clips has been observed to silently return
  `""` on the second call — see
  `Dikta/Services/AppleDictationEngine.swift` and
  `docs/review-2026-09/apple-dictation-engine-spec.md` §6), and applies
  inverse text normalization unconditionally (numbers/dates/currency come out
  as digits, punctuation included) — there's no toggle for it (spec §5). This
  means aggregate WER against FLEURS references (which spell numbers out) is
  not a fair like-for-like with WhisperKit; use `score.py digits` to separate
  genuine transcription errors from ITN-vs-spelled-out mismatches.
