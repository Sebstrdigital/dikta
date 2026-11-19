#!/usr/bin/env python3
"""Transcribe a mono 16 kHz PCM recording with Parakeet Ultra on the CPU."""
import os
from pathlib import Path
import sys
import wave

import numpy as np
import sherpa_onnx


def main():
    if len(sys.argv) != 2:
        raise ValueError("Usage: dikta-transcribe recording.wav")
    data_home = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    model = data_home / "dikta/models/parakeet-ultra-int8"
    files = [model / name for name in (
        "encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"
    )]
    missing = [str(path) for path in files if not path.is_file()]
    if missing:
        raise RuntimeError("Parakeet Ultra model is missing: " + ", ".join(missing))
    with wave.open(sys.argv[1], "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
            raise ValueError("Recording must be mono 16-bit PCM at 16 kHz")
        samples = np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
    if not samples.size:
        return
    recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
        *(str(path) for path in files), num_threads=min(4, os.cpu_count() or 1),
        sample_rate=16000, feature_dim=128, model_type="nemo_transducer",
        provider="cpu", decoding_method="greedy_search",
    )
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
    print(" ".join(parts))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Transcription failed: {exc}", file=sys.stderr)
        sys.exit(1)
