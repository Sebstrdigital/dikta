# Feature: Windows Clipboard & Hotkey Polish (F-2)

**Epic:** [Dikta Windows v1.2 — MVP Reliability & Polish](epic-windows-v12-mvp-reliability.md)

## 1. Introduction/Overview

The current `ClipboardManager` uses `VK_CONTROL` + virtual-key-only `SendInput` plus a fixed 50 ms delay. This pattern fails in resource-intensive apps (Outlook, Teams, some browsers) where the clipboard is still busy when the paste fires. The hotkey parser in `HotkeyManager` only accepts alphanumeric single-character keys — users cannot bind F-keys, arrows, or punctuation. The `_processing` flag in `TrayIconManager` is a non-volatile bool that is read and written from async continuations. This Feature hardens these small but high-impact spots for broader app compatibility.

## 2. Goals

- Auto-paste works reliably in Notepad, browsers, Microsoft 365, Teams, and other common targets
- Users can bind F-keys, arrow keys, and punctuation as the dictation hotkey
- The recording state machine cannot be confused by a rapid hotkey double-press

## 3. User Stories

### US-001: Reliable SendInput paste

**Description:** As a user, I want dictated text to paste correctly into any app I'm typing in so that the tool works the same way everywhere.

**Acceptance Criteria:**
- [ ] `ClipboardManager` uses `VK_LCONTROL` (not generic `VK_CONTROL`) + scan codes populated via `MapVirtualKey(_, MAPVK_VK_TO_VSC)` and the `KEYEVENTF_SCANCODE` flag
- [ ] A dictated phrase pastes correctly into Outlook / Teams / browser address bars on the tester machine
- [ ] Paste still works in Notepad and TextEdit-equivalent plain text apps

### US-002: Clipboard-idle wait replaces fixed 50 ms delay

**Description:** As a user, I want the paste to wait until the clipboard is ready so that my first dictation does not drop into a clipboard race on slow apps.

**Acceptance Criteria:**
- [ ] The paste waits until `GetOpenClipboardWindow()` returns `IntPtr.Zero` or a 500 ms ceiling elapses, whichever comes first
- [ ] The 50 ms `Task.Delay` is removed
- [ ] The paste still fires within 500 ms even if the clipboard never becomes idle (so the user never sees an infinite hang)

### US-003: Hotkey parser accepts F-keys, arrows, punctuation

**Description:** As a user, I want to bind my dictation hotkey to whatever key combo works on my keyboard so that I can avoid conflicts with other apps.

**Acceptance Criteria:**
- [ ] `HotkeyManager.ParseKey` returns valid VKs for F1–F12, arrow keys, Home/End/PgUp/PgDn, Insert/Delete, and common punctuation
- [ ] Attempting to bind an unsupported key surfaces a readable error, not a silent failure
- [ ] Existing alphanumeric bindings continue to work unchanged

### US-004: Thread-safe processing flag

**Description:** As a user, I want a rapid double-tap of the hotkey to behave predictably so that the app does not get stuck in "processing" forever.

**Acceptance Criteria:**
- [ ] The `_processing` flag in `TrayIconManager` uses `Interlocked.CompareExchange` for the start/end guard
- [ ] Two hotkey presses within 100 ms do not both enter the transcription path
- [ ] The recording state returns to idle after the transcription completes, even under concurrent hotkey presses

## 4. Functional Requirements

- FR-1: `ClipboardManager.CopyAndPasteAsync` must use `VK_LCONTROL` (0xA2) with `wScan = MapVirtualKey(VK_LCONTROL, MAPVK_VK_TO_VSC)` and set `dwFlags |= KEYEVENTF_SCANCODE` on all four `INPUT` structs.
- FR-2: Before calling `SendInput`, poll `GetOpenClipboardWindow()` every 10 ms up to a 500 ms ceiling; proceed as soon as it returns `IntPtr.Zero`.
- FR-3: `HotkeyManager.ParseKey` must recognize these key name strings (case-insensitive): `F1`–`F12`, `Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PageUp`, `PageDown`, `Insert`, `Delete`, `Tab`, `Space`, `Enter`, `Backspace`, and ASCII punctuation `. , ; ' [ ] - = / \`.
- FR-4: `TrayIconManager.OnHotkeyPressed` must gate the recording-start path with `Interlocked.CompareExchange(ref _processing, 1, 0) == 0` (using `int`, not `bool`).

## 5. Non-Goals (Out of Scope)

- Multi-key chord hotkeys (e.g., Ctrl+K then D)
- Media keys (Play, Pause, Stop, Volume)
- Support for non-US keyboard layouts where the reported VK differs from the QWERTY expectation — document as a known limitation
- Localized key display names in Settings (English only)

## 6. Design Considerations

- **Clipboard-idle poll:** 10 ms poll interval is chosen so the total added latency on a fast machine is under 20 ms, while the ceiling protects against a stuck clipboard owner.
- **Scan code fallback:** If `MapVirtualKey` returns 0 (rare — unmapped key), fall back to virtual-key-only path so paste does not break entirely.

## 7. Technical Considerations

- **`VK_LCONTROL` vs `VK_CONTROL`:** Some RDP sessions, older Citrix clients, and a handful of games expect explicit left-Ctrl in keyboard simulation. Using `VK_LCONTROL` costs nothing and improves compatibility.
- **Scan codes + `KEYEVENTF_SCANCODE`:** Ensures Windows dispatches the event through the normal keyboard input path rather than the virtual-key shortcut path; improves compat with games and full-screen apps.
- **`Interlocked.CompareExchange` on bool:** C# does not support `Interlocked` on `bool` — use `int` with 0/1 values. Rename the field to `_processingFlag` or wrap in a helper.

## 8. Success Metrics

- Paste works in 5/5 tester-verified apps (Notepad, Edge address bar, Outlook, Teams chat, VS Code)
- All 4 new hotkey categories (F-keys, arrows, nav cluster, punctuation) bindable and functional
- No "stuck in processing" reports from tester

## 9. Open Questions

1. **500 ms clipboard-idle ceiling** — is this the right value? Too high feels laggy; too low risks racing. 500 ms is my first guess; tester feedback may tune it.
2. **MAPVK_VK_TO_VSC layout-dependent behavior** — `MapVirtualKey` without an explicit HKL uses the active layout. On non-US layouts this could return different scan codes. Document as a known limitation for v1.2; consider `MapVirtualKeyEx(_, _, GetKeyboardLayout(0))` in a future iteration.
