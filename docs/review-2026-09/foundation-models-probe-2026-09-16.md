# Foundation Models Formatting Probe — 2026-09-16

**Machine:** Apple M2 Max, 32 GB, macOS 26.6.2, Xcode 27.0 (invoked `swiftc` directly, no Xcode project)

**Goal:** can `FoundationModels` (on-device `LanguageModelSession` + `@Generable`) restructure raw dictated text into an email/document shape without changing the words, in English and Swedish.

**Result: blocked before any formatting could be tested.** `SystemLanguageModel.default.availability` reports `.available`, but every single `respond(to:)` call — Generable or plain text, either language, both option sets — fails with the same nested error. This is not a guardrail hit and not per-sample; a bare `session.respond(to: "Say hello in one word.")` with no schema fails identically. Root cause looks like a missing/broken on-device safety-classifier asset, not anything about the prompts or types tested.

## Availability

```
AVAILABILITY: available
```

## Per-sample table

Every cell is the same because every call failed the same way, regardless of sample, language, target type, or `GenerationOptions`.

| sample | lang | type | opts | latency (s) | words added | words removed | structure ok? |
|---|---|---|---|---|---|---|---|
| en1-greeting-list | en | email / document | default / greedy-temp0 | — | — | — | ERROR |
| en2-narrative | en | email / document | default / greedy-temp0 | — | — | — | ERROR |
| en3-formal-email | en | email / document | default / greedy-temp0 | — | — | — | ERROR |
| en4-casual-message | en | email / document | default / greedy-temp0 | — | — | — | ERROR |
| en5-status-update | en | email / document | default / greedy-temp0 | — | — | — | ERROR |
| sv1-lines0-5 | sv | email / document | default / greedy-temp0 | — | — | — | ERROR |
| sv2-lines6-12 | sv | email / document | default / greedy-temp0 | — | — | — | ERROR |
| sv3-lines13-19 | sv | email / document | default / greedy-temp0 | — | — | — | ERROR |

20 of 20 calls (5 en + 3 sv samples × 2 types × 2 option sets) failed. 0 succeeded.

## Before/after examples

**None available.** No call produced output in either language, so there is nothing to show as a verbatim before/after pair. Reporting this rather than fabricating a "would look like" example per the no-invented-content rule.

## The error

Identical shape on every call:

```
Error Domain=FoundationModels.LanguageModelSession.GenerationError Code=-1 "(null)" UserInfo={NSMultipleUnderlyingErrorsKey=(
    "Error Domain=FoundationModels.LanguageModelSession.GenerationError Code=-1 \"(null)\" UserInfo={NSMultipleUnderlyingErrorsKey=(
    \"Error Domain=com.apple.SensitiveContentAnalysisML Code=15 \\\"(null)\\\" UserInfo={NSMultipleUnderlyingErrorsKey=(
    \\\"Error Domain=ModelManagerServices.ModelManagerError Code=1013 \\\\\\\"(null)\\\\\\\" UserInfo={NSMultipleUnderlyingErrorsKey=(\\\\n)}\\\"
    \n)}\"
    \n)}"
)}
```

Chain: `GenerationError` → `GenerationError` → `com.apple.SensitiveContentAnalysisML Code=15` → `ModelManagerServices.ModelManagerError Code=1013`. None of these are the documented, typed `LanguageModelSession.GenerationError` cases (`guardrailViolation`, `exceededContextWindowSize`, `refusal`, etc.) — it's an opaque infra failure surfacing through the generic case, with an empty `NSLocalizedDescription` ("(null)" at every level).

## Diagnosis (ruling out prompt/schema causes)

- Failed on all 8 samples (5 English, 3 Swedish) — including entirely mundane content (weather-adjacent narrative, status updates). Not a guardrail-shaped failure.
- Failed identically under both `GenerationOptions()` (default) and `GenerationOptions(samplingMode: .greedy, temperature: 0)` — not sampling-related.
- Failed identically for both `@Generable` types (`EmailDraft`, `DocumentDraft`) — not schema-related.
- Built a separate minimal repro (`/tmp/fm-minimal.swift`, not checked in) with **no** `@Generable`, **no** custom instructions, **no** options — just `LanguageModelSession().respond(to: "Say hello in one word.")`. Same exact error chain. This isolates the failure to session/model infra, not anything in `foundation-formatprobe.swift`.
- `com.apple.SensitiveContentAnalysisML` is Apple's on-device content-safety classifier that runs ahead of generation. `ModelManagerError 1013` reads as "required model asset not present/loadable" — i.e. the safety classifier asset itself, not the main generation model, appears to be the thing that's missing or broken on this Mac, even though `SystemLanguageModel.default.availability` (which only checks the base generation model) reports `.available`.
- No public API surfaced to force-download or bypass this classifier asset. `SystemLanguageModel(guardrails: .permissiveContentTransformations)` only affects *content* permissiveness for string generation, not classifier asset presence, and wasn't tried since the failure isn't guardrail-shaped.

This is exactly the "framework fails / model unavailable in practice" case the task said to stop and report on, not improvise past.

## Exact commands

```bash
cd dikta-macos/bench/probes
swiftc -O -parse-as-library foundation-formatprobe.swift -o /tmp/foundation-formatprobe -framework FoundationModels
/tmp/foundation-formatprobe
```

Compiles clean (one deprecation warning fixed during development: `GenerationOptions(sampling:...)` → `GenerationOptions(samplingMode:...)`, the latter used in the checked-in probe).

## Verdict

**Not viable to evaluate yet — the platform failed before the formatting question could be tested at all**, on this Mac, on macOS 26.6.2 / Xcode 27.0, right now. This is an environment/asset-availability problem, not a fidelity or hallucination problem with the approach. Nothing here says the formatter idea is bad; nothing here says it's good. **Swedish specifically:** no separate signal — Swedish failed with the exact same error as English, at the exact same point (before any tokens were generated), so this run gives zero information about Swedish-specific behavior (translation risk, hallucination, etc.) one way or the other. Re-run needed once availability is fixed (see open questions) before any real verdict on the macOS 26 formatter tier is possible.

## Failure modes seen

- **Infra/asset failure (100% of calls):** `ModelManagerError 1013` under `SensitiveContentAnalysisML`, as above.
- **Not seen (because nothing got far enough to trigger them):** hallucinated words, translated text, dropped sentences, guardrail refusals, context overflow. Samples were kept well under the 4K-token on-device limit (largest sample ~176 words / ~230 tokens) specifically to rule out context overflow as a confound, but this couldn't be exercised either way.

## Open questions

- Is `com.apple.SensitiveContentAnalysisML` asset download gated on something `SystemLanguageModel.availability` doesn't check (e.g. a separate Settings toggle, a background download that hasn't completed, disk space, or region)? Not established — would need Apple's own diagnostics or a second Mac to compare against.
- Does a reboot / waiting for background asset sync / toggling Apple Intelligence off-and-on in System Settings clear `ModelManagerError 1013`? Not tried — outside probe scope, and the task said not to improvise past a blocked state.
- Is this specific to Xcode 27.0 / macOS 26.6.2, or would it reproduce on a clean macOS 26.6.2 + Xcode 26.6 machine (the versions named in the original task brief)? Xcode 27.0 was what's actually installed on this Mac, not 26.6 as the brief assumed — worth flagging since it's a version mismatch from what was expected, though unlikely to be the cause of an asset-manager error.

## Out-of-scope findings (report, don't fix)

- No `history.json` exists at `~/Library/Application Support/Dikta/` on this Mac — only `config.json` and `kokoro_server.py`. Source priority (1) from the task brief was unavailable; fell through to source (2) (`FormatterTests.swift` fixtures) for English and source (3) (`raw-openai_whisper-large-v3-v20240930_turbo_632MB-sv.jsonl`) for Swedish, both real STT output per the task's fallback order.
- `dikta-macos/bench/results/raw-openai_whisper-large-v3-v20240930_turbo_632MB-en.jsonl` also exists (English read-speech STT output, same benchmark run as the Swedish one) — not used here since `FormatterTests.swift` already had enough real English fixtures in range, but noted in case a future probe wants a matched-condition en/sv pair from the same benchmark source instead of mixing dictation-style and read-speech-style text across languages.
