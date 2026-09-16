#!/usr/bin/env bash
# DiktaBench end-to-end runner: fetch clips -> transcribe -> score -> report.
#
# Usage:
#   ./run.sh                                  # default pairs, both languages
#   ./run.sh <repo1> <variant1> [<repo2> <variant2> ...]
#
# Each pair is a Hugging Face repo + WhisperKit variant id, e.g.:
#   ./run.sh argmaxinc/whisperkit-coreml openai_whisper-small
#
# The literal pair `apple apple` selects Apple's on-device DictationTranscriber
# engine instead of WhisperKit (macOS 26+ only; see
# docs/review-2026-09/apple-dictation-engine-spec.md). It ignores repo/variant
# and is scored/labelled as model `apple-dictation`, e.g.:
#   ./run.sh apple apple
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

    if [[ "$repo" == "apple" && "$variant" == "apple" ]]; then
        engine="apple"
        model_label="apple-dictation"
    else
        engine="whisper"
        model_label="$variant"
    fi

    for lang in sv en; do
        audio_dir="$DATA_DIR/$lang"
        if [[ ! -d "$audio_dir" ]] || [[ -z "$(ls -A "$audio_dir"/*.wav 2>/dev/null)" ]]; then
            echo "Skipping $model_label/$lang: no clips in $audio_dir"
            continue
        fi

        raw_out="$RESULTS_DIR/raw-${model_label}-${lang}.jsonl"
        echo "=== $model_label ($repo) / $lang ==="
        if [[ "$engine" == "apple" ]]; then
            "$DIKTABENCH_BIN" \
                --engine apple \
                --language "$lang" \
                --audio-dir "$audio_dir" \
                --out "$raw_out"
        else
            "$DIKTABENCH_BIN" \
                --repo "$repo" \
                --variant "$variant" \
                --language "$lang" \
                --audio-dir "$audio_dir" \
                --out "$raw_out"
        fi

        python3 "$SCRIPT_DIR/score.py" score \
            --results "$raw_out" \
            --refs "$audio_dir/refs.jsonl" \
            --model "$model_label" \
            --lang "$lang"
    done
done

echo
echo "=== Full report ==="
python3 "$SCRIPT_DIR/score.py" report
