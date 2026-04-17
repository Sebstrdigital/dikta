# Feature: Windows Hotkey Recording Window (F-5)

**Epic:** [Dikta Windows v1.2 — MVP Reliability & Polish](epic-windows-v12-mvp-reliability.md)

## 1. Introduction/Overview

The current Settings window asks users to configure their dictation hotkey by selecting modifier checkboxes from a ListBox (multi-select) and picking a key from a ComboBox. This UX is geeky — non-tech users look at it and don't know what "modifiers" means. macOS has a better pattern: a dialog that says "Press your hotkey" and captures the actual key press. This Feature ports that pattern to Windows. It also blocks OS-reserved combinations and tests registration before saving, so users cannot bind a combo that silently fails.

## 2. Goals

- Users bind their dictation hotkey by pressing the key combo, not by reading checkboxes
- OS-reserved combinations (Win+L, Win+D, Ctrl+Alt+Del, Win+Tab) are rejected with a readable message
- Registration is verified before save; a bound combo that fails `RegisterHotKey` surfaces a message rather than silently saving and breaking

## 3. User Stories

### US-001: Press-to-bind hotkey dialog

**Description:** As a user, I want to bind my dictation hotkey by pressing the keys I want to use so that I don't have to understand modifiers and virtual keys.

**Acceptance Criteria:**
- [ ] The Settings window has a "Change hotkey…" button that opens a `HotkeyRecordingWindow`
- [ ] The recording window shows "Press your hotkey combination…" and a live preview of the captured combo
- [ ] Pressing a valid combination (one or more modifiers + one key) enables the "OK" button and displays the combo as "Ctrl + Shift + D"
- [ ] Pressing Escape cancels without changes

### US-002: Reject OS-reserved combinations

**Description:** As a user, I want Dikta to prevent me from binding a combo that Windows has reserved so that I don't trip a system shortcut instead of triggering dictation.

**Acceptance Criteria:**
- [ ] Attempting to bind Win+L, Win+D, Ctrl+Alt+Del, Win+Tab, or Ctrl+Esc shows a readable warning in the recording window
- [ ] The OK button remains disabled while a reserved combo is displayed
- [ ] The user can press a different combo to replace it

### US-003: Pre-save registration test

**Description:** As a user, I want Dikta to confirm my new hotkey works before saving so that I don't find out at the next recording that it silently broke.

**Acceptance Criteria:**
- [ ] Clicking OK in the recording window temporarily registers the new combo via `HotkeyManager.ReregisterHotkey`
- [ ] If registration fails, a message "This combination is in use by another app. Choose a different one." appears in the window; the old binding is preserved
- [ ] If registration succeeds, the Settings window reflects the new binding and Save persists it

### US-004: Integration with SettingsWindow

**Description:** As a user, I want the new dialog to replace the old modifier list so that I have one clear way to change my hotkey.

**Acceptance Criteria:**
- [ ] The SettingsWindow's ListBox + ComboBox hotkey controls are removed
- [ ] A read-only display of the current hotkey plus a "Change hotkey…" button replaces them
- [ ] Saving Settings with no change to the hotkey leaves the binding untouched

## 4. Functional Requirements

- FR-1: `HotkeyRecordingWindow.xaml` displays: a heading, a live preview label showing the captured combo, a status line (validation messages), and OK/Cancel buttons.
- FR-2: The window subscribes to `PreviewKeyDown`. On each key event it reads `Keyboard.Modifiers` plus `e.Key` (filtering out modifier-only events) and updates the preview.
- FR-3: The window requires at least one modifier (Ctrl, Shift, Alt, Win) and exactly one non-modifier key before OK is enabled.
- FR-4: A blocklist method checks the combo against reserved values: `(Win, L)`, `(Win, D)`, `(Win, Tab)`, `(Ctrl, Esc)`, `(Ctrl+Alt, Delete)`. Reserved = OK disabled + status message.
- FR-5: On OK, call `HotkeyManager.ReregisterHotkey(modifierString, keyString)`. If the call throws `InvalidOperationException`, show the exception message in the status line and keep the window open.
- FR-6: On successful re-register + OK, write the combo back to the SettingsWindow fields (which Save persists to `AppConfig`).
- FR-7: The SettingsWindow hotkey section is replaced by: a read-only `TextBlock` showing the current binding formatted as "Ctrl + Shift + D" and a "Change hotkey…" `Button`.

## 5. Non-Goals (Out of Scope)

- Multi-key chord hotkeys (e.g., Ctrl+K then D) — out of scope
- Hotkey profiles / multiple simultaneous bindings — out of scope
- Modifier-only hotkeys (push-to-talk) — explicitly out of scope per epic
- Media key bindings
- Visual illustration of key positions on a virtual keyboard
- Custom keyboard layout rebinding

## 6. Design Considerations

- **Focus behavior:** The recording window should grab and hold keyboard focus from the moment it opens. `PreviewKeyDown` on the window root captures keys before any child control handles them.
- **Escape as cancel:** Pressing Escape alone cancels. Escape + any modifier is treated as binding the combo (user may want `Ctrl+Escape`). Since `Ctrl+Esc` is blocklisted, the ambiguity resolves cleanly.
- **Visual feedback:** When a key combo becomes valid, the preview label brightens or changes color. When blocklisted, it greys out with a red status message.

## 7. Technical Considerations

- **WPF `Keyboard.Modifiers`:** Returns a bitmask of `ModifierKeys.Control | Shift | Alt | Windows`. Map to the same string format the existing `HotkeyManager.ParseModifiers` accepts ("Ctrl+Shift").
- **Windows key capture:** The Windows key fires as `Key.LWin` or `Key.RWin`. These arrive as `Key.System` on some layouts — handle both. Note the Win key is blocked in WPF unless `SystemKey` is checked.
- **Pre-save registration atomicity:** Calling `ReregisterHotkey` and then rolling back on Save-cancel is tricky. Simpler: require OK to commit the new binding (Cancel leaves the old in place). Save in SettingsWindow then persists to `AppConfig`.
- **Thread safety:** All UI work stays on the Dispatcher thread. No async operations needed in this Feature.

## 8. Success Metrics

- Tester can bind Ctrl+Shift+D without opening the old modifier list
- Tester successfully rebinds to Ctrl+Alt+Space and returns to Ctrl+Shift+D
- Attempting to bind Win+L surfaces the blocklist message; OK stays disabled
- Attempting to bind a combo held by another app surfaces the registration failure message

## 9. Open Questions

1. **Should modifier-only combos be allowed temporarily (for the push-to-talk future)?** — Out of scope for v1.2, but the dialog structure could accommodate it. Recommend: reject now, revisit in a future iteration.
2. **Should the recording window auto-close on valid binding?** — Auto-close risks accidental binds from stray key presses. Recommend: require explicit OK click.
3. **`AltGr` on non-US layouts** — AltGr = Ctrl+Alt on Windows, so a user pressing AltGr+D actually generates Ctrl+Alt+D. Document as a known edge case; non-US support is already a known limitation (F-2).
