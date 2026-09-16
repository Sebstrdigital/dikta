#!/usr/bin/env bash
# Converts KBLab/kb-whisper-small (PyTorch) to the WhisperKit CoreML layout
# via Argmax's whisperkittools. See README.md in this directory for context,
# requirements, and how to benchmark the result afterwards.
#
# Usage:
#   ./convert.sh            # reuse existing venv/checkout/snapshot if present
#   ./convert.sh --clean    # wipe .venv/, whisperkittools/, and src/ first

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODEL_REPO="KBLab/kb-whisper-small"
MODEL_REVISION="3564d61a42fc210ceaa55a22a96dd64478959c78"  # pinned HEAD of KBLab/kb-whisper-small main, recorded 2026-09-16
MODEL_LOCAL_NAME="KBLab_kb-whisper-small"  # deliberately no "/" — see naming note below
SRC_DIR="src"
OUTPUT_DIR="../models"
PINNED_COMMIT="84f77a83c8f530022ae55fbb1a64b3351ef63c7a"  # whisperkittools main, 2026-09-16 — no version tags exist upstream
PYTHON_BIN="/opt/homebrew/bin/python3.11"

if [[ "${1:-}" == "--clean" ]]; then
    echo "Removing existing .venv/, whisperkittools/, and src/ ..."
    rm -rf .venv whisperkittools src
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
    echo "error: $PYTHON_BIN not found. whisperkittools needs Python 3.11 (see README.md)." >&2
    exit 1
fi

if ! xcrun -f coremlcompiler >/dev/null 2>&1; then
    echo "error: coremlcompiler not found. Install/select a full Xcode: xcode-select --switch /Applications/Xcode.app" >&2
    exit 1
fi

if [[ ! -d .venv ]]; then
    echo "Creating venv with $PYTHON_BIN ..."
    "$PYTHON_BIN" -m venv .venv
    .venv/bin/python -m pip install --upgrade pip -q
fi

if [[ ! -d whisperkittools ]]; then
    echo "Cloning whisperkittools ..."
    git clone https://github.com/argmaxinc/whisperkittools.git whisperkittools
fi

CURRENT_COMMIT="$(git -C whisperkittools rev-parse HEAD)"
if [[ "$CURRENT_COMMIT" != "$PINNED_COMMIT" ]]; then
    echo "Checking out pinned commit $PINNED_COMMIT (was $CURRENT_COMMIT) ..."
    git -C whisperkittools fetch origin
    git -C whisperkittools checkout "$PINNED_COMMIT"
fi

echo "Installing whisperkittools (torch/coremltools/transformers — several GB, several minutes) ..."
.venv/bin/pip install -e ./whisperkittools

# Pin the source model to one exact revision and download it ONCE, locally.
# The conversion itself reads from this local snapshot (never touches the
# network for model files again), and the config.json/generation_config.json
# copied into the output folder later come from this same snapshot — one
# revision, one download, no drift between what got converted and what got
# copied. Restricted to the 3 files conversion actually needs (config.json,
# generation_config.json, model.safetensors) — the repo also ships ONNX/GGML
# variants and tokenizer files this doesn't touch (tokenizer files are only
# needed for whisperkittools's optional --generate-decoder-context-prefill-data
# path, which convert.sh doesn't use).
SRC_MODEL_DIR="$SRC_DIR/$MODEL_LOCAL_NAME"
echo "Downloading $MODEL_REPO @ $MODEL_REVISION -> $SRC_MODEL_DIR/ (pinned snapshot) ..."
.venv/bin/python -c "
from huggingface_hub import snapshot_download
path = snapshot_download(
    repo_id='$MODEL_REPO',
    revision='$MODEL_REVISION',
    local_dir='$SRC_MODEL_DIR',
    allow_patterns=['config.json', 'generation_config.json', 'model.safetensors'],
)
print('  snapshot at', path)
"

OUT_FOLDER="$OUTPUT_DIR/$MODEL_LOCAL_NAME"
CONVERT_LOG="$(mktemp)"

echo "Converting $SRC_MODEL_DIR -> $OUT_FOLDER/ ..."
echo "(no --upload-results passed: this never touches Hugging Face write access)"
# Run with cwd inside $SRC_DIR and pass the model as a bare relative name
# (no "/") rather than an absolute path: whisperkittools names its output
# folder as output_dir + model_version.replace("/", "_")
# (scripts/generate_model.py), so a path containing slashes would produce an
# ugly, un-guessable folder name. A bare name with no slashes survives that
# .replace() unchanged, giving exactly "KBLab_kb-whisper-small" with no
# renaming needed afterwards. This also happens to make the conversion
# resilient to the transient-download issue seen on 2026-09-16 (see the
# conversion doc): WhisperForConditionalGeneration.from_pretrained() on a
# local directory reads generation_config.json off disk directly, with no
# network round-trip during conversion at all.
(
    cd "$SRC_DIR"
    time ../.venv/bin/whisperkit-generate-model \
        --model-version "$MODEL_LOCAL_NAME" \
        --output-dir "../$OUTPUT_DIR" 2>&1 | tee "$CONVERT_LOG"
)

# generate_model.py doesn't check its own test suites' results and exits 0
# regardless (confirmed 2026-09-16) — grep its log ourselves. Matches both
# unittest's own failure reporting ("ERROR: setUpClass (...)", "FAILED
# (errors=1)") and argmaxtools's logging-module output (default
# logging.basicConfig format "ERROR:argmaxtools.module:message", colon with
# no space) — an earlier version of this check only matched the first shape.
if grep -qE "^(FAILED|ERROR)[: ]|errors=[1-9]|failures=[1-9]" "$CONVERT_LOG"; then
    echo "" >&2
    echo "error: whisperkit-generate-model reported a test failure/error (exit code is not reliable — see above). Not treating this as a successful conversion." >&2
    rm -f "$CONVERT_LOG"
    exit 1
fi
rm -f "$CONVERT_LOG"

# whisperkit-generate-model only copies config.json/generation_config.json
# into the output folder when --upload-results is passed (they live inside
# upload_version(), gated on that flag) — we deliberately never pass it. Copy
# them ourselves from the SAME pinned local snapshot used for conversion
# (not a fresh download), verbatim, no edits — one source, no drift.
# WhisperKit 1.1.0 doesn't currently parse either file for local model
# loading (Sources/WhisperKit/Core/Models.swift:52, "TODO: implement
# config.json and generation_config.json parsing for models") but the
# documented model catalogue layout (docs/review-2026-09/whisperkit-drift.md)
# includes them, and they're required for eventual HF upload — so this
# keeps the folder upload-ready and future-proof rather than minimal.
echo "Copying config.json / generation_config.json from $SRC_MODEL_DIR ..."
cp "$SRC_MODEL_DIR/config.json" "$OUT_FOLDER/config.json"
cp "$SRC_MODEL_DIR/generation_config.json" "$OUT_FOLDER/generation_config.json"

# *.mlcomputeplan.json are argmaxtools test-profiling byproducts (per-op ANE
# dispatch cost breakdowns) — confirmed via grep that nothing in WhisperKit's
# Swift source reads them. Not part of the documented model catalogue layout.
rm -f "$OUT_FOLDER"/*.mlcomputeplan.json

echo ""
echo "Done. Output folder: $OUT_FOLDER"
du -sh "$OUT_FOLDER"
ls -la "$OUT_FOLDER"
