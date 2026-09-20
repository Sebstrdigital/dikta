"""Command-line entry point for Dikta."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from dikta.engines.audio.loader import SUPPORTED_EXTENSIONS

#: ISO 639-1/639-3 code shape (STT can be asked to force many languages;
#: `render_language` falls back to English for anything it doesn't
#: recognize, so this only needs to reject obviously-malformed input).
_LANGUAGE_CODE_PATTERN = re.compile(r"^[a-z]{2,3}$")


def _parse_candidate_languages(raw: str) -> list[str] | None:
    """Parse `--candidates`: "all" means unrestricted (`None`), else a comma-separated code list.

    Raises `ValueError` (with the offending code as its argument) if any
    entry doesn't match `_LANGUAGE_CODE_PATTERN`.
    """
    if raw == "all":
        return None
    codes = [code.strip() for code in raw.split(",") if code.strip()]
    for code in codes:
        if not _LANGUAGE_CODE_PATTERN.fullmatch(code):
            raise ValueError(code)
    return codes


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dikta")
    parser.add_argument(
        "-V", "--version", action="store_true", help="print the version and exit"
    )
    subparsers = parser.add_subparsers(dest="command")

    debrief = subparsers.add_parser("debrief", help="summarize a recorded meeting file")
    debrief.add_argument("file", type=Path, help="path to an audio file")
    debrief.add_argument("--language", default=None, help="ISO 639-1/639-3 code, e.g. sv, en, id")
    debrief.add_argument("--engine", choices=["auto", "ollama", "heuristic"], default="auto")
    debrief.add_argument("--stt-model", default="small")
    debrief.add_argument(
        "--candidates",
        default="en,sv",
        help=(
            "comma-separated ISO 639-1/639-3 codes to restrict language "
            "auto-detection to, or 'all' for unrestricted auto-detect (default: en,sv)"
        ),
    )
    debrief.add_argument("--ollama-model", default=None)
    debrief.add_argument(
        "--offline",
        action="store_true",
        help="never download an STT model that isn't already cached (fail instead)",
    )
    debrief.add_argument("--root", type=Path, default=None)
    debrief.add_argument("--in-process", action="store_true")
    debrief.add_argument("--json", action="store_true")
    # Forces stt_engine="fake" instead of faster-whisper — tests/bench only.
    debrief.add_argument("--fake-stt-text", default=None, help=argparse.SUPPRESS)

    subparsers.add_parser("gui", help="launch the desktop GUI")

    return parser


def main(argv: list[str] | None = None) -> int:
    """Run the Dikta CLI."""
    args = sys.argv[1:] if argv is None else argv
    parser = _build_parser()
    parsed = parser.parse_args(args)

    if parsed.version:
        from dikta import __version__

        print(f"dikta {__version__}")
        return 0

    if parsed.command == "debrief":
        return _run_debrief(parsed)

    if parsed.command == "gui":
        return _run_gui()

    parser.print_usage(sys.stderr)
    return 2


def _run_debrief(args: argparse.Namespace) -> int:
    from dikta.engines.llm.factory import DEFAULT_OLLAMA_MODEL, EngineKind
    from dikta.worker.client import WorkerClient, WorkerError
    from dikta.worker.protocol import DebriefRequest, StageEvent

    if args.language is not None and not _LANGUAGE_CODE_PATTERN.fullmatch(args.language):
        print(f"dikta debrief: invalid --language code: {args.language!r}", file=sys.stderr)
        return 2

    try:
        candidate_languages = _parse_candidate_languages(args.candidates)
    except ValueError as exc:
        print(f"dikta debrief: invalid --candidates code: {exc}", file=sys.stderr)
        return 2

    file_path: Path = args.file
    extension = file_path.suffix.lstrip(".").lower()
    if extension not in SUPPORTED_EXTENSIONS or not file_path.exists():
        print(f"dikta debrief: unsupported or missing file: {file_path}", file=sys.stderr)
        return 2

    request = DebriefRequest(
        file=file_path,
        language=args.language,
        stt_engine="fake" if args.fake_stt_text is not None else "faster-whisper",
        stt_model=args.stt_model,
        fake_stt_text=args.fake_stt_text,
        engine_kind=EngineKind(args.engine),
        ollama_model=args.ollama_model or DEFAULT_OLLAMA_MODEL,
        store_root=args.root,
        candidate_languages=candidate_languages,
        offline=args.offline,
    )

    def on_event(event) -> None:
        if isinstance(event, StageEvent):
            print(f"[{event.stage}] ...", file=sys.stderr)

    try:
        if args.in_process:
            result = _run_in_process(request, on_event)
        else:
            result = WorkerClient().run(request, on_event=on_event)
    except WorkerError as exc:
        print(exc.message, file=sys.stderr)
        return exc.exit_code if exc.exit_code is not None else 1

    if result.detected_language is not None:
        print(f"[transcribing] done, language={result.detected_language}", file=sys.stderr)
    if args.json:
        print(result.model_dump_json())
    else:
        print(result.rendered_text, end="")
    print(f"saved to {result.folder}", file=sys.stderr)
    return 0


def _run_gui() -> int:
    """Launch the desktop GUI (`dikta.app.main`).

    Imported lazily so the CLI (`--version`, `debrief`, ...) stays usable
    on a machine without a display / Qt installed.
    """
    from dikta.app.main import main as gui_main

    return gui_main([])


def _run_in_process(request, on_event):
    """Run `child.run` directly in this process instead of spawning a worker subprocess.

    Useful for debugging: no subprocess, so a debugger/breakpoint in the
    pipeline works normally.
    """
    from dikta.worker import child
    from dikta.worker.client import WorkerError
    from dikta.worker.protocol import ErrorEvent, ResultEvent

    result = None
    error = None

    def emit(event) -> None:
        nonlocal result, error
        on_event(event)
        if isinstance(event, ResultEvent):
            result = event
        elif isinstance(event, ErrorEvent):
            error = event

    exit_code = child.run(request, emit)
    if result is not None:
        return result
    assert error is not None
    raise WorkerError(error.kind, error.message, exit_code=exit_code)


if __name__ == "__main__":
    sys.exit(main())
