# Phase 4 — Integration

**Goal:** Wire the formatter engine into Dikta with a format hotkey, style cycling, auto-format option, and menu bar indicator.

**Depends on:** Phase 1, 2, and 3 must be working and tested.

**When done:** User can select text in any app, press a hotkey, and get formatted text. Style is shown in the menu bar and applies to both manual formatting and (optionally) auto-formatting after dictation.

---

## Key Decisions

- **One active style** — Off / Message / Structure. Applies to both hotkey formatting and auto-format.
- **No style picker HUD** — the hotkey applies whatever style is active. No second keypress.
- **All hotkeys configurable** — no hardcoded hotkeys. Defaults provided, editable in Hotkeys menu.
- **Menu bar indicator** — active style shown to the left of the app icon. Off = no indicator. Message = `M`. Structure = `S`.
- **Auto-format** — optional toggle in menu bar. When on, the active style is applied to dictation output before paste.

---

## Progress

- [ ] TODO 1: Read selected text via pasteboard
- [ ] TODO 2: Register formatting hotkey (configurable)
- [ ] TODO 3: Register style-cycle hotkey (configurable)
- [ ] TODO 4: Menu bar indicator (left of icon)
- [ ] TODO 5: Auto-format toggle (post-dictation)
- [ ] TODO 6: Edge cases (empty selection, short text, already formatted)
- [ ] TODO 7: Add to Dikta's menu bar
- [ ] TODO 8: Manual testing in Mail, Notes, Slack

---

## TODO 1: Read the selected text

The user selects text in another app (Mail, Slack, Notes, whatever). Dikta needs to grab that text.

### The approach

Dikta already uses the pasteboard for pasting transcriptions. Same technique:

1. Simulate `Cmd+C` to copy the selected text to the system pasteboard
2. Read the pasteboard contents
3. Format it using the active style
4. Write the result back to the pasteboard
5. Simulate `Cmd+V` to paste the formatted text back

This replaces the selection with the formatted version. The target app's undo (Cmd+Z) should revert it since it's just a paste operation.

### Things to watch out for

- **Timing:** After simulating Cmd+C, you need a tiny delay before reading the pasteboard (the system needs time to process). Dikta already handles this for transcription paste — reuse that approach.
- **Permissions:** This requires Accessibility permissions (same as the dictation hotkey). Dikta already has this.
- **Pasteboard types:** Read the pasteboard as plain text (`NSPasteboard.PasteboardType.string`). Don't try to preserve rich text formatting — the formatter works on plain text.
- **Empty selection:** If the user hits the hotkey with nothing selected, the pasteboard won't change. Detect this (compare pasteboard contents before and after Cmd+C, or check if pasteboard is empty) and show a brief notification: "No text selected."
- **Style is Off:** If the active style is Off, the hotkey should do nothing (or show a brief notification: "No format style active").

---

## TODO 2: Register the formatting hotkey

### Default hotkey

**Cmd+Shift+F** — common "format" association. Configurable by the user.

### Implementation

Follow the same pattern as the dictation hotkey:
1. Registered at app startup
2. Configurable in the Hotkeys menu (same as record, push-to-talk, read aloud, language toggle)
3. Works globally (when Dikta is in the background)
4. Collision detection with other Dikta hotkeys

When pressed:
1. If active style is Off → do nothing (or brief notification)
2. Otherwise → execute the copy-format-paste flow from TODO 1

---

## TODO 3: Register the style-cycle hotkey

A second configurable hotkey that cycles through: **Off → Message → Structure → Off**

### Default hotkey

Pick a sensible default (e.g., `Cmd+Shift+G` or `Ctrl+Shift+F`). Must not collide with the format hotkey or other Dikta hotkeys.

### Implementation

Same registration pattern as the other hotkeys. When pressed:
1. Cycle to the next style
2. Update the menu bar indicator
3. Persist the choice to config (so it survives restart)
4. Optionally show a brief notification: "Format: Message" / "Format: Structure" / "Format: Off"

---

## TODO 4: Menu bar indicator

Show the active format style to the **left** of the Dikta icon in the menu bar.

### Display

| Active style | Indicator | Menu bar appearance |
|-------------|-----------|-------------------|
| Off | (nothing) | `[icon] EN` |
| Message | `M` | `M [icon] EN` |
| Structure | `S` | `S [icon] EN` |

### Implementation

Update the menu bar status item to include the format indicator. Follow the same approach used for the language indicator on the right side. The indicator should update when:
- The user cycles styles via hotkey (TODO 3)
- The user changes style via the menu (TODO 7)
- The app launches (read persisted style from config)

---

## TODO 5: Auto-format toggle

When enabled, the active format style is automatically applied to dictation output before it's pasted.

### Menu bar option

Add a toggle in the menu: **"Auto-format dictation"** with a checkmark when enabled.

This is a simple on/off toggle — the style it uses is whatever is currently active (M or S). If the active style is Off, auto-format has no effect regardless of the toggle.

### Implementation

1. Add a boolean config option: `autoFormatDictation` (default: `false`)
2. In the dictation pipeline, after transcription and before paste: if auto-format is on and style is not Off, run the formatter
3. Persist the toggle to config

---

## TODO 6: Handle edge cases

### Nothing selected
If the pasteboard is empty or unchanged after Cmd+C → show "No text selected" notification and cancel.

### Style is Off
If the user presses the format hotkey with style set to Off → do nothing or show "No format style active."

### Very short text
If the text is 1-2 words → return unchanged and optionally show "Text too short to format."

### Already formatted text
Phase 3 already handles this (returns unchanged if bullets/numbers detected). Phase 2 should also check — if text already has blank lines between paragraphs, don't add more.

### Formatting takes noticeable time
It shouldn't — these are string operations, should be instant. But if somehow it does, consider running the format on a background thread and showing a brief spinner. Probably not needed.

---

## TODO 7: Add to Dikta's menu

Add formatting options to the Dikta menu bar. This provides discoverability and an alternative to hotkeys.

```
Dikta
├── Stop Recording / Stop Speaking / Processing...
├── History >
├── Hotkeys >
│   ├── Set Record Hotkey...
│   ├── Set Push-to-Talk Hotkey...
│   ├── Set Read Aloud Hotkey...
│   ├── Set Language Toggle Hotkey...
│   ├── Set Format Hotkey...
│   └── Set Format Cycle Hotkey...
├── Audio >
│   ├── Mute Sounds
│   ├── Mute Notifications
│   └── Mic Distance: Close / Normal / Far
├── Format >
│   ├── ✓ Off
│   ├── Message
│   ├── Structure
│   └── ─────────────
│   └── Auto-format dictation
├── Write in: (language) >
│   ├── English
│   ├── Svenska
│   └── ...
├── Advanced >
│   ├── Whisper Model: Small / Medium
│   └── Voice: (Kokoro voices)
├── About
└── Quit
```

---

## TODO 8: Test the full flow manually

### Test scenario 1: Format email in Mail.app
1. Open Mail, compose new email
2. Dictate a message using Dikta
3. Select the dictated text
4. Set style to Message (via cycle hotkey or menu)
5. Press format hotkey
6. Verify: greeting separated, paragraphs added, sign-off on its own line

### Test scenario 2: Format bullet list in Notes.app
1. Open Notes, create new note
2. Dictate a list of items
3. Select the text
4. Set style to Structure
5. Press format hotkey
6. Verify: items converted to bullets

### Test scenario 3: Style cycling
1. Press style-cycle hotkey repeatedly
2. Verify menu bar indicator changes: (nothing) → M → S → (nothing)
3. Verify the change persists after Dikta restart

### Test scenario 4: Auto-format dictation
1. Set style to Message, enable "Auto-format dictation"
2. Dictate a message
3. Verify: the pasted text is already formatted as a message (no manual select+hotkey needed)

### Test scenario 5: Nothing selected
1. In any app, don't select anything
2. Press format hotkey
3. Verify: "No text selected" notification, nothing changes

### Test scenario 6: Style is Off
1. Cycle style to Off
2. Press format hotkey
3. Verify: nothing happens

### Test scenario 7: Already formatted
1. Select text that already has bullet points
2. Set style to Structure, press format hotkey
3. Verify: text unchanged

### Test scenario 8: Undo
1. Dictate and format text
2. Press Cmd+Z
3. Verify: original unformatted text is restored

### Test scenario 9: Slack message
1. Open Slack, dictate and format as Message
2. Verify: properly structured

---

## Done checklist

- [ ] Formatting hotkey registered, configurable, works globally
- [ ] Style-cycle hotkey registered, configurable, works globally
- [ ] Format style persisted to config
- [ ] Menu bar shows format indicator left of icon (M/S/nothing)
- [ ] Copy-format-paste flow works for selected text
- [ ] Auto-format toggle in menu, applies to dictation output
- [ ] "No text selected" and "Style is Off" cases handled
- [ ] Menu bar shows Format submenu with Off/Message/Structure + auto-format toggle
- [ ] Hotkeys menu includes Set Format Hotkey and Set Format Cycle Hotkey
- [ ] Full flow works in Mail.app
- [ ] Full flow works in Notes.app
- [ ] Full flow works in Slack
- [ ] Undo (Cmd+Z) works in the target app
- [ ] Already-formatted text is returned unchanged
- [ ] Style survives app restart

---

## Future ideas (not for now)

- **Auto mode per style:** Different auto-format style than the manual style
- **Custom styles:** Let users define their own formatting rules
- **Markdown toggle:** Output markdown or plain text depending on target app
- **Preview:** Show a preview of the formatted text before applying
- **History:** Keep last 5 formatted texts, allow re-applying different style
