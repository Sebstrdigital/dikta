#!/usr/bin/env python3
"""Transcribe a mono 16 kHz PCM recording with Parakeet Ultra on the CPU."""
import json
import os
from pathlib import Path
import sys
import time
import wave

timing = {"failure_stage": "audio"}

def elapsed_ms(start):
    return (time.perf_counter_ns() - start) / 1_000_000


def model_files():
    timing["failure_stage"] = "model_files"
    data_home = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    model = data_home / "dikta/models/parakeet-ultra-int8"
    files = [model / name for name in (
        "encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"
    )]
    missing = [str(path) for path in files if not path.is_file()]
    if missing:
        raise RuntimeError("Parakeet Ultra model is missing: " + ", ".join(missing))
    return files


def load_audio(path):
    import numpy as np

    timing["failure_stage"] = "audio"
    with wave.open(path, "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
            raise ValueError("Recording must be mono 16-bit PCM at 16 kHz")
        return np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(np.float32) / 32768.0


def load_recognizer(files):
    timing["failure_stage"] = "model_init"
    started = time.perf_counter_ns()
    try:
        import numpy  # Check both runtime dependencies during worker initialization.
        import sherpa_onnx

        return sherpa_onnx.OfflineRecognizer.from_transducer(
            *(str(path) for path in files), num_threads=min(4, os.cpu_count() or 1),
            sample_rate=16000, feature_dim=128, model_type="nemo_transducer",
            provider="cpu", decoding_method="greedy_search",
        )
    finally:
        timing["model_init_ms"] = elapsed_ms(started)


def transcribe(recognizer, samples):
    timing["failure_stage"] = "decode"
    started = time.perf_counter_ns()
    try:
        return decode(recognizer, samples)
    finally:
        timing["decode_ms"] = elapsed_ms(started)


def main():
    if len(sys.argv) not in (2, 3):
        raise ValueError("Usage: dikta-transcribe recording.wav [timing.json]")
    files = model_files()
    samples = load_audio(sys.argv[1])
    if not samples.size:
        return
    recognizer = load_recognizer(files)
    print(transcribe(recognizer, samples))
    timing.pop("failure_stage", None)


def decode(recognizer, samples):
    import numpy as np

    parts = []
    start = 0
    while start < len(samples):
        end = min(start + 25 * 16000, len(samples))
        if end < len(samples):
            # Cut at the quietest 100 ms in the final three seconds of a chunk.
            window = samples[end - 3 * 16000:end]
            rms = np.mean(window.reshape(-1, 1600) ** 2, axis=1)
            end = end - 3 * 16000 + (int(np.argmin(rms)) + 1) * 1600
        stream = recognizer.create_stream()
        stream.accept_waveform(16000, samples[start:end])
        recognizer.decode_stream(stream)
        text = stream.result.text.strip()
        if text:
            parts.append(text)
        start = end
    return " ".join(parts)


def worker():
    # Keep native library output away from the protocol pipe as well as Python output.
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())

    def send(message):
        print(json.dumps(message, ensure_ascii=True), file=protocol, flush=True)

    try:
        recognizer = load_recognizer(model_files())
    except Exception as exc:
        send({"type": "init_error", "error": str(exc), "failure_stage": timing["failure_stage"]})
        return 1

    send({"type": "ready", "model_init_ms": timing["model_init_ms"]})
    for line in sys.stdin.buffer:
        timing["failure_stage"] = "audio"
        try:
            request = json.loads(line)
            if not isinstance(request, dict) or not isinstance(request.get("audio_path"), str) or not request["audio_path"]:
                raise ValueError("Request must contain a nonempty audio_path string")
            samples = load_audio(request["audio_path"])
            if samples.size:
                text = transcribe(recognizer, samples)
                decode_ms = timing["decode_ms"]
            else:
                text = ""
                decode_ms = 0
            send({"type": "result", "text": text, "decode_ms": decode_ms})
        except Exception as exc:
            send({"type": "error", "error": str(exc), "failure_stage": timing["failure_stage"]})
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--worker"]:
        sys.exit(worker())
    try:
        main()
    except Exception as exc:
        print(f"Transcription failed: {exc}", file=sys.stderr)
        sys.exit(1)
    finally:
        if len(sys.argv) == 3:
            try:
                Path(sys.argv[2]).write_text(json.dumps(timing), encoding="utf-8")
            except (OSError, ValueError):
                pass
