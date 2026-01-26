#!/usr/bin/env python3
"""
Dua Talk - Offline dictation tool.

Uses Whisper for speech-to-text and copies transcription to clipboard.
Supports toggle mode and push-to-talk mode with configurable hotkeys.

macOS Menu Bar App version using rumps.
"""

import json
import os
import time
import threading
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import numpy as np
import whisper
import sounddevice as sd
import argparse
import rumps
from queue import Queue
from pynput import keyboard
from pynput.keyboard import Key, KeyCode, Controller


class ConfigManager:
    """Manages persistent configuration for Dua Talk."""

    CONFIG_DIR = Path.home() / "Library" / "Application Support" / "Dua Talk"
    CONFIG_FILE = CONFIG_DIR / "config.json"

    DEFAULT_CONFIG = {
        "version": 1,
        "hotkeys": {
            "toggle": {"modifiers": ["shift", "ctrl"], "key": None},
            "push_to_talk": {"modifiers": ["cmd", "shift"], "key": None}
        },
        "active_mode": "toggle",
        "history": [],
        "cleanup_enabled": False,
        "whisper_model": "base.en",
        "llm_model": "gemma3"
    }

    HISTORY_LIMIT = 5

    def __init__(self):
        self.config = self._load()

    def _load(self):
        """Load config from disk or create default."""
        try:
            if self.CONFIG_FILE.exists():
                with open(self.CONFIG_FILE, "r") as f:
                    config = json.load(f)
                # Merge with defaults for any missing keys
                for key, value in self.DEFAULT_CONFIG.items():
                    if key not in config:
                        config[key] = value
                return config
        except (json.JSONDecodeError, IOError):
            pass
        return self.DEFAULT_CONFIG.copy()

    def save(self):
        """Save config to disk."""
        try:
            self.CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            with open(self.CONFIG_FILE, "w") as f:
                json.dump(self.config, f, indent=2)
        except IOError as e:
            print(f"Failed to save config: {e}")

    def add_history_item(self, text):
        """Add a dictation to history (max 5 items)."""
        item = {
            "text": text,
            "timestamp": datetime.now().isoformat()
        }
        self.config["history"].insert(0, item)
        self.config["history"] = self.config["history"][:self.HISTORY_LIMIT]
        self.save()

    def get_history(self):
        """Get history items."""
        return self.config.get("history", [])

    def get_hotkey(self, mode):
        """Get hotkey config for a mode."""
        return self.config["hotkeys"].get(mode, self.DEFAULT_CONFIG["hotkeys"][mode])

    def set_hotkey(self, mode, modifiers, key=None):
        """Set hotkey for a mode."""
        self.config["hotkeys"][mode] = {"modifiers": modifiers, "key": key}
        self.save()

    def get_active_mode(self):
        """Get the active hotkey mode."""
        return self.config.get("active_mode", "toggle")

    def set_active_mode(self, mode):
        """Set the active hotkey mode."""
        self.config["active_mode"] = mode
        self.save()

    def get_cleanup_enabled(self):
        """Get cleanup enabled state."""
        return self.config.get("cleanup_enabled", False)

    def set_cleanup_enabled(self, enabled):
        """Set cleanup enabled state."""
        self.config["cleanup_enabled"] = enabled
        self.save()


class DuaTalkApp(rumps.App):
    """Dua Talk menu bar application."""

    # State icons (emoji fallback)
    ICON_IDLE = "🎤"
    ICON_RECORDING = "🔴"
    ICON_PROCESSING = "⏳"

    # Modifier key mappings for hotkey detection
    KEY_MAPPING = {
        "shift": [Key.shift, Key.shift_l, Key.shift_r],
        "ctrl": [Key.ctrl, Key.ctrl_l, Key.ctrl_r],
        "cmd": [Key.cmd, Key.cmd_l, Key.cmd_r],
        "alt": [Key.alt, Key.alt_l, Key.alt_r],
    }

    # Reverse mapping for display
    MODIFIER_NAMES = {
        Key.shift: "shift", Key.shift_l: "shift", Key.shift_r: "shift",
        Key.ctrl: "ctrl", Key.ctrl_l: "ctrl", Key.ctrl_r: "ctrl",
        Key.cmd: "cmd", Key.cmd_l: "cmd", Key.cmd_r: "cmd",
        Key.alt: "alt", Key.alt_l: "alt", Key.alt_r: "alt",
    }

    def __init__(self, whisper_model="base.en", cleanup=False, llm_model="gemma3"):
        super().__init__("Dua Talk", icon=None, title=self.ICON_IDLE, quit_button=None)

        # Load configuration
        self.config_manager = ConfigManager()

        # Configuration (CLI args override saved config)
        self.whisper_model_name = whisper_model
        self.cleanup_enabled = cleanup or self.config_manager.get_cleanup_enabled()
        self.llm_model = llm_model

        # Recording state
        self.recording = False
        self.stop_event = None
        self.recording_thread = None
        self.data_queue = None
        self.pressed_keys = set()
        self.hotkey_active = False  # For push-to-talk mode

        # Hotkey recording state
        self.recording_hotkey_for = None  # None, "toggle", or "push_to_talk"
        self.recorded_modifiers = set()
        self.recorded_key = None

        # Keyboard controller for auto-paste
        self.kb_controller = Controller()

        # Whisper model (loaded lazily)
        self.stt_model = None

        # Build menu
        self._build_menu()

        # Start keyboard listener for hotkey
        self.keyboard_listener = keyboard.Listener(
            on_press=self.on_press,
            on_release=self.on_release
        )
        self.keyboard_listener.start()

        # Load model in background
        threading.Thread(target=self.load_model, daemon=True).start()

    def _build_menu(self):
        """Build the complete menu structure."""
        # Main recording item
        self.record_menu_item = rumps.MenuItem(
            "Start Recording",
            callback=self.toggle_recording_menu
        )

        # History submenu
        self.history_menu = rumps.MenuItem("History")
        self._update_history_menu()

        # Cleanup toggle
        self.cleanup_menu_item = rumps.MenuItem(
            f"Cleanup: {'On' if self.cleanup_enabled else 'Off'}",
            callback=self.toggle_cleanup
        )

        # Settings submenu
        self.settings_menu = rumps.MenuItem("Settings")
        self._build_settings_menu()

        # Build main menu
        self.menu = [
            self.record_menu_item,
            None,  # Separator
            self.history_menu,
            None,  # Separator
            self.cleanup_menu_item,
            self.settings_menu,
            None,  # Separator
            rumps.MenuItem("Quit", callback=self.quit_app),
        ]

    def _build_settings_menu(self):
        """Build the settings submenu."""
        # Only clear if menu has been initialized
        if self.settings_menu._menu is not None:
            self.settings_menu.clear()

        active_mode = self.config_manager.get_active_mode()

        # Mode selection items
        self.toggle_mode_item = rumps.MenuItem(
            "Toggle Mode" + (" ✓" if active_mode == "toggle" else ""),
            callback=lambda _: self._set_mode("toggle")
        )
        self.ptt_mode_item = rumps.MenuItem(
            "Push-to-Talk Mode" + (" ✓" if active_mode == "push_to_talk" else ""),
            callback=lambda _: self._set_mode("push_to_talk")
        )

        # Hotkey display
        toggle_hotkey = self._format_hotkey(self.config_manager.get_hotkey("toggle"))
        ptt_hotkey = self._format_hotkey(self.config_manager.get_hotkey("push_to_talk"))

        self.set_toggle_hotkey_item = rumps.MenuItem(
            f"Set Toggle Hotkey... ({toggle_hotkey})",
            callback=lambda _: self._start_hotkey_recording("toggle")
        )
        self.set_ptt_hotkey_item = rumps.MenuItem(
            f"Set Push-to-Talk Hotkey... ({ptt_hotkey})",
            callback=lambda _: self._start_hotkey_recording("push_to_talk")
        )

        self.settings_menu.update([
            self.toggle_mode_item,
            self.ptt_mode_item,
            None,  # Separator
            self.set_toggle_hotkey_item,
            self.set_ptt_hotkey_item,
        ])

    def _format_hotkey(self, hotkey_config):
        """Format hotkey config for display."""
        parts = []
        for mod in hotkey_config.get("modifiers", []):
            if mod == "cmd":
                parts.append("⌘")
            elif mod == "shift":
                parts.append("⇧")
            elif mod == "ctrl":
                parts.append("⌃")
            elif mod == "alt":
                parts.append("⌥")
        if hotkey_config.get("key"):
            parts.append(hotkey_config["key"].upper())
        return "".join(parts) if parts else "None"

    def _set_mode(self, mode):
        """Set the active hotkey mode."""
        self.config_manager.set_active_mode(mode)
        self._build_settings_menu()
        rumps.notification("Dua Talk", "Mode Changed", f"Now using {mode.replace('_', ' ')} mode")

    def _start_hotkey_recording(self, mode):
        """Start recording a new hotkey."""
        self.recording_hotkey_for = mode
        self.recorded_modifiers = set()
        self.recorded_key = None
        rumps.notification(
            "Dua Talk",
            "Set Hotkey",
            f"Press your desired key combination for {mode.replace('_', ' ')}..."
        )

    def _finish_hotkey_recording(self):
        """Finish recording a hotkey and save it."""
        if not self.recorded_modifiers:
            rumps.notification("Dua Talk", "Invalid Hotkey", "At least one modifier key required")
            self.recording_hotkey_for = None
            return

        mode = self.recording_hotkey_for
        modifiers = list(self.recorded_modifiers)
        key = self.recorded_key

        self.config_manager.set_hotkey(mode, modifiers, key)
        self._build_settings_menu()

        hotkey_display = self._format_hotkey({"modifiers": modifiers, "key": key})
        rumps.notification(
            "Dua Talk",
            "Hotkey Set",
            f"{mode.replace('_', ' ').title()} hotkey set to {hotkey_display}"
        )
        self.recording_hotkey_for = None

    def _update_history_menu(self):
        """Update the history submenu with recent dictations."""
        # Only clear if menu has been initialized
        if self.history_menu._menu is not None:
            self.history_menu.clear()

        history = self.config_manager.get_history()
        if not history:
            self.history_menu.update([
                rumps.MenuItem("No history yet", callback=None)
            ])
            return

        items = []
        for item in history:
            text = item["text"]
            # Truncate for display
            display_text = text[:40] + "..." if len(text) > 40 else text
            # Replace newlines for menu display
            display_text = display_text.replace("\n", " ")
            menu_item = rumps.MenuItem(
                display_text,
                callback=self._make_history_callback(text)
            )
            items.append(menu_item)

        self.history_menu.update(items)

    def _make_history_callback(self, text):
        """Create a callback for a history item."""
        def callback(_):
            self._paste_text(text)
        return callback

    def _paste_text(self, text):
        """Paste text at cursor position, preserving clipboard."""
        # Save current clipboard
        try:
            result = subprocess.run(
                ["pbpaste"],
                capture_output=True,
                text=True,
                env={"LANG": "en_US.UTF-8"}
            )
            original_clipboard = result.stdout
        except Exception:
            original_clipboard = ""

        # Copy new text to clipboard
        self.copy_to_clipboard(text)
        time.sleep(0.05)

        # Simulate Cmd+V
        try:
            with self.kb_controller.pressed(Key.cmd):
                self.kb_controller.tap('v')
        except Exception as e:
            rumps.notification("Dua Talk", "Paste Failed", f"Could not simulate paste: {e}")
            return

        # Restore original clipboard after delay
        def restore_clipboard():
            time.sleep(0.2)
            self.copy_to_clipboard(original_clipboard)

        threading.Thread(target=restore_clipboard, daemon=True).start()

    def load_model(self):
        """Load Whisper model in background."""
        self.title = self.ICON_PROCESSING
        self.stt_model = whisper.load_model(self.whisper_model_name)
        self.title = self.ICON_IDLE

        mode = self.config_manager.get_active_mode()
        hotkey = self._format_hotkey(self.config_manager.get_hotkey(mode))
        rumps.notification(
            "Dua Talk",
            "Ready",
            f"Whisper model ({self.whisper_model_name}) loaded. Use {hotkey} to record."
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

    def _is_hotkey_pressed(self, hotkey_config):
        """Check if a hotkey combination is currently pressed."""
        # Check all required modifiers
        for mod in hotkey_config.get("modifiers", []):
            mod_keys = self.KEY_MAPPING.get(mod, [])
            if not any(k in self.pressed_keys for k in mod_keys):
                return False

        # Check optional regular key
        key = hotkey_config.get("key")
        if key:
            try:
                key_code = KeyCode.from_char(key.lower())
                if key_code not in self.pressed_keys:
                    return False
            except Exception:
                return False

        return True

    def on_press(self, key):
        """Handle key press events."""
        self.pressed_keys.add(key)

        # Handle hotkey recording mode
        if self.recording_hotkey_for:
            # Track modifiers
            if key in self.MODIFIER_NAMES:
                self.recorded_modifiers.add(self.MODIFIER_NAMES[key])
            elif isinstance(key, KeyCode) and key.char:
                # Regular key pressed - finish recording
                self.recorded_key = key.char
                self._finish_hotkey_recording()
            return

        # Normal hotkey handling
        active_mode = self.config_manager.get_active_mode()
        hotkey_config = self.config_manager.get_hotkey(active_mode)

        if self._is_hotkey_pressed(hotkey_config):
            if active_mode == "toggle":
                # Clear keys to prevent repeat triggers
                self.pressed_keys.clear()
                self.toggle_recording()
            elif active_mode == "push_to_talk":
                if not self.hotkey_active and not self.recording:
                    self.hotkey_active = True
                    self.start_recording()

    def on_release(self, key):
        """Handle key release events."""
        self.pressed_keys.discard(key)

        # Handle hotkey recording - finish on modifier release if no regular key
        if self.recording_hotkey_for:
            if key in self.MODIFIER_NAMES and self.recorded_modifiers:
                # Short delay to allow for regular key press
                threading.Timer(0.1, self._check_hotkey_recording_complete).start()
            return

        # Handle push-to-talk release
        active_mode = self.config_manager.get_active_mode()
        if active_mode == "push_to_talk" and self.hotkey_active:
            hotkey_config = self.config_manager.get_hotkey(active_mode)
            # Check if any modifier was released
            if key in self.MODIFIER_NAMES:
                mod_name = self.MODIFIER_NAMES[key]
                if mod_name in hotkey_config.get("modifiers", []):
                    self.hotkey_active = False
                    if self.recording:
                        self.stop_recording()

    def _check_hotkey_recording_complete(self):
        """Check if hotkey recording should complete (modifiers only)."""
        if self.recording_hotkey_for and self.recorded_modifiers and not self.recorded_key:
            # No regular key was pressed, save modifiers-only hotkey
            self._finish_hotkey_recording()

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
        self.title = self.ICON_IDLE

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
        """Output transcribed text - auto-paste and add to history."""
        # Add to history
        self.config_manager.add_history_item(text)
        self._update_history_menu()

        # Auto-paste at cursor
        self._paste_text(text)

        # Notify user
        preview = text[:50] + "..." if len(text) > 50 else text
        self.beep_off()
        rumps.notification("Dua Talk", "Pasted", preview)

    def toggle_cleanup(self, _):
        """Toggle LLM cleanup feature."""
        self.cleanup_enabled = not self.cleanup_enabled
        self.cleanup_menu_item.title = f"Cleanup: {'On' if self.cleanup_enabled else 'Off'}"
        self.config_manager.set_cleanup_enabled(self.cleanup_enabled)

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
