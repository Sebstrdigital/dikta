#!/usr/bin/env bash
# DiktaBench end-to-end runner: fetch clips -> transcribe -> score -> report.
#
# Usage:
#   ./run.sh                                  # default pairs, both languages
#   ./run.sh <repo1> <variant1> [<repo2> <variant2> ...]
#
# Each pair is a Hugging Face repo + WhisperKit variant id, e.g.:
#   ./run.sh argmaxinc/whisperkit-coreml openai_whisper-small
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
DATA_DIR="$SCRIPT_DIR/data"
RESULTS_DIR="$SCRIPT_DIR/results"

# --- venv setup -------------------------------------------------------------
if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating venv at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet -r "$SCRIPT_DIR/requirements.txt"

# --- fetch clips (idempotent) ------------------------------------------------
python3 "$SCRIPT_DIR/fetch_clips.py"

# --- pairs to benchmark ------------------------------------------------------
if [[ $# -eq 0 ]]; then
    set -- \
        argmaxinc/whisperkit-coreml openai_whisper-small \
        argmaxinc/whisperkit-coreml openai_whisper-large-v3-v20240930_turbo_632MB
fi

if (( $# % 2 != 0 )); then
    echo "Error: expected an even number of args (repo variant repo variant ...)" >&2
    exit 1
fi

mkdir -p "$RESULTS_DIR"

# --- build DiktaBench once --------------------------------------------------
echo "Building DiktaBench..."
(cd "$PROJECT_DIR" && swift build --product DiktaBench)

DIKTABENCH_BIN="$(cd "$PROJECT_DIR" && swift build --show-bin-path)/DiktaBench"

while (( $# > 0 )); do
    repo="$1"; variant="$2"; shift 2
    for lang in sv en; do
        audio_dir="$DATA_DIR/$lang"
        if [[ ! -d "$audio_dir" ]] || [[ -z "$(ls -A "$audio_dir"/*.wav 2>/dev/null)" ]]; then
            echo "Skipping $variant/$lang: no clips in $audio_dir"
            continue
        fi

        raw_out="$RESULTS_DIR/raw-${variant}-${lang}.jsonl"
        echo "=== $variant ($repo) / $lang ==="
        "$DIKTABENCH_BIN" \
            --repo "$repo" \
            --variant "$variant" \
            --language "$lang" \
            --audio-dir "$audio_dir" \
            --out "$raw_out"

        python3 "$SCRIPT_DIR/score.py" score \
            --results "$raw_out" \
            --refs "$audio_dir/refs.jsonl" \
            --model "$variant" \
            --lang "$lang"
    done
done

echo
echo "=== Full report ==="
python3 "$SCRIPT_DIR/score.py" report
