#!/usr/bin/env python3
"""
Dua Talk - Offline dictation tool.

Uses Whisper for speech-to-text and copies transcription to clipboard.
Toggle recording with Left Shift + Left Control or via menu bar.

macOS Menu Bar App version using rumps.
"""

import time
import threading
import subprocess
import sys
import os
import numpy as np
import whisper
import sounddevice as sd
import argparse
import rumps
from queue import Queue
from pynput import keyboard


def get_resource_path(filename):
    """Get path to resource file, works both in dev and bundled app."""
    # When running as bundled app
    if getattr(sys, 'frozen', False):
        return os.path.join(os.path.dirname(sys.executable), '..', 'Resources', filename)
    # When running in development
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), filename)


class DuaTalkApp(rumps.App):
    """Dua Talk menu bar application."""

    # State indicators (used as title when recording/processing)
    ICON_RECORDING = "REC"
    ICON_PROCESSING = "..."

    def __init__(self, whisper_model="base.en", cleanup=False, llm_model="gemma3"):
        # Get icon path
        icon_path = get_resource_path('menubar_icon.png')
        if not os.path.exists(icon_path):
            icon_path = None

        super().__init__("Dua Talk", icon=icon_path, title=None, quit_button=None)

        # Configuration
        self.whisper_model_name = whisper_model
        self.cleanup_enabled = cleanup
        self.llm_model = llm_model

        # Recording state
        self.recording = False
        self.stop_event = None
        self.recording_thread = None
        self.data_queue = None
        self.pressed_keys = set()

        # Whisper model (loaded lazily)
        self.stt_model = None

        # Build menu items (store references for later updates)
        self.record_menu_item = rumps.MenuItem(
            "Start Recording",
            callback=self.toggle_recording_menu
        )
        self.cleanup_menu_item = rumps.MenuItem(
            f"Cleanup: {'On' if self.cleanup_enabled else 'Off'}",
            callback=self.toggle_cleanup
        )
        self.menu = [
            self.record_menu_item,
            None,  # Separator
            self.cleanup_menu_item,
            None,  # Separator
            rumps.MenuItem("Quit", callback=self.quit_app),
        ]

        # Start keyboard listener for hotkey
        self.keyboard_listener = keyboard.Listener(
            on_press=self.on_press,
            on_release=self.on_release
        )
        self.keyboard_listener.start()

        # Load model in background
        threading.Thread(target=self.load_model, daemon=True).start()

    def load_model(self):
        """Load Whisper model in background."""
        self.title = self.ICON_PROCESSING
        self.stt_model = whisper.load_model(self.whisper_model_name)
        self.title = None  # Show icon only
        rumps.notification(
            "Dua Talk",
            "Ready",
            f"Whisper model ({self.whisper_model_name}) loaded. Use Shift+Ctrl to record."
        )

    def beep(self, frequency=440, duration=0.1):
        """Generate a simple beep using numpy + sounddevice."""
        sample_rate = 44100
        t = np.linspace(0, duration, int(sample_rate * duration), False)
        wave = 0.2 * np.sin(2 * np.pi * frequency * t)
        sd.play(wave.astype(np.float32), sample_rate)
        sd.wait()

    def beep_on(self):
        """Subtle tone when recording starts."""
        self.beep(frequency=350, duration=0.12)

    def beep_off(self):
        """Subtle tone when recording stops/ready."""
        self.beep(frequency=280, duration=0.12)

    def on_press(self, key):
        """Handle key press events."""
        self.pressed_keys.add(key)

        # Check for Shift + Ctrl combination
        shift_pressed = (
            keyboard.Key.shift in self.pressed_keys or
            keyboard.Key.shift_l in self.pressed_keys or
            keyboard.Key.shift_r in self.pressed_keys
        )
        ctrl_pressed = (
            keyboard.Key.ctrl in self.pressed_keys or
            keyboard.Key.ctrl_l in self.pressed_keys or
            keyboard.Key.ctrl_r in self.pressed_keys
        )

        if shift_pressed and ctrl_pressed:
            # Clear the keys to prevent repeat triggers
            self.pressed_keys.clear()
            self.toggle_recording()

    def on_release(self, key):
        """Handle key release events."""
        self.pressed_keys.discard(key)

    def toggle_recording_menu(self, sender):
        """Menu callback for toggle recording."""
        self.toggle_recording()

    def toggle_recording(self):
        """Toggle recording state."""
        if self.stt_model is None:
            rumps.notification("Dua Talk", "Not Ready", "Whisper model still loading...")
            return

        if not self.recording:
            self.start_recording()
        else:
            self.stop_recording()

    def start_recording(self):
        """Start audio recording."""
        self.data_queue = Queue()
        self.stop_event = threading.Event()
        self.recording_thread = threading.Thread(
            target=self.record_audio,
            args=(self.stop_event, self.data_queue),
        )
        self.recording_thread.start()
        self.recording = True

        # Update UI
        self.title = self.ICON_RECORDING
        self.record_menu_item.title = "Stop Recording"
        self.beep_on()

    def stop_recording(self):
        """Stop recording and process audio."""
        self.stop_event.set()
        self.recording_thread.join()
        self.recording = False

        # Update UI
        self.title = self.ICON_PROCESSING
        self.record_menu_item.title = "Start Recording"

        # Process in background thread
        threading.Thread(target=self.process_audio, daemon=True).start()

    def record_audio(self, stop_event, data_queue):
        """Captures audio data from the user's microphone."""
        def callback(indata, frames, time_info, status):
            data_queue.put(bytes(indata))

        with sd.RawInputStream(
            samplerate=16000, dtype="int16", channels=1, callback=callback
        ):
            while not stop_event.is_set():
                time.sleep(0.1)

    def process_audio(self):
        """Process recorded audio and copy to clipboard."""
        # Gather audio data
        audio_data = b"".join(list(self.data_queue.queue))
        audio_np = (
            np.frombuffer(audio_data, dtype=np.int16).astype(np.float32) / 32768.0
        )

        if audio_np.size > 0:
            # Transcribe
            text = self.transcribe(audio_np)

            if text:
                # Optional LLM cleanup
                if self.cleanup_enabled:
                    text = self.cleanup_with_llm(text)

                self.output_text(text)
            else:
                rumps.notification("Dua Talk", "No Speech", "No speech detected in recording.")
        else:
            rumps.notification("Dua Talk", "Error", "No audio recorded. Check microphone.")

        # Reset UI
        self.title = None  # Show icon only

    def transcribe(self, audio_np):
        """Transcribe audio using Whisper."""
        result = self.stt_model.transcribe(audio_np, fp16=False)
        return result["text"].strip()

    def cleanup_with_llm(self, text):
        """Use Ollama to clean up transcription."""
        try:
            import ollama
            prompt = (
                "Clean up this dictation. Remove filler words (um, uh, like, you know), "
                "fix punctuation and capitalization. Output ONLY the cleaned text, nothing else:\n\n"
                f"{text}"
            )
            response = ollama.generate(model=self.llm_model, prompt=prompt)
            return response['response'].strip()
        except Exception:
            return text

    def copy_to_clipboard(self, text):
        """Copy text to system clipboard."""
        if sys.platform == "darwin":
            process = subprocess.Popen(
                ["pbcopy"],
                stdin=subprocess.PIPE,
                env={"LANG": "en_US.UTF-8"}
            )
            process.communicate(text.encode("utf-8"))
        else:
            import pyperclip
            pyperclip.copy(text)

    def output_text(self, text):
        """Copy text to clipboard."""
        preview = text[:50] + "..." if len(text) > 50 else text
        self.copy_to_clipboard(text)
        self.beep_off()
        rumps.notification("Dua Talk", "Ready", f"{preview} (Cmd+V)")

    def toggle_cleanup(self, _):
        """Toggle LLM cleanup feature."""
        self.cleanup_enabled = not self.cleanup_enabled
        self.cleanup_menu_item.title = f"Cleanup: {'On' if self.cleanup_enabled else 'Off'}"

    def quit_app(self, _):
        """Quit the application."""
        self.keyboard_listener.stop()
        rumps.quit_application()


def main():
    # Parse command line arguments
    parser = argparse.ArgumentParser(description="Dua Talk - Offline Dictation")
    parser.add_argument("--cleanup", action="store_true", help="Enable LLM cleanup by default")
    parser.add_argument("--model", default="gemma3", help="Ollama model for cleanup (default: gemma3)")
    parser.add_argument("--whisper-model", default="base.en", help="Whisper model size (default: base.en)")
    args = parser.parse_args()

    app = DuaTalkApp(
        whisper_model=args.whisper_model,
        cleanup=args.cleanup,
        llm_model=args.model
    )
    app.run()


if __name__ == "__main__":
    main()
