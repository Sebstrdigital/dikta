# Active Alerts

| Status | Alert | First Seen | Last Seen |
|--------|-------|------------|-----------|
| potential | Workers unable to commit (Bash denied at end of execution) | 2026-02-20 | 2026-02-20 |

---

## Retro: 2026-02-20 — takt/v02-dual-hotkeys-and-audio-reliability

### What Went Well
- **Clean dependency chain**: US-001 and US-002 were independent, US-003/US-004 depended on them respectively — no blocking or skipping needed. All 4 stories completed first attempt.
- **Existing pattern reuse** (US-001): The TTS hotkey already demonstrated concurrent hotkey handling in HotkeyManager. Workers followed the same pattern for dual dictation hotkeys — minimal invention required.
- **Focused scope per story**: Each story touched 2-5 files with clear boundaries. US-004 (cleanup) only needed 2 files because US-001 had already done the heavy lifting.
- **Backward compatibility** (US-004): Swift's `Codable` silently ignores unknown JSON keys, so removing `activeMode` from `CodingKeys` was sufficient for v2 config migration — no explicit migration code needed.
- **Verification passed 16/16 on first run**: No bugs.json generated, no fix cycles needed.

### What Didn't Go Well
- **Workers couldn't commit**: All 4 workers hit Bash permission denials at the commit step, requiring the orchestrator to commit on their behalf. Workers completed implementation and verification but couldn't finalize. This added overhead to the orchestrator loop.
- **First commit included untracked files**: The US-001 commit bundled `stories.json`, `scenarios.json`, `CertificateSigningRequest.certSigningRequest`, and `LLMService.swift` — files that existed before the takt run. Workers using `git add -A` picked up everything.

### Patterns Observed
- **Bash permission escalation**: Workers are spawned with `bypassPermissions` but still hit Bash denials toward the end of their execution. This is consistent across all 4 workers — likely a session-level permission issue rather than per-command.
- **Config-model-view layering**: All 4 stories followed the same change pattern: model (`AppConfig`) -> service (`ConfigService`) -> manager/viewmodel -> view. This is a well-established pattern in the codebase.
- **os_unfair_lock for audio thread sync** (US-002): Correct choice for real-time audio thread — avoids priority inversion that `DispatchQueue` or `NSLock` would cause.

### Action Items
- [ ] Investigate why `bypassPermissions` workers lose Bash access late in execution — may need a different permission mode or a wrapper script for git operations
- [ ] Consider adding `.gitignore` entries for `.takt/` and `stories.json` to prevent takt artifacts from being committed with feature code
- [ ] Add `CertificateSigningRequest.certSigningRequest` to `.gitignore` — it was accidentally included in US-001 commit

### Metrics
- Stories completed: 4/4
- Stories blocked: 0
- Total workbooks: 4
- Verification: 16/16 scenarios passed (100%), 0 fix cycles
- Timeline: ~32 minutes total (09:08 — 09:40)
