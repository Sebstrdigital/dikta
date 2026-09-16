# Benchmark Results — 2026-09-15

**Machine:** Apple M2 Max, macOS 26.6.2

**Clip Set:** FLEURS test split (20 sv_se + 20 en_us), seed 42, shuffle buffer 1000, 16kHz mono WAVs

## Results

| model | repo | lang | WER | median RTF | model load s |
|-------|------|------|-----|-----------|--------------|
| openai_whisper-small | argmaxinc/whisperkit-coreml | sv | 18.46% | 0.071 | 36.0 |
| openai_whisper-small | argmaxinc/whisperkit-coreml | en | 9.89% | 0.091 | 15.0 |
| openai_whisper-large-v3-v20240930_turbo_632MB | argmaxinc/whisperkit-coreml | sv | 10.05% | 0.103 | 331.0 |
| openai_whisper-large-v3-v20240930_turbo_632MB | argmaxinc/whisperkit-coreml | en | 6.67% | 0.085 | 18.4 |
| KBLab_kb-whisper-small | Leonidng/whisperkit-kb-whisper-small | sv | 3.50% | 0.059 | 215.0 |
| KBLab_kb-whisper-small | Leonidng/whisperkit-kb-whisper-small | en | 54.19% | 0.061 | 20.6 |

## Exact Commands Run

```bash
cd dikta-macos/Bench
source .venv/bin/activate

# Model 1: small
./run.sh argmaxinc/whisperkit-coreml openai_whisper-small

# Model 2: turbo
./run.sh argmaxinc/whisperkit-coreml openai_whisper-large-v3-v20240930_turbo_632MB

# Model 3: kb-whisper
./run.sh Leonidng/whisperkit-kb-whisper-small KBLab_kb-whisper-small
```

## Notes

- **kb-whisper en performance:** WER 54.19% on English test set indicates KBLab model is Swedish-tuned. Swedish WER 3.50% confirms model quality; English underperformance expected for language-specific training.
- **turbo load time:** 331s load for turbo sv reflects model size (632 MB). Subsequent English run (18.4s) benefits from cached CoreML.
- **All three models loaded successfully.** No repository or variant mismatches.
