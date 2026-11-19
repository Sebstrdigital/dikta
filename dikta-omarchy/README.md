# Dikta for Omarchy

Offline dictation for Omarchy/Hyprland, using Parakeet Ultra on the CPU. See [FEATURES.md](FEATURES.md) for implemented and planned features.

## Install

Requires Qt 6 development tools (`qmake6`, Qt Quick, Quick Controls, and Multimedia), a C++ compiler, make, ffmpeg with PulseAudio support, `wl-copy`, `wtype`, `hyprctl`, `curl`, `sha256sum`, and `uv`. From this directory, run `bin/install` to build and install for the current user. It downloads about 670 MB of model files and verifies their SHA-256 hashes. Keep this source directory in place: the installed launchers and Omarchy panel point into it. If you move it, run `bin/install` again from the new location.

Add an Omarchy Hyprland binding for `dikta --toggle` (for example Alt+Space), then reload Hyprland. To enable changing it in Dikta, have the binding file load `~/.config/dikta/shortcuts.lua` when present and use the default binding otherwise. Dikta starts in the background at login.

On Omarchy, enable its native bar panel with `omarchy plugin enable dikta.panel --section right`. The microphone opens a theme-matched panel with history, hotkey settings, notifications, and About. Use the shortcut to start or stop dictation. Hide the separate Dikta system-tray item to avoid a duplicate icon. Notifications are off by default. Closing the window leaves the app running; Ctrl+Q quits it. A shortcut toggle starts it again if necessary.

## Use

Focus the target application, start dictation with the shortcut, speak, and press it again to stop. Dikta plays a rising tone when recording starts and a falling tone after recording stops. The recording is transcribed locally and the text is pasted into the same focused window. If focus changes, Dikta copies the transcript instead of pasting into a different window. The last five transcripts are saved in `~/.local/share/dikta/history.json`; recordings are temporary. Copying a history item replaces the clipboard. Text fields and terminals use their usual paste shortcuts.

Sound cues use the system's default audio output. If they are inaudible, check the selected output and its volume in Omarchy's audio menu.

Dictation uses the system default microphone. Parakeet Ultra automatically detects its supported European languages. The Linux model is an int8 conversion of the same Ultra weights used by the macOS app; it may produce different results. Long recordings are split near quiet portions for inference. Dikta starts a transcription worker and loads the model when the app starts, keeping it loaded until the app quits. A dictation stopped before the model is ready waits for it to load.

## Timing diagnostics

Each finished dictation appends one JSON object to `$XDG_STATE_HOME/dikta/timings.jsonl`, or `~/.local/state/dikta/timings.jsonl` when `XDG_STATE_HOME` is unset or not absolute. The file is created with owner-only permissions. Logging is best effort: an unavailable state directory or log does not interrupt dictation. Delete the file whenever you no longer need it; it is not automatically rotated.

Records contain a UTC timestamp, an outcome (`pasted`, `copied_no_paste`, `no_speech`, or `failed`), and, for failures, a `failure_stage`. Available durations are milliseconds: `recording_ms` (ffmpeg process start to stop request), `stop_to_audio_ready_ms` (stop request to successful ffmpeg exit), `model_init_ms`, `decode_ms` (including chunk preparation), `copy_ms`, `paste_ms`, and `stop_to_finish_ms`. `stop_to_paste_ms` appears only when the paste command succeeds; it measures through that command's completion, not confirmation by the target application. Missing fields indicate stages that were not reached or could not report timing. A stop requested before ffmpeg starts has a recording duration of zero. A warm worker reports zero model initialization time for a dictation; if the model is still loading when dictation stops, the stop-to-finish and stop-to-paste durations include the wait.

The log contains no transcript, audio, window identifier, or error text. It does reveal when dictations occurred, their durations, and their outcomes. Existing transcript history is separate and is not affected by this log.

## Model attribution

Parakeet Ultra is a post-training of NVIDIA's Parakeet TDT 0.6B v3 by Moondream. Dikta uses Plotdesk's ONNX conversion and int8 quantization of that model, with the original VAD head removed. The model and conversion are licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/): [NVIDIA model](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [Moondream Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra), [Plotdesk conversion and license](https://github.com/plotdesk/parakeet-ultra-sherpa-onnx). Inference uses [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), licensed under Apache 2.0.
