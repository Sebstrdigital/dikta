# KB-Whisper self-conversion

Converts [`KBLab/kb-whisper-small`](https://huggingface.co/KBLab/kb-whisper-small)
(PyTorch, Hugging Face `transformers` format) to the WhisperKit CoreML layout
using Argmax's [`whisperkittools`](https://github.com/argmaxinc/whisperkittools),
so it can be benchmarked and eventually shipped without depending on a
third-party community conversion (`Leonidng/whisperkit-kb-whisper-small`).

This directory is **conversion tooling only** — it does not touch the Swift
app. Output lands in `../models/KBLab_kb-whisper-small/` (gitignored), loaded
by `DiktaBench --model-folder` for benchmarking.

## Why a separate venv

`whisperkittools` pulls in `torch==2.5.0`, `transformers==4.53`, and
`coremltools>=8.1` — multiple GB of heavy ML dependencies with pinned
versions that would conflict with the lightweight `bench/.venv` used for
`fetch_clips.py`/`score.py` (`jiwer`, `datasets`, `huggingface_hub`). Keep
them isolated: this venv lives at `bench/convert/.venv/`, gitignored, and is
never activated for the scoring pipeline.

## Requirements

- **Python 3.11.** `whisperkittools`'s `setup.py` declares support for
  3.9–3.12, but its own install docs (and CI) use 3.11 — that's what this
  script pins. On this machine: `/opt/homebrew/bin/python3.11` (Homebrew).
- **Xcode with `coremlcompiler` on PATH** — verify with
  `xcrun -f coremlcompiler`. Conversion compiles `.mlpackage` → `.mlmodelc`
  via `xcrun coremlcompiler`, which requires a full Xcode install (not just
  Command Line Tools). Confirmed present: Xcode 27.0 (build 27A266a).
- ~10GB free disk (PyTorch + source checkpoint + intermediate CoreML
  artifacts; final output folder is much smaller, see conversion doc).
- No Hugging Face auth needed — `KBLab/kb-whisper-small` is a public repo and
  this script never uploads (`whisperkit-generate-model` only uploads when
  passed `--upload-results`, which `convert.sh` deliberately omits).

## What `convert.sh` does

1. Creates `bench/convert/.venv/` with `/opt/homebrew/bin/python3.11` (skips
   if it already exists — pass `--clean` to rebuild from scratch).
2. Clones `argmaxinc/whisperkittools` into `bench/convert/whisperkittools/`
   (gitignored) and checks out the pinned commit in `PINNED_COMMIT` at the
   top of the script — `whisperkittools` has no version tags, so a commit
   hash is the only reproducible pin. Recorded conversion used commit
   `84f77a83c8f530022ae55fbb1a64b3351ef63c7a` (2026-09-16, `main`).
3. `pip install -e .` into that venv.
4. Downloads a **pinned, local** snapshot of the source model —
   `huggingface_hub.snapshot_download(repo_id='KBLab/kb-whisper-small',
   revision=MODEL_REVISION, local_dir='src/KBLab_kb-whisper-small',
   allow_patterns=['config.json', 'generation_config.json',
   'model.safetensors'])` — into `bench/convert/src/` (gitignored).
   `whisperkit-generate-model` itself has no `--revision` flag (a bare hub
   id always resolves to `main`), so this is the only way to pin the exact
   source revision. `MODEL_REVISION` at the top of the script records
   `3564d61a42fc210ceaa55a22a96dd64478959c78`. Restricted to the 3 files
   conversion actually needs — the repo also ships ONNX/GGML variants and
   tokenizer files this never touches.
5. Runs, with `cwd` inside `src/` and the bare local directory name (no
   `/`) as `--model-version`:
   ```
   whisperkit-generate-model \
       --model-version KBLab_kb-whisper-small \
       --output-dir ../../models
   ```
   `generate_model.py`'s `--model-version` docstring explicitly supports
   "a local directory containing the model files"
   (`scripts/generate_model.py:35-41`). It writes
   `../models/KBLab_kb-whisper-small/` (relative to `bench/convert/`) — the
   folder-naming convention is `whisperkittools`'s own
   (`args.output_dir + model_version.replace("/", "_")`); passing a bare
   name with no slashes survives that `.replace()` unchanged, so the output
   folder is exactly `KBLab_kb-whisper-small` with no renaming needed
   afterwards. No flags for quantization or decoder context prefill are
   passed — this reproduces a plain, unquantized conversion comparable to
   the community one, and it means conversion never touches the network for
   model files (everything needed is already in the local snapshot from
   step 4), closing off the transient-download failure mode described in
   the conversion doc.
6. Greps the conversion log for `^(FAILED|ERROR)[: ]`, `errors=[1-9]`, or
   `failures=[1-9]`. `whisperkit-generate-model` doesn't check its own test
   suites' results and exits 0 even when a suite errored out entirely
   (confirmed 2026-09-16 — see the conversion doc's "What happened"
   section) — its exit code alone is not a reliable success signal. The
   pattern matches both unittest's own failure reporting (`ERROR:
   setUpClass (...)`, `FAILED (errors=1)`) and `argmaxtools`'s
   `logging`-module output (`ERROR:argmaxtools.module:message`, colon with
   no space) — see the conversion doc for a demonstration against synthetic
   lines of each shape.
7. Copies `config.json` and `generation_config.json` from the **same**
   pinned local snapshot used for conversion (step 4) into the output
   folder, verbatim, no edits — one revision, one download, no drift
   between what got converted and what got copied in. `whisperkit-generate-model`
   only does this copy inside `upload_version()`, gated on
   `--upload-results`, which this script never passes — so without this
   step the folder would be missing these two files. WhisperKit 1.1.0
   doesn't currently parse either file for local `--model-folder` loading
   (`Sources/WhisperKit/Core/Models.swift:52`, `TODO: implement config.json
   and generation_config.json parsing for models`), but they're part of the
   documented model catalogue layout
   (`docs/review-2026-09/whisperkit-drift.md`) and needed for eventual HF
   upload, so the folder is kept complete rather than minimal.
8. Deletes `*.mlcomputeplan.json` — `argmaxtools` test-profiling byproducts
   (per-op ANE dispatch cost breakdowns), not part of the model catalogue
   layout and never read by WhisperKit's Swift source.

`--clean` wipes `.venv/`, `whisperkittools/`, and `src/` so the next run
starts completely fresh.

Run it:

```
cd dikta-macos/bench/convert
./convert.sh
```

Wall-clock time, output size, and any converter warnings are recorded in
`docs/review-2026-09/kb-whisper-conversion-2026-09-16.md`.

## Benchmarking the converted model

`DiktaBench` gained a `--model-folder <path>` flag (bypasses the
`--repo`/`--variant` Hugging Face download path, loads a local WhisperKit
model folder directly via `WhisperKitConfig.modelFolder`). **Not fully
offline**: the converted folder has no tokenizer files, so WhisperKit still
falls back to downloading a tokenizer from Hugging Face
(`argmaxinc/whisperkit-coreml`) on first use if one isn't already cached —
see the conversion doc's "Tokenizer / offline limitation" section. This
wasn't wired into `run.sh` (its interface is repo/variant pairs, not local
paths) — run it directly instead:

```
cd dikta-macos
swift build --product DiktaBench

cd bench
source .venv/bin/activate   # the LIGHT bench venv (jiwer/datasets), not convert/.venv
python3 fetch_clips.py       # if data/ isn't already populated

MODEL_DIR=../bench/models/KBLab_kb-whisper-small
swift run --package-path .. DiktaBench \
    --model-folder "$MODEL_DIR" --language sv \
    --audio-dir data/sv --out results/raw-KBLab_kb-whisper-small-selfconv-sv.jsonl
swift run --package-path .. DiktaBench \
    --model-folder "$MODEL_DIR" --language en \
    --audio-dir data/en --out results/raw-KBLab_kb-whisper-small-selfconv-en.jsonl

python3 score.py score --results results/raw-KBLab_kb-whisper-small-selfconv-sv.jsonl \
    --refs data/sv/refs.jsonl --model KBLab_kb-whisper-small-selfconv --lang sv
python3 score.py score --results results/raw-KBLab_kb-whisper-small-selfconv-en.jsonl \
    --refs data/en/refs.jsonl --model KBLab_kb-whisper-small-selfconv --lang en

python3 score.py report
```

(Note: `swift run` from `bench/` needs `--package-path ..` since the SPM
package root is `dikta-macos/`, not `dikta-macos/bench/`.)

## Acceptance

Swedish WER must land within 1 percentage point of the community
conversion's 3.50% (`Leonidng/whisperkit-kb-whisper-small`); English should
be near its 54.19% (same underlying weights, so both should be close to
identical). See the results table in
`docs/review-2026-09/kb-whisper-conversion-2026-09-16.md`.

## Not done here

- **No upload to Hugging Face.** `convert.sh` never passes
  `--upload-results`. Publishing the converted model (to replace the
  `Leonidng/*` community dependency) needs the maintainer's HF login and is
  a separate, later step.
- **No app integration.** The app still points at
  `Leonidng/whisperkit-kb-whisper-small` — swapping to a self-hosted repo (or
  bundling the converted model) is out of scope for this conversion.
