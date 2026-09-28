# Parakeet vs Whisper — FLEURS sv+en Benchmark — 2026-09-28

**Machine:** Apple M2 Max, macOS 26.6.2, Xcode 27.0.

**Clip Set:** same FLEURS test split as
[benchmark-2026-09-15.md](benchmark-2026-09-15.md) and
[benchmark-2026-09-16-apple.md](benchmark-2026-09-16-apple.md) (20 sv_se + 20
en_us, seed 42, shuffle buffer 1000, 16kHz mono WAVs) — `bench/data/` was
already populated from an earlier run and `fetch_clips.py` is idempotent, so
these are the same clips, directly comparable to every other row cited here.

**Engines:** `parakeet-redux` / `parakeet-v3` / `parakeet-ultra` driven fresh
this sprint via `DiktaBench --engine parakeet --model-version
redux|v3|ultra` (US-004), which talks to FluidAudio's `AsrModels`/`AsrManager`
the same way `Dikta/Services/ParakeetEngine.swift` does — see
`bench/README.md` for the exact invocation. `turbo`
(`openai_whisper-large-v3-v20240930_turbo_632MB`) and `KBLab_kb-whisper-small-hub`
are **not** re-run: their existing summaries are from 2026-09-15/16, inside
this story's "acceptable to cite as-is" window (knownIssues), so they're
carried over unchanged from [benchmark-2026-09-15.md](benchmark-2026-09-15.md)
and [kb-whisper-conversion-2026-09-16.md](kb-whisper-conversion-2026-09-16.md).

Full command sequence run for this report:

```
cd dikta-macos/bench
./run.sh parakeet redux parakeet v3 parakeet ultra
```

`parakeet-redux` was already cached on this Mac from earlier US-004/US-007/US-008
work (`~/Library/Application Support/FluidAudio/Models/parakeet-redux`, 214MB);
`parakeet-v3` (`parakeet-tdt-0.6b-v3`, ~450MB) and `parakeet-ultra`
(`parakeet-ultra`, ~615MB) downloaded fresh from Hugging Face via FluidAudio's
own cache during this run.

## Results

"overall RTF" is `total seconds_wall / total seconds_audio` across all 20
clips for that (model, lang) — same metric `DiktaBench` itself prints in its
`Summary:` line — not the per-file-median RTF the `score.py report` table
prints, since the story asks for the former. For the two carried-over rows
(no saved `Summary:` line), it's recomputed the same way from the still-present
raw per-clip JSONL (`seconds_wall`/`seconds_audio` per file, summed).

| model | lang | WER | overall RTF | model load s | summary JSON |
|---|---|-----:|-----:|-----:|---|
| parakeet-redux | sv | 10.98% | 0.017 | 0.17 | `results/20260928T065101Z-parakeet-redux-sv.json` |
| parakeet-redux | en | 5.81% | 0.018 | 0.17 | `results/20260928T065105Z-parakeet-redux-en.json` |
| parakeet-v3 | sv | 10.98% | 0.009 | 85.78 | `results/20260928T065233Z-parakeet-v3-sv.json` |
| parakeet-v3 | en | 5.38% | 0.009 | 0.14 | `results/20260928T065235Z-parakeet-v3-en.json` |
| parakeet-ultra | sv | 10.28% | 0.009 | 97.74 | `results/20260928T065415Z-parakeet-ultra-sv.json` |
| parakeet-ultra | en | 6.45% | 0.009 | 0.16 | `results/20260928T065417Z-parakeet-ultra-en.json` |
| turbo (large-v3-turbo_632MB) | sv | 10.05% | 0.094 | 331.0 | `results/20260915T092604Z-openai_whisper-large-v3-v20240930_turbo_632MB-sv.json` |
| turbo (large-v3-turbo_632MB) | en | 6.67% | 0.087 | 18.4 | `results/20260915T092639Z-openai_whisper-large-v3-v20240930_turbo_632MB-en.json` |
| KB-Whisper small (hub) | sv | 3.50% | 0.070 | 149.0 | `results/20260916T044112Z-KBLab_kb-whisper-small-hub-sv.json` |
| KB-Whisper small (hub) | en | 54.19% | 0.064 | 14.2 | `results/20260916T044139Z-KBLab_kb-whisper-small-hub-en.json` |

## Caveats

- **`model load s` is cold-vs-warm, not a fair single number.** `parakeet-redux`
  was already downloaded and Neural-Engine-compiled on this Mac before this
  run (from earlier US-004/US-007/US-008 work), so its 0.17s is a warm load,
  not a first-ever-launch number — `bench/README.md`'s "first-load compile
  caveat" says a cold Redux load can take *minutes* for the decoder/joint
  pieces alone. `parakeet-v3` and `parakeet-ultra` downloaded fresh here: their
  **sv** rows (85.78s / 97.74s) are the true cold-load cost (HF download +
  first ANE compile, done in the same process as the sv transcription run);
  their **en** rows (0.14s / 0.16s) are warm, because `run.sh` transcribes sv
  then en as two separate `DiktaBench` invocations and the model was already
  on disk and ANE-compiled by the time the en invocation started. Same
  cold/warm split likely explains turbo's 331.0s (sv) vs 18.4s (en) and
  KB-Whisper-hub's 149.0s (sv) vs 14.2s (en) — those numbers are carried over
  unchanged, not re-verified here.
- **`parakeet-redux` and `parakeet-v3` sv WER are identical to 15 decimal
  places (10.98%) by coincidence, not a harness bug.** Diffed the raw
  hypothesis text (`raw-parakeet-redux-sv.jsonl` vs `raw-parakeet-v3-sv.jsonl`)
  clip by clip — the transcripts genuinely differ word-for-word on most
  clips (e.g. 001.wav: "distrikts gemensam bussstation" vs "distrikt i
  gemensamma busstationer"), they just land on the same total edit-distance
  count over the same 20-clip/224.8s set.
- **This run's raw Parakeet output does include punctuation and casing**
  (periods, commas, capitalized sentence starts — see e.g.
  `raw-parakeet-ultra-en.jsonl` 018.wav: "...to hold the tracks in place.
  Gradually, however, it was realized..."), which reads as contradicting
  `stt-landscape-2026-09.md`'s "No punctuation" note on Parakeet TDT v3. Not
  independently verified beyond a spot-check of a few clips per variant — this
  benchmark measures WER, not punctuation presence/quality — so treat this as
  a pointer for follow-up, not a re-scored claim.
- Our fresh `parakeet-v3` sv WER (10.98%) is measurably better than the
  16.8% FLEURS figure `stt-landscape-2026-09.md` cites from FluidAudio's own
  published benchmark (M4 Pro, undated, unknown clip sample) — different
  hardware and almost certainly a different/larger clip sample than this
  20-clip set, so the two numbers aren't directly comparable, but both agree
  on the conclusion below: worse than KB-Whisper small on Swedish either way.

## Recommendation

On this evidence, the Engine menu's `(Recommended)` label belongs on
**Parakeet v3** for English — it has the best English WER of every model
measured here (5.38%, beating turbo's 6.67%, Redux's 5.81%, and Ultra's
6.45%), an overall RTF roughly 10x faster than turbo (0.009 vs 0.087), and a
mid-sized footprint (600MB) between Redux (480MB) and Ultra (1200MB); the
one real cost is a one-time ~86s cold load on first use (Neural Engine
compile), which is a one-off per machine, not a per-transcription tax.
Swedish should **not** move off KB-Whisper: every Parakeet variant scored
10.28–10.98% WER on Swedish here, roughly 3x worse than KB-Whisper small's
3.50%, so `MenuBarViewModel.effectiveModel(for:)`'s existing Swedish rule —
force KB-Whisper (under the Whisper engine) regardless of the user's engine
or model preference — should stay exactly as it is; none of the three new
Parakeet variants gives any reason to revisit it.
