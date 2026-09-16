# Benchmark Results — Apple Dictation Engine — 2026-09-16

**Machine:** Apple M2 Max, macOS 26.6.2, Xcode 27.0 (task context named Xcode 26.6; the
machine has since updated to 27.0 — noted here since it affects reproducibility, not
because it changed anything relevant to this run).

**Clip Set:** same FLEURS test split as [benchmark-2026-09-15.md](benchmark-2026-09-15.md)
(20 sv_se + 20 en_us, seed 42, shuffle buffer 1000, 16kHz mono WAVs) — same clips, so
results are directly comparable.

**Engine:** Apple's on-device `DictationTranscriber` (Speech framework, macOS 26+), driven
via `DiktaBench --engine apple`, mirroring
`Dikta/Services/AppleDictationEngine.swift` and
[apple-dictation-engine-spec.md](apple-dictation-engine-spec.md). Fresh
`DictationTranscriber` + `SpeechAnalyzer` per clip (reuse silently returns `""` — spec §6),
`.shortDictation` preset, locale resolved via `DictationTranscriber.supportedLocale(equivalentTo:)`
(sv → sv-SE, en → en-US), assets checked/installed once per language via
`AssetInventory.assetInstallationRequest`.

## Converter Bug Fix (pre-existing report was run against buggy code)

The first version of this benchmark (this report supersedes it) had a bug in
`appleConvert` (`dikta-macos/bench/DiktaBench/main.swift`): the `AVAudioConverterInputBlock`
always returned the source buffer with `.haveData` and never signalled `.endOfStream`, and
the output buffer's capacity was over-allocated by a flat `+1024` frames. Caught by
skeptic review: for an 8000-frame input, `outputFrameLength` came out `9024`, and
`frames[8000..8004]` equalled `frames[0..4]` — the converter, seeing no end-of-stream
signal, pulled the (already-exhausted) source buffer a second time and padded the tail
with a wrapped-around repeat of its first ~64ms.

Fixed with a captured `didSupply` flag: the input block returns the buffer with `.haveData`
on the first call only; every later call sets the status to `.endOfStream` and returns
`nil`. Output capacity is now sized from the sample-rate ratio (rounded up) plus a small
16-frame margin — the margin no longer matters for correctness since the input block itself
caps the real data at one buffer's worth.

Verified with a standalone check (samples supplied to `appleConvert`, not linked against
the real target — same logic, copied for isolated testing) converting an 8000-frame,
16kHz Float32 buffer to the analyzer's Int16 16kHz mono format (spec §2's measured
`bestAvailableAudioFormat` for sv-SE — same rate as the source, so no resampling, only a
format change):

```
inputFrames=8000 outputFrameLength=8000 outputCapacity=8016
PASS: outputFrameLength == inputFrames
head[0..5]=[0, 5634, 11100, 16235, 20887]
tail[-5..]=[-24917, -20887, -16235, -11100, -5634]
identity-path: inputFrames=8000 outputFrameLength=8000
```

`outputFrameLength` now equals `inputFrames` exactly, and the head/tail samples are
clearly distinct (natural sine-wave values, not a repeat) — the wraparound duplication is
gone. The identity fast-path (source format already matches target) still returns the
source buffer unmodified. This report's numbers below are from a full re-run against the
fixed converter; also fixed at the same time: the format-match guard now also compares
`channelCount`, not just `commonFormat`/`sampleRate` (`main.swift:143`), since a
channel-count mismatch alone would previously have skipped conversion incorrectly.

Re-running WER after the fix was unchanged (11.68% sv / 11.18% en, byte-identical
hypothesis text to the buggy run) — the duplicated ~64ms tail was silence-adjacent in
every one of these 20+20 clips and never registered as an extra recognized word here. The
correctness fix stands regardless: it would matter for a clip whose last ~64ms contains
meaningful audio, and the bug's underlying misuse of `AVAudioConverterInputBlock` (an
input block that never signals end-of-stream) is a real defect independent of whether this
particular sample set happened to expose it in the transcript text.

## Results

| model | lang | WER | WER (no-digit refs) | median RTF | model load s |
|-------|------|-----|----------------------|-----------|--------------|
| apple-dictation | sv | 11.68% | 11.14% | 0.033 | 0.02 |
| apple-dictation | en | 11.18% | 9.15% | 0.043 | 0.02 |

`model load s` rounds to `0.0` in the `score.py report` table below; the harness printed
the more precise `0.02s` for both languages (see "Exact Commands Run"). It is much lower
than the first (buggy-converter) run's ~1.1–1.3s because the Apple Dictation language
assets for sv-SE/en-US were already installed on this machine from that earlier run —
`AssetInventory.assetInstallationRequest` returns near-instantly once assets are present
(spec §3), regardless of the converter fix. Median RTF also dropped (0.086→0.033 sv,
0.128→0.043 en) for the same reason: no first-run disk I/O for asset installation
competing with per-clip transcription.

"WER (no-digit refs)" restricts scoring to clips whose FLEURS reference contains no digit
at all, isolating genuine transcription errors from mismatches caused by Apple's inverse
text normalization (ITN) turning spoken numbers into digits that a purely lexical FLEURS
reference never has. It drops WER slightly in both languages (sv 11.68% → 11.14%, en
11.18% → 9.15%), meaning digit-containing clips are somewhat harder for this engine, but
ITN alone does not explain the bulk of the WER — most errors are ordinary
substitutions/deletions, not digit-formatting mismatches (see the mixed sv/en error
examples below).

## Digit Analysis

| lang | n clips | refs with digits | hyps with digits | clips scored (no-digit refs) |
|------|---------|-------------------|-------------------|-------------------------------|
| sv | 20 | 4 | 6 | 16 |
| en | 20 | 6 | 7 | 14 |

Reproduce with:

```bash
cd dikta-macos/bench && source .venv/bin/activate
python3 score.py digits --results results/raw-apple-dictation-sv.jsonl \
    --refs data/sv/refs.jsonl --model apple-dictation --lang sv
python3 score.py digits --results results/raw-apple-dictation-en.jsonl \
    --refs data/en/refs.jsonl --model apple-dictation --lang en
```

Output:

```
model=apple-dictation lang=sv n_total=20 ref_has_digits=4 hyp_has_digits=6 n_no_digit_refs=16 wer_no_digit_refs=11.14%
model=apple-dictation lang=en n_total=20 ref_has_digits=6 hyp_has_digits=7 n_no_digit_refs=14 wer_no_digit_refs=9.15%
```

More hypotheses have digits than references in both languages (sv 6 vs 4, en 7 vs 6) —
consistent with ITN converting spelled-out numbers to digits, though the gap is small in
this 20-clip sample and a couple of cases are plain transcription errors, not ITN (see
below).

## Example Pairs — ITN Effect

**Swedish** — clips `003.wav` and `020.wav` share the same FLEURS reference sentence, but
their hypotheses are two independent transcriptions (not identical) and are shown
separately:

```
003.wav
REF: Kyrkans centrala makt hade legat i Rom i över tusen år och denna koncentration av
     makt och pengar fick många att ifrågasätta om denna princip var uppfylld.
HYP: Kyrkans centrala makt hade legat i Rom i över 1000 år och denna koncentration av
     makt och pengar. Fick många ifrågasätta om denna princip har uppfyllt.

020.wav
REF: Kyrkans centrala makt hade legat i Rom i över tusen år och denna koncentration av
     makt och pengar fick många att ifrågasätta om denna princip var uppfylld.
HYP: Kyrkans centrala makt hade legat i Rom i över 1000 år och denna koncentration av
     makt och pengar fick många ifrågasätt om denna princip var uppfylld
```

Both independently convert spoken "tusen" (thousand) to the digit "1000" — a clean,
isolated ITN conversion — but differ elsewhere: `003.wav`'s hypothesis adds a sentence
break ("pengar. Fick") and says "har uppfyllt" where `020.wav`'s says "ifrågasätt" for
"ifrågasätta" and omits "att" — ordinary transcription variance between two separate
recordings of the same sentence, not related to ITN.

**Swedish** (clip `001.wav`) — time formatting, not just number-to-digit:

```
REF: ... går mellan 6.30 och 7.30.
HYP: ... går mellan 06:30 och 07:30
```

The reference already uses digits for the times, but Apple's output re-formats them with
zero-padding and a colon separator (`06:30`/`07:30`) instead of the FLEURS source's
period-separated, non-padded style (`6.30`/`7.30`) — a formatting difference the WER
normaliser (which strips all punctuation) happens to erase, but a real ITN behaviour a
formatter stage downstream would need to handle.

**Swedish** (clip `013.wav`) — hyphenated year-range collapsed:

```
REF: ... sedan 1800-talet.
HYP: ... sedan 1800 talet
```

**English** (clip `020.wav`) — the clearest word-to-digit conversion in the English set:

```
REF: Finland is a great boating destination. The "Land of a thousand lakes" has
     thousands of islands too, in the lakes and in the coastal archipelagos.
HYP: Finland is a great boating destination the land of 1000 lakes has thousands of
     islands too, and the lakes in the coastal archipelago
```

"a thousand" → "1000". Note "thousands" (plural, non-numeral use) is correctly left as a
word both times — ITN only fires on the numeral usage.

**English** (clip `014.wav`) — ITN interacting badly with a recognition error:

```
REF: ... the period of European history in the 11th, 12th, and 13th centuries
     (AD 1000–1300).
HYP: ... the period of European history and the 11th 12th and 13th centuries 80 100 or
     1000 to 1300
```

"AD" was misheard and rendered as "80 100", and the en-dash range "1000–1300" became
"1000 to 1300" — illustrates that ITN artifacts are not always clean; they can compound
with ordinary ASR errors in ways that are hard to disentangle from "genuine" WER.

**English** (clip `004.wav`) — a case where the reference already had a digit and it
passed through unchanged:

```
REF: ... Some tax agencies define goods older than 100 years as antiques.
HYP: ... some tax agencies, defying goods, older than 100 years as antiques
```

Only 1 of 6 English no-digit-reference clips with digit hypotheses showed a clean
word→digit conversion (`020.wav`); most of the FLEURS English references in this 20-clip
sample already use digits for numbers, so the ITN effect specifically is under-sampled
here — a larger clip set would surface more of it.

## Exact Commands Run

```bash
cd dikta-macos/bench
./run.sh apple apple
```

This built `DiktaBench`, then ran `--engine apple` for both `sv` and `en` against the
existing 20-clip sets in `data/sv` and `data/en`, writing
`results/raw-apple-dictation-{sv,en}.jsonl` and
`results/20260916T021529Z-apple-dictation-sv.json` /
`results/20260916T021539Z-apple-dictation-en.json`, then printed the full
`score.py report` table (below, unmodified from that run's tail). The earlier
(converter-bug) run's summary JSONs
(`20260916T015135Z-apple-dictation-sv.json`,
`20260916T015202Z-apple-dictation-en.json`) were deleted so `report` shows one row per
language.

Digit analysis commands are in the "Digit Analysis" section above.

## Comparison vs. WhisperKit Models (benchmark-2026-09-15.md)

| model | lang | WER | median RTF | model load s |
|-------|------|-----|-----------|--------------|
| openai_whisper-small | sv | 18.46% | 0.071 | 36.0 |
| openai_whisper-small | en | 9.89% | 0.091 | 15.0 |
| openai_whisper-large-v3-v20240930_turbo_632MB | sv | 10.05% | 0.103 | 331.0 |
| openai_whisper-large-v3-v20240930_turbo_632MB | en | 6.67% | 0.085 | 18.4 |
| KBLab_kb-whisper-small | sv | 3.50% | 0.059 | 215.0 |
| KBLab_kb-whisper-small | en | 54.19% | 0.061 | 20.6 |
| **apple-dictation** | **sv** | **11.68%** | **0.033** | **0.0** |
| **apple-dictation** | **en** | **11.18%** | **0.043** | **0.0** |

Observations:

- **Swedish**: Apple (11.68%) sits between `small` (18.46%) and `turbo` (10.05%) — better
  than the small OpenAI model but not quite turbo, and far behind KB-Whisper's 3.50%.
- **English**: Apple (11.18%) is worse than both `small` (9.89%) and `turbo` (6.67%), but
  dramatically better than KB-Whisper on English (54.19% — that model is Swedish-tuned).
  Apple is the only engine here that is simultaneously usable on both languages without a
  language-specific WER cliff.
- **Load time** is Apple's standout number: ~0.02s (assets already installed on this
  machine) vs. 15–331s for the WhisperKit models. Even accounting for a cold
  asset-install (measured ~1.1–1.3s in this benchmark's first run, before assets were
  cached), it's still an order of magnitude faster than any WhisperKit model here.
- **RTF** is lower than the WhisperKit models in this run (0.033–0.043 vs. 0.059–0.103),
  but the two are not measuring quite the same thing: `seconds_wall` for Apple includes
  building a fresh `DictationTranscriber` + `SpeechAnalyzer` and calling
  `bestAvailableAudioFormat` on every clip (required per-clip by this engine's lifecycle —
  see spec §6), whereas the WhisperKit span times only `whisperKit.transcribe(...)`
  against an already-loaded model, excluding load time entirely. Apple's RTF advantage
  here is real but partly reflects that per-clip setup cost being small, not a strictly
  comparable inference-only number.
- Apple's WER cannot be directly compared 1:1 with the WhisperKit rows without caveats:
  its output includes ITN and native punctuation, both of which the shared normaliser
  (lowercase, strip punctuation) neutralizes for scoring — but see the "WER (no-digit
  refs)" column and digit analysis above for the residual effect that punctuation-stripping
  doesn't erase.

## Open Questions

- Only 20 clips per language; digit/ITN incidence (4-7 clips with digits) is too small a
  sample to generalize the exact ITN error rate — a larger clip set (or one deliberately
  oversampled for numeric content) would give a tighter estimate.
- `score.py digits` computes WER over the no-digit-reference subset only; it does not
  attempt to align/score the digit-containing clips separately by "ITN correct" vs. "ASR
  wrong" — clip `014.wav` above shows those two failure modes can compound and aren't
  always separable from the raw JSONL alone.
- Real (non-`say`-synthesized) human Swedish audio was already flagged as an open gap in
  `apple-dictation-engine-spec.md` §7; this run uses the same FLEURS human-speech clips as
  the WhisperKit benchmarks, so that specific gap is now closed for Apple too — but
  offline/air-gapped asset installation is still unverified.
