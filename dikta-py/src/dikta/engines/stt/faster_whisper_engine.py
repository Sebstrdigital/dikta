"""`SpeechToText` engine backed by faster-whisper (CTranslate2)."""

from __future__ import annotations

import logging
import threading
import time
from collections.abc import Sequence
from pathlib import Path

import numpy as np

from dikta.engines.stt.base import TranscriptionError, TranscriptionResult, TranscriptSegment

__all__ = ["FasterWhisperEngine"]

_log = logging.getLogger("dikta.engines.stt")

# `SpeechToText.transcribe` always receives 16 kHz mono audio (see base.py).
_SAMPLE_RATE = 16_000

#: Number of top language probabilities to log alongside the chosen
#: candidate, so a misdetection is diagnosable from the log line alone.
_LOG_TOP_N_LANGUAGES = 5


class FasterWhisperEngine:
    """Transcribes audio with a `faster_whisper.WhisperModel`.

    `model` accepts a faster-whisper size name ("tiny", "small",
    "large-v3-turbo", ...) or any HuggingFace CTranslate2 repo id, so a
    KB-Whisper checkpoint can be used the same way. The model is loaded
    lazily on the first `transcribe` call, guarded by a lock so concurrent
    callers don't trigger duplicate loads.
    """

    def __init__(
        self,
        model: str = "small",
        device: str = "auto",
        compute_type: str = "int8",
        download_root: Path | None = None,
        beam_size: int = 5,
        vad_filter: bool = True,
        candidate_languages: Sequence[str] | None = ("en", "sv"),
        language_detection_segments: int = 5,
        offline: bool = False,
    ) -> None:
        self._model_name = model
        self._device = device
        self._compute_type = compute_type
        self._download_root = download_root
        self._beam_size = beam_size
        self._vad_filter = vad_filter
        # `tuple(...)` so a falsy-but-non-None empty sequence (`()`, `[]`)
        # collapses to `None` too -- both mean "no restriction".
        self._candidate_languages = tuple(candidate_languages) if candidate_languages else None
        self._language_detection_segments = language_detection_segments
        #: When true, never fall back to downloading an uncached model --
        #: `_ensure_model` raises instead. Keeps a `--offline` run from
        #: silently hitting the network the first time a new model size is
        #: requested.
        self._offline = offline
        self._model: object | None = None
        self._lock = threading.Lock()

    @property
    def name(self) -> str:
        return f"faster-whisper:{self._model_name}"

    def _ensure_model(self) -> object:
        if self._model is not None:
            return self._model
        with self._lock:
            # Re-check, then work with a local: returning `self._model` after
            # releasing the lock would race a concurrent `unload()`, which
            # could hand back None here even though a model was just loaded.
            model = self._model
            if model is None:
                model = self._load_model()
                self._model = model
        return model

    def _load_model(self) -> object:
        """Construct the `WhisperModel`, preferring an already-downloaded copy.

        Tries `local_files_only=True` first, so a normal run never makes a
        network call (a HuggingFace Hub `GET .../revision/main` lookup on
        every single load, even for a model already on disk, otherwise
        breaks the offline requirement). Only if that raises (the model
        isn't cached yet) does it retry with `local_files_only=False`,
        which is allowed to hit the network -- unless `self._offline` is
        set, in which case it raises `TranscriptionError` instead of ever
        retrying.
        """
        from faster_whisper import WhisperModel

        kwargs: dict[str, object] = {
            "device": self._device,
            "compute_type": self._compute_type,
            "download_root": str(self._download_root) if self._download_root else None,
        }
        start = time.monotonic()
        try:
            model = WhisperModel(self._model_name, local_files_only=True, **kwargs)
        except Exception as local_exc:  # noqa: BLE001
            if self._offline:
                raise TranscriptionError(
                    f"model {self._model_name!r} is not downloaded and offline mode is on"
                ) from local_exc
            _log.info("downloading model %r", self._model_name)
            try:
                model = WhisperModel(self._model_name, local_files_only=False, **kwargs)
            except Exception as exc:  # noqa: BLE001
                raise TranscriptionError(
                    f"Failed to load model {self._model_name!r}: {exc}"
                ) from exc
        _log.info("loaded model %r in %.2fs", self._model_name, time.monotonic() - start)
        return model

    def transcribe(self, samples: np.ndarray, language: str | None = None) -> TranscriptionResult:
        model = self._ensure_model()
        start = time.monotonic()
        transcribe_kwargs: dict[str, object] = {
            "beam_size": self._beam_size,
            "vad_filter": self._vad_filter,
        }
        try:
            if language is not None:
                # Caller forced a language -- skip detection entirely.
                transcribe_kwargs["language"] = language
            elif self._candidate_languages is None:
                # No restriction: let faster-whisper's own multi-window
                # auto-detect (across every language it knows) pick.
                transcribe_kwargs["language"] = None
                transcribe_kwargs["language_detection_segments"] = (
                    self._language_detection_segments
                )
            else:
                chosen = self._detect_candidate_language(model, samples)
                if chosen is None:
                    # `detect_language` failed or gave us nothing usable --
                    # fall back to the same unrestricted path as above.
                    transcribe_kwargs["language"] = None
                    transcribe_kwargs["language_detection_segments"] = (
                        self._language_detection_segments
                    )
                else:
                    transcribe_kwargs["language"] = chosen

            segments_iter, info = model.transcribe(samples, **transcribe_kwargs)
            segments = tuple(
                TranscriptSegment(text=segment.text.strip(), start=segment.start, end=segment.end)
                for segment in segments_iter
            )
            # Read inside the try so a malformed `info` (missing/renamed
            # attribute) is wrapped in TranscriptionError like any other
            # faster-whisper failure, rather than raising AttributeError.
            language = getattr(info, "language", None)
        except Exception as exc:  # noqa: BLE001
            raise TranscriptionError(f"Transcription failed: {exc}") from exc

        text = " ".join(segment.text for segment in segments if segment.text)
        audio_seconds = len(samples) / _SAMPLE_RATE
        _log.info(
            "transcribed %.2fs of audio in %.2fs (%d segments)",
            audio_seconds,
            time.monotonic() - start,
            len(segments),
        )
        return TranscriptionResult(
            text=text,
            segments=segments,
            language=language,
            audio_seconds=audio_seconds,
        )

    def _detect_candidate_language(self, model: object, samples: np.ndarray) -> str | None:
        """Run `WhisperModel.detect_language` and pick the highest-probability candidate.

        Returns `None` (signalling "fall back to unrestricted auto-detect")
        if detection itself fails, returns no probabilities, or none of
        `self._candidate_languages` appear in what it did return.
        """
        try:
            _, _, all_language_probs = model.detect_language(
                samples,
                vad_filter=self._vad_filter,
                language_detection_segments=self._language_detection_segments,
            )
        except Exception as exc:  # noqa: BLE001 - detection is best-effort here
            _log.warning(
                "language detection failed (%s); falling back to unrestricted auto-detect", exc
            )
            return None

        if not all_language_probs:
            _log.warning(
                "language detection returned no probabilities; "
                "falling back to unrestricted auto-detect"
            )
            return None

        probs_by_language = dict(all_language_probs)
        candidates = [c for c in self._candidate_languages if c in probs_by_language]
        if not candidates:
            _log.warning(
                "none of the candidate languages %r appeared in detection probabilities "
                "(%r); falling back to unrestricted auto-detect",
                self._candidate_languages,
                sorted(probs_by_language),
            )
            return None

        chosen = max(candidates, key=lambda c: probs_by_language[c])
        top = sorted(all_language_probs, key=lambda pair: pair[1], reverse=True)
        top_str = ", ".join(f"{lang} {prob:.2f}" for lang, prob in top[:_LOG_TOP_N_LANGUAGES])
        _log.info(
            "language detect: chosen=%s p=%.2f (top: %s)",
            chosen,
            probs_by_language[chosen],
            top_str,
        )
        return chosen

    def unload(self) -> None:
        """Drop the loaded model, freeing its memory."""
        with self._lock:
            self._model = None
