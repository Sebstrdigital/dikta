# KB-Whisper small self-conversion — 2026-09-16

**Status: DONE.** Self-converted `KBLab/kb-whisper-small` to WhisperKit CoreML
format with `whisperkittools`, without uploading anything to Hugging Face.
Benchmarked against FLEURS (sv + en, 20 clips/lang, this Mac) via a new
`DiktaBench --model-folder` flag: **sv 3.50% WER, en 54.19% WER — an exact
match to the community conversion** (`Leonidng/whisperkit-kb-whisper-small`,
see [benchmark-2026-09-15.md](benchmark-2026-09-15.md)). Confirmed twice: once
against a manually-run conversion (superseded), and again against the actual
output of `bench/convert/convert.sh` run end to end as written — see
"Reproducibility" below.

## Correcting the record

An earlier version of this document claimed `KBLab/kb-whisper-small` ships
no `generation_config.json` at all, and that this was the root cause of a
`TextDecoder` conversion crash. **That claim was wrong.** The real
situation, confirmed with evidence below:

- `KBLab/kb-whisper-small`'s Hugging Face repo **does** ship a
  `generation_config.json`, and it **does** have `alignment_heads`
  (confirmed by fetching it directly — see "Evidence" below).
- The first conversion attempt crashed anyway, with:
  ```
  AttributeError: 'GenerationConfig' object has no attribute 'alignment_heads'
  ```
  because the *local Hugging Face cache*, at that point in time, held only
  `config.json` and `model.safetensors` for this repo — `generation_config.json`
  was missing from the cache. `transformers`' `PreTrainedModel.from_pretrained()`
  silently falls back to a synthesized default `GenerationConfig` (built from
  `config.json` alone) when it can't resolve `generation_config.json`, rather
  than raising — so the failure to fetch that one file didn't surface as an
  error at load time, only later when `whisperkittools` tried to read
  `alignment_heads` off the synthesized default, which doesn't have it.
- Why the fetch failed the first time isn't captured in the log (`transformers`
  doesn't log this fallback at a visible level) — most likely a transient
  network hiccup while `torch`, `config.json`, and the ~250MB `model.safetensors`
  were all being pulled in the same `from_pretrained()` call. It was not
  reproducible against the live Hugging Face hub: a second manual run, with
  nothing changed, completed successfully end to end (see "What happened"
  below). `convert.sh` now removes this class of flakiness altogether by
  converting from a local, pre-downloaded, revision-pinned snapshot instead
  of hitting the hub mid-conversion — see "Revision pinning" below.

No workaround was needed. **Not applied**: the option-3 plan discussed
earlier in this task (build a local source directory with a
`generation_config.json` borrowed from `openai/whisper-small`) — verification
before applying it showed KBLab's own file was fine all along, so borrowing
one from `openai/whisper-small` would have been an unnecessary substitution.

### Evidence

Cached snapshot at the time of the first (failed) run —
`~/.cache/huggingface/hub/models--KBLab--kb-whisper-small/snapshots/3564d61a42fc210ceaa55a22a96dd64478959c78/`:
```
config.json
model.safetensors
```
(no `generation_config.json` — this is a **cache** gap, not a repo gap.)

`KBLab/kb-whisper-small`'s actual repo file listing (Hugging Face API,
revision `3564d61a42fc210ceaa55a22a96dd64478959c78`) includes
`generation_config.json` alongside `config.json`, `model.safetensors`, and
tokenizer/ONNX/GGML files it ships for other runtimes.

Fetching `KBLab/kb-whisper-small`'s `generation_config.json` directly:
```json
{
    "alignment_heads": [[5,3],[5,9],[8,0],[8,4],[8,7],[8,8],[9,0],[9,7],[9,9],[10,5]],
    ...
}
```
Present and populated — identical `alignment_heads` values to
`openai/whisper-small` (see diff below).

Loading the model exactly as `whisperkittools` does, directly in the
conversion venv, after the cache issue resolved itself:
```
$ .venv/bin/python -c "
from transformers import WhisperForConditionalGeneration
import torch
m = WhisperForConditionalGeneration.from_pretrained('KBLab/kb-whisper-small', torch_dtype=torch.float32)
gc = m.generation_config
print(hasattr(gc, 'alignment_heads'))
print(getattr(gc, 'alignment_heads', 'MISSING'))
"
True
[[5, 3], [5, 9], [8, 0], [8, 4], [8, 7], [8, 8], [9, 0], [9, 7], [9, 9], [10, 5]]
```

**Cross-check requested by the orchestrator**: diffed the community repo's
(`Leonidng/whisperkit-kb-whisper-small`, revision
`edc5edca19ca8fda3d0986ba89be719bd8bf82f1`, folder `KBLab_kb-whisper-small/`)
`config.json` and `generation_config.json` against KBLab's own real files and
against `openai/whisper-small`'s (revision
`973afd24965f72e36ca33b3055d56a652f456b4d`):

- Community `config.json` vs KBLab's own real `config.json`: **byte-identical**.
- Community `generation_config.json` vs KBLab's own real `generation_config.json`:
  **byte-identical**.
- Community/KBLab `generation_config.json` vs `openai/whisper-small`'s:
  ```
  162a163
  >     "language": "<|sv|>",
  258a260
  >     "task": "transcribe",
  263c265
  <     "transformers_version": "4.31.0.dev0"
  ---
  >     "transformers_version": "4.45.2"
  ```
  Only `language`, `task`, and `transformers_version` differ — expected
  fine-tune metadata and a version string, not `alignment_heads` (identical
  in both) or anything structural. Per the orchestrator's stop condition
  ("if the community generation_config differs from openai/whisper-small's
  in anything other than alignment_heads or cosmetic fields, STOP"): this
  doesn't trigger a stop — the only non-cosmetic-adjacent field
  (`alignment_heads`) is identical, and it's the field that mattered.

The community conversion used KBLab's own real `generation_config.json`
as-is — it did not need to borrow anything from `openai/whisper-small`
either.

## Environment

- Machine: Apple M2 Max, 32GB RAM, macOS 26.6.2, Xcode 27.0 (build 27A266a)
- `argmax-oss-swift` (WhisperKit) pin in `dikta-macos/Package.swift`: **1.1.0**
- Python: `/opt/homebrew/bin/python3.11` (3.11.15)
- `whisperkittools`: no version tags upstream. Pinned to `main` HEAD at
  investigation time: commit `84f77a83c8f530022ae55fbb1a64b3351ef63c7a`
  ("Fix CI (#44)").
- Installed package versions (full list in
  `dikta-macos/bench/convert/requirements.txt`): `torch==2.5.0`,
  `transformers==4.53.0`, `coremltools==9.0`, `numpy==2.3.5`,
  `argmaxtools==0.1.23`.
- Source model revision: `KBLab/kb-whisper-small` sha
  `3564d61a42fc210ceaa55a22a96dd64478959c78` (Hugging Face API,
  `lastModified` 2025-08-27) — **pinned**, see "Revision pinning" below.

## Revision pinning

`whisperkit-generate-model` itself has no `--revision` flag — passing a bare
Hugging Face repo id as `--model-version` always resolves to whatever `main`
currently is. To pin the conversion to one exact, recorded revision,
`convert.sh` downloads a local snapshot first
(`huggingface_hub.snapshot_download(repo_id='KBLab/kb-whisper-small',
revision='3564d61a42fc210ceaa55a22a96dd64478959c78', local_dir='src/KBLab_kb-whisper-small',
allow_patterns=['config.json', 'generation_config.json', 'model.safetensors'])`)
and passes **that local directory** as `--model-version` — `generate_model.py`
(`scripts/generate_model.py:35-41`) explicitly supports a local directory
here (`--model-version` docstring: "1. A Hugging Face model hub name ... 2. A
local directory containing the model files"). `whisperkittools`'s own model
loaders (`WhisperForConditionalGeneration.from_pretrained()` in both
`test_text_decoder.py` and `test_audio_encoder.py`, and the plain
`config.json` read in `test_audio_encoder.py`'s `TestWhisperMelSpectrogram`)
all treat an existing local directory as authoritative and read from disk,
with no network round-trip — so the conversion itself now also can't hit the
same transient-download failure that hit the first attempt.

The `config.json`/`generation_config.json` copied into the final output
folder come from this exact same local snapshot (`cp`, not a second
download) — one revision, one download, no drift between what got converted
and what got copied in alongside it.

`allow_patterns` restricts the snapshot to the 3 files conversion actually
needs. `KBLab/kb-whisper-small`'s repo also ships ONNX/GGML variants and
tokenizer files for other runtimes that this never touches — tokenizer files
are only needed for `whisperkittools`'s optional
`--generate-decoder-context-prefill-data` path (uses
`AutoTokenizer.from_pretrained(TEST_WHISPER_VERSION)` at
`test_text_decoder.py:209`, inside `test_torch_context_prefill`, which isn't
in the default test suite), which `convert.sh` doesn't pass.

One naming detail: the local snapshot directory is named
`KBLab_kb-whisper-small` (no `/`), and `convert.sh` `cd`s into its parent
before invoking `whisperkit-generate-model` so that bare name — with no
slash — is what's passed as `--model-version`. `generate_model.py` names its
output folder `output_dir + model_version.replace("/", "_")`
(`scripts/generate_model.py`, the "Alias the CLI args" block) — passing an
absolute path with slashes would produce an ugly, unpredictable folder name;
a bare relative name survives `.replace("/", "_")` unchanged, giving exactly
`KBLab_kb-whisper-small` with no renaming needed afterwards.

## What was set up

- `dikta-macos/bench/convert/` — isolated Python 3.11 venv
  (`bench/convert/.venv/`, gitignored), `whisperkittools` checkout
  (`bench/convert/whisperkittools/`, gitignored, pinned commit above), a
  pinned local snapshot of the source model
  (`bench/convert/src/KBLab_kb-whisper-small/`, gitignored), `convert.sh`
  (reproduces all of the above end to end: venv, checkout, install,
  snapshot download, convert, failure-detection grep, config file copy,
  byproduct cleanup), `README.md`, `requirements.txt` (pinned dependency
  snapshot).
- `dikta-macos/bench/DiktaBench/main.swift` — added `--model-folder <path>`,
  loading a local WhisperKit model folder directly via
  `WhisperKitConfig.modelFolder` (`argmax-oss-swift/Sources/WhisperKit/Core/WhisperKit.swift:320-321`:
  when `modelFolder` is set, `setupModels` uses it as-is, skipping the
  Hugging Face download path *for the model files* entirely).
  `--repo`/`--variant` behaviour unchanged. See "Tokenizer / offline
  limitation" below — this flag is not fully offline.
- `dikta-macos/.gitignore` — added `bench/models/`,
  `bench/convert/.venv/`, `bench/convert/whisperkittools/`,
  `bench/convert/src/`.

## What happened

### Attempt 1 — transient failure, not a real blocker

Ran the plain HF-hub-id form of the command
(`--model-version KBLab/kb-whisper-small`, before the revision-pinning
change existed). `test_audio_encoder` suite: 3 tests passed. `test_text_decoder`
suite: crashed in `setUpClass` per the `alignment_heads` `AttributeError`
above — 0 tests ran, `TextDecoder.mlmodelc` never got produced.
`whisperkit-generate-model` doesn't check either suite's result and exits 0
regardless — **its exit code is not a reliable success signal**, confirmed
by this run finishing with `[exited with code 0]` despite the crash.

### Attempt 2 — manual re-run, confirmed the hypothesis, superseded

Re-ran the identical bare-hub-id command by hand (not via `convert.sh`, which
didn't have the grep/pinning changes yet) to test whether the failure was
transient. It was: this time `test_text_decoder` passed (`Ran 2 tests ...
OK`, `TextDecoder.mlmodelc` 99.64% ANE dispatch), confirming the "cache was
temporarily missing one file" theory. This run's output was manually
patched (config files copied in, `*.mlcomputeplan.json` deleted by hand) and
benchmarked to check the WER hypothesis quickly — sv 3.50%, en 54.19%. **This
folder and its config-copy step were done manually, not by any version of
`convert.sh`** — a legitimate concern was raised about this not proving
`convert.sh` itself works. That folder was moved aside
(`KBLab_kb-whisper-small-manual`) and, after attempt 3 below succeeded and
was independently re-benchmarked, **deleted**.

### Attempt 3 — `convert.sh`, run end to end as written (authoritative)

With the revision-pinning and failure-grep changes in place, ran
`./convert.sh` from a clean invocation (existing `.venv/`, `whisperkittools/`
checkout, and pip install were reused — they don't change between runs; the
model snapshot download, conversion, config copy, and byproduct cleanup all
executed fresh):

```
$ ./convert.sh
...
Downloading KBLab/kb-whisper-small @ 3564d61a42fc210ceaa55a22a96dd64478959c78 -> src/KBLab_kb-whisper-small/ (pinned snapshot) ...
Fetching 3 files: 100%|██████████| 3/3 [00:01<00:00,  2.36it/s]
  snapshot at .../bench/convert/src/KBLab_kb-whisper-small
Converting src/KBLab_kb-whisper-small -> ../models/KBLab_kb-whisper-small/ ...
(no --upload-results passed: this never touches Hugging Face write access)
...
Ran 3 tests in 104.574s

OK
...
real	2m15.680s
user	1m11.759s
sys	0m21.225s
Copying config.json / generation_config.json from src/KBLab_kb-whisper-small ...

Done. Output folder: ../models/KBLab_kb-whisper-small
464M	../models/KBLab_kb-whisper-small
total 16
drwxr-xr-x@ 7 sebastianstrandberg  staff   224 Sep 16 11:51 .
drwxr-xr-x@ 4 sebastianstrandberg  staff   128 Sep 16 11:49 ..
drwxr-xr-x@ 7 sebastianstrandberg  staff   224 Sep 16 11:50 AudioEncoder.mlmodelc
-rw-r--r--@ 1 sebastianstrandberg  staff  3690 Sep 16 11:51 config.json
-rw-r--r--@ 1 sebastianstrandberg  staff  3911 Sep 16 11:51 generation_config.json
drwxr-xr-x@ 7 sebastianstrandberg  staff   224 Sep 16 11:51 MelSpectrogram.mlmodelc
drwxr-xr-x@ 7 sebastianstrandberg  staff   224 Sep 16 11:49 TextDecoder.mlmodelc

[exited with code 0]
```

**Wall clock for the whole script**: 2m15.680s (the `time` block above wraps
just the `whisperkit-generate-model` invocation; snapshot download and
config copy add a few more seconds on top, well under 2m20s total).

No `FAILED`/`ERROR:`/`errors=N`/`failures=N` anywhere in the log this
time — `convert.sh`'s own grep gate passed silently, as it should when a
conversion succeeds.

### Reproducibility — proof this run came from the script

Before this run, `dikta-macos/bench/models/KBLab_kb-whisper-small/` (attempt
2's manual output) was moved aside as `KBLab_kb-whisper-small-manual`, so the
directory `convert.sh` wrote to did not exist beforehand. `convert.sh`'s own
mtime vs. every artifact it produced:

```
$ stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S %z" bench/convert/convert.sh
2026-09-16 11:48:29 +0800

$ find bench/models/KBLab_kb-whisper-small -maxdepth 1 -exec stat -f "%Sm %N" -t "%Y-%m-%dT%H:%M:%S%z" {} \; | sort
2026-09-16T11:49:28+0800 .../TextDecoder.mlmodelc
2026-09-16T11:50:37+0800 .../AudioEncoder.mlmodelc
2026-09-16T11:51:18+0800 .../MelSpectrogram.mlmodelc
2026-09-16T11:51:19+0800 .../KBLab_kb-whisper-small
2026-09-16T11:51:19+0800 .../config.json
2026-09-16T11:51:19+0800 .../generation_config.json
```

Every artifact postdates the script by 59 seconds to just under 3 minutes —
consistent with the ~2m16s run that produced them, and impossible if this
were the stale manual-run folder (which was moved to
`KBLab_kb-whisper-small-manual` and no longer occupied this path when
`convert.sh` ran).

## Failure-detection grep pattern — fixed and demonstrated

The orchestrator's skeptic flagged that the original pattern,
`^(FAILED|ERROR:) |errors=[1-9]|failures=[1-9]`, required a literal space
after `ERROR:` — matching unittest's own `ERROR: setUpClass (...)` reporting
but **not** `argmaxtools`'s `logging.basicConfig`-formatted output
(`ERROR:argmaxtools.module:message`, colon directly followed by the module
name, no space). Fixed to `^(FAILED|ERROR)[: ]|errors=[1-9]|failures=[1-9]`
(`convert.sh`, the grep right after the conversion command) — matching
either a space or a colon right after `FAILED`/`ERROR` covers both shapes.
Demonstrated against synthetic lines of each shape plus a benign control:

```
$ PATTERN='^(FAILED|ERROR)[: ]|errors=[1-9]|failures=[1-9]'

$ echo 'ERROR: setUpClass (tests.test_text_decoder.TestWhisperTextDecoder)' | grep -qE "$PATTERN" && echo MATCH
MATCH

$ echo 'ERROR:argmaxtools.test_utils:Something failed by exception' | grep -qE "$PATTERN" && echo MATCH
MATCH

$ echo 'FAILED (errors=1)' | grep -qE "$PATTERN" && echo MATCH
MATCH

$ echo 'INFO:argmaxtools.test_utils:Conversion complete, testing first load time..' | grep -qE "$PATTERN" && echo MATCH || echo "no match"
no match

$ echo 'Removing outlier decomposition errors from consideration' | grep -qE "$PATTERN" && echo MATCH || echo "no match"
no match
```

Also re-ran against the two real logs on hand: matches attempt 1's failed
log (`ERROR: setUpClass ...` / `FAILED (errors=1)`), does not match attempt
3's successful log.

## Final folder layout

```
$ du -sh dikta-macos/bench/models/KBLab_kb-whisper-small/
464M
```
- `AudioEncoder.mlmodelc/`
- `MelSpectrogram.mlmodelc/`
- `TextDecoder.mlmodelc/`
- `config.json`
- `generation_config.json`

Matches the documented model catalogue layout
(`docs/review-2026-09/whisperkit-drift.md`, "Model Catalogue":
`AudioEncoder.mlmodelc/`, `MelSpectrogram.mlmodelc/`, `TextDecoder.mlmodelc/`,
`config.json`, `generation_config.json`) exactly.

Two things needed handling beyond the raw `whisperkit-generate-model`
output, both scripted into `convert.sh`:

1. **`config.json`/`generation_config.json`.** `whisperkit-generate-model`
   only copies these into the output folder inside `upload_version()`,
   gated on `--upload-results` — which `convert.sh` deliberately never
   passes. Checked whether WhisperKit 1.1.0 actually needs them for local
   `--model-folder` loading before copying anything in: it doesn't yet —
   `Sources/WhisperKit/Core/Models.swift:52` has `// TODO: implement
   config.json and generation_config.json parsing for models`, and neither
   `AudioEncoder`/`MelSpectrogram`/`TextDecoder` loading (`WhisperKit.swift`
   `loadModels()`) nor tokenizer resolution (`loadTokenizerIfNeeded()`)
   reads either file — confirmed with
   `grep -rn "config\.json\|generation_config" Sources/` across the whole
   `argmax-oss-swift` checkout, which only turned up unrelated tokenizer/hub
   code and that TODO comment. Copied them in anyway, from the same pinned
   local snapshot used for conversion (see "Revision pinning"), to match the
   documented layout and keep the folder upload-ready for later.
2. **`AudioEncoder.mlcomputeplan.json`, `MelSpectrogram.mlcomputeplan.json`,
   `TextDecoder.mlcomputeplan.json`** were byproducts of `argmaxtools`'s
   test-time ANE-dispatch profiling (per-op cost/dispatch-target
   breakdowns, one as large as 861KB), not part of the model catalogue and
   never read by WhisperKit (`grep -rln "mlcomputeplan" Sources/` — no
   matches). Deleted.

## Tokenizer / offline limitation

`--model-folder` is **not fully offline**. The converted folder contains no
tokenizer files (`tokenizer.json`, `vocab.json`, etc. — conversion never
downloads these; see "Revision pinning" above). WhisperKit's
`loadTokenizerIfNeeded()` searches the model folder as one candidate path
(`WhisperKit.swift`'s `additionalSearchPaths = [modelFolder] + [...]`) but
falls back to downloading a tokenizer from Hugging Face
(`argmaxinc/whisperkit-coreml`) if it isn't found there. The benchmark in
this doc worked without any visible network round-trip only because that
tokenizer was already cached locally from the earlier community-model
(`--repo`/`--variant`) benchmark run. On a machine with no prior WhisperKit
usage, `--model-folder` would still make one network call for the tokenizer
on first use. Documented in the `DiktaBench --model-folder` doc comment and
at its call site (`dikta-macos/bench/DiktaBench/main.swift`) rather than
extending `convert.sh` to also fetch and bundle tokenizer files — out of
scope for this task.

## Benchmark (attempt 3's script-produced folder)

```
$ swift build --product DiktaBench 2>&1 | tail -3
Building for debugging...
Build complete! (0,25 sec)

$ MODEL_DIR="$PWD/bench/models/KBLab_kb-whisper-small"
$ swift run --package-path . DiktaBench --model-folder "$MODEL_DIR" --language sv \
    --audio-dir bench/data/sv --out bench/results/raw-KBLab_kb-whisper-small-selfconv-sv.jsonl
DiktaBench: model-folder=.../bench/models/KBLab_kb-whisper-small language=sv files=20
Model loaded in 32.14s
...
Summary: 20 files, total audio 224.8s, total wall 13.6s, overall RTF 0.061, model load 32.14s

$ swift run --package-path . DiktaBench --model-folder "$MODEL_DIR" --language en \
    --audio-dir bench/data/en --out bench/results/raw-KBLab_kb-whisper-small-selfconv-en.jsonl
Model loaded in 0.91s
...
Summary: 20 files, total audio 194.1s, total wall 12.8s, overall RTF 0.066, model load 0.91s

$ python3 score.py score --results results/raw-KBLab_kb-whisper-small-selfconv-sv.jsonl \
    --refs data/sv/refs.jsonl --model KBLab_kb-whisper-small-selfconv --lang sv
model                                         lang       WER  median RTF   load s
---------------------------------------------------------------------------------
KBLab_kb-whisper-small-selfconv               sv       3.50%       0.059     32.1

$ python3 score.py score --results results/raw-KBLab_kb-whisper-small-selfconv-en.jsonl \
    --refs data/en/refs.jsonl --model KBLab_kb-whisper-small-selfconv --lang en
model                                         lang       WER  median RTF   load s
---------------------------------------------------------------------------------
KBLab_kb-whisper-small-selfconv               en      54.19%       0.064      0.9
```

(The older summary JSONs from attempt 2's manual-folder benchmark —
`results/*-KBLab_kb-whisper-small-selfconv-{sv,en}.json` and the matching
`raw-*.jsonl` — were deleted before this re-run so `score.py report` below
reflects only the script-produced folder.)

### Results table (`score.py report`)

| model | lang | WER | median RTF | load s |
|---|---|---|---|---|
| openai_whisper-large-v3-v20240930_turbo_632MB | sv | 10.05% | 0.103 | 331.0 |
| openai_whisper-large-v3-v20240930_turbo_632MB | en | 6.67% | 0.085 | 18.4 |
| KBLab_kb-whisper-small (community) | sv | 3.50% | 0.059 | 215.0 |
| KBLab_kb-whisper-small (community) | en | 54.19% | 0.061 | 20.6 |
| apple-dictation | sv | 11.68% | 0.033 | 0.0 |
| apple-dictation | en | 11.18% | 0.043 | 0.0 |
| **KBLab_kb-whisper-small-selfconv** | **sv** | **3.50%** | 0.059 | 32.1 |
| **KBLab_kb-whisper-small-selfconv** | **en** | **54.19%** | 0.064 | 0.9 |

**Gate: Swedish WER within 1 point of the community conversion's 3.50%.**
Result: **3.50% vs 3.50% — exact match, 0.00pp difference**, from the
`convert.sh`-produced folder. English also matches exactly (54.19% vs
54.19%). Same architecture, same weights (both conversions ultimately used
KBLab's own unmodified `generation_config.json` — see cross-check above),
same WhisperKit 1.1.0 CoreML conversion path: identical transcription
output on this test set is the expected outcome, not a coincidence.

RTF and load-time differences vs. the community row (sv load 32.1s vs
215.0s, en 0.9s vs 20.6s) are local-folder-vs-first-HF-download artifacts,
not conversion-quality differences — the tokenizer was already cached from
the earlier community-model benchmark run (see "Tokenizer / offline
limitation" above), and no network round-trip was needed for the model
files themselves.

## Validation

```
$ swift build --product DiktaBench 2>&1 | tail -3
    /Users/sebastianstrandberg/work/git/dikta/dikta-macos/Dikta/Resources/minilm-vocab.txt
Building for debugging...
Build complete! (0,25 sec)

$ xcodebuild test -project Dikta.xcodeproj -scheme Dikta -only-testing:DiktaTests \
    -destination 'platform=macOS' CODE_SIGN_IDENTITY=- 2>&1 | grep 'Executed.*test'
...
	 Executed 240 tests, with 0 failures (0 unexpected) in 0.258 (0.307) seconds
	 Executed 240 tests, with 0 failures (0 unexpected) in 0.258 (0.308) seconds
```
240/240, matching baseline — no regression from the harness change.

No repo-root sandbox junk (`TemporaryDirectory.*`, `_Users_*.lock`,
`swift-generated-sources/`) was present at any point during this task
(checked repeatedly). Nothing committed; still on `feat/drop-apple-dictation`.

## Not done here

- **No upload to Hugging Face.** Nothing in this task ever passed
  `--upload-results`; `bench/models/KBLab_kb-whisper-small/` exists only
  locally (gitignored).
- **No app integration.** The app still points at
  `Leonidng/whisperkit-kb-whisper-small`. Swapping to a self-hosted repo (or
  bundling the converted model) is a separate step, needing the maintainer's
  Hugging Face login to publish anywhere.
- **`--model-folder` is not fully offline** — see "Tokenizer / offline
  limitation" above. Bundling tokenizer files into the converted folder (or
  adding a `--tokenizer-folder` passthrough to `DiktaBench`) would close
  this but wasn't requested and would extend scope beyond this task.

## Published and verified from the Hub (2026-09-16)

Uploaded to `sebastian-duadigital/whisperkit-kb-whisper-small` (public, Apache 2.0, repo commit `3491633d80f2df18058b2189a78cfb26b1ff5419`, 464 MB, folder `KBLab_kb-whisper-small/` plus a model card). Verified through the same download path the app uses:

```
DiktaBench --repo sebastian-duadigital/whisperkit-kb-whisper-small --variant KBLab_kb-whisper-small --language {sv,en} ...
score.py score --model KBLab_kb-whisper-small-hub
```

| model | lang | WER | median RTF | load s |
|---|---|---|---|---|
| KBLab_kb-whisper-small-hub | sv | 3.50% | 0.070 | 149.0 (includes first download + CoreML compile) |
| KBLab_kb-whisper-small-hub | en | 54.19% | 0.063 | 14.2 |

Identical WER to the local script-produced folder and to the community conversion.
