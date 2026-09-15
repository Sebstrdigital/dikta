#!/usr/bin/env python3
"""Score DiktaBench output against FLEURS references and print a WER table.

Two subcommands:

  score.py score --results <results.jsonl> --refs <refs.jsonl> \
                  --model <variant> --lang sv|en
      Computes aggregate WER + median RTF + model load time for one
      (model, language) run, writes bench/results/<timestamp>-<variant>-<lang>.json,
      and prints that one row.

  score.py report
      Reads every bench/results/*.json summary and prints the full table,
      newest run per (model, lang) pair last.

Normalisation (applied identically to reference and hypothesis before WER):
lowercase, strip punctuation, collapse whitespace, Unicode NFC. Letters with
diacritics (e.g. åäö) are kept — punctuation stripping only removes non-word
characters, and \\w is Unicode-aware in Python's re module.

WER is aggregate (total edit distance / total reference words across the
whole file set), not the mean of per-file WER — matches the method in
docs/review-2026-09/stt-landscape-2026-09.md.
"""

import argparse
import json
import re
import statistics
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

import jiwer

BENCH_DIR = Path(__file__).resolve().parent
RESULTS_DIR = BENCH_DIR / "results"

# Whisper control tokens (<|startoftranscript|>, <|en|>, <|0.00|>, <|endoftext|>, ...).
# DiktaBench emits raw segment text on purpose (see Bench/main.swift), same as
# WhisperKit itself returns it before Dikta's own Transcriber.cleanSegments runs,
# so these must be stripped here before WER — otherwise "startoftranscript" etc.
# get counted as real words and WER blows up.
_CONTROL_TOKEN_RE = re.compile(r"<\|[^|]+\|>")
_PUNCT_RE = re.compile(r"[^\w\s]", flags=re.UNICODE)
_WS_RE = re.compile(r"\s+")


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFC", text)
    text = _CONTROL_TOKEN_RE.sub(" ", text)
    text = text.lower()
    text = _PUNCT_RE.sub(" ", text)
    text = _WS_RE.sub(" ", text).strip()
    return text


def load_jsonl(path: Path) -> list[dict]:
    records = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            records.append(json.loads(line))
    return records


def cmd_score(args: argparse.Namespace) -> None:
    results_path = Path(args.results)
    refs_path = Path(args.refs)

    results = {r["file"]: r for r in load_jsonl(results_path)}
    refs = {r["file"]: r["reference"] for r in load_jsonl(refs_path)}

    common_files = sorted(set(results) & set(refs))
    missing_results = sorted(set(refs) - set(results))
    missing_refs = sorted(set(results) - set(refs))
    if missing_results:
        print(f"WARNING: {len(missing_results)} ref file(s) have no bench result: {missing_results}", file=sys.stderr)
    if missing_refs:
        print(f"WARNING: {len(missing_refs)} bench result(s) have no reference: {missing_refs}", file=sys.stderr)
    if not common_files:
        print("ERROR: no overlapping files between results and refs", file=sys.stderr)
        sys.exit(1)

    # jiwer.wer raises on an empty reference (it can't divide by zero
    # reference words), so skip those clips rather than letting the whole
    # run crash on one bad FLEURS reference.
    references = []
    hypotheses = []
    empty_ref_files = []
    for f in common_files:
        ref = normalize(refs[f])
        if not ref:
            empty_ref_files.append(f)
            continue
        references.append(ref)
        hypotheses.append(normalize(results[f]["text"]))

    if empty_ref_files:
        print(f"WARNING: {len(empty_ref_files)} file(s) have an empty reference after normalization, skipped: {empty_ref_files}", file=sys.stderr)
    if not references:
        print("ERROR: every overlapping file has an empty reference, nothing to score", file=sys.stderr)
        sys.exit(1)

    aggregate_wer = jiwer.wer(references, hypotheses)

    rtfs = [
        results[f]["seconds_wall"] / results[f]["seconds_audio"]
        for f in common_files
        if results[f]["seconds_audio"] > 0
    ]
    median_rtf = statistics.median(rtfs) if rtfs else float("nan")

    load_times = [results[f]["model_load_seconds"] for f in common_files]
    model_load_seconds = load_times[0] if load_times else float("nan")

    summary = {
        "model": args.model,
        "lang": args.lang,
        "n_files": len(common_files),
        "wer": aggregate_wer,
        "median_rtf": median_rtf,
        "model_load_seconds": model_load_seconds,
        "scored_at": datetime.now(timezone.utc).isoformat(),
    }

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = RESULTS_DIR / f"{timestamp}-{args.model}-{args.lang}.json"
    out_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")

    print_table([summary])
    print(f"wrote {out_path}")


def cmd_report(args: argparse.Namespace) -> None:
    summaries = []
    for path in sorted(RESULTS_DIR.glob("*.json")):
        try:
            summaries.append(json.loads(path.read_text()))
        except json.JSONDecodeError:
            continue
    if not summaries:
        print(f"No summaries found in {RESULTS_DIR}")
        return
    print_table(summaries)


def print_table(rows: list[dict]) -> None:
    header = f"{'model':<45} {'lang':<5} {'WER':>8} {'median RTF':>11} {'load s':>8}"
    print(header)
    print("-" * len(header))
    for r in rows:
        print(
            f"{r['model']:<45} {r['lang']:<5} "
            f"{r['wer'] * 100:>7.2f}% {r['median_rtf']:>11.3f} {r['model_load_seconds']:>8.1f}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_score = sub.add_parser("score", help="score one results.jsonl against refs.jsonl")
    p_score.add_argument("--results", required=True)
    p_score.add_argument("--refs", required=True)
    p_score.add_argument("--model", required=True, help="model variant label, e.g. openai_whisper-small")
    p_score.add_argument("--lang", required=True, choices=["sv", "en"])
    p_score.set_defaults(func=cmd_score)

    p_report = sub.add_parser("report", help="print a table from all saved summaries")
    p_report.set_defaults(func=cmd_report)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
