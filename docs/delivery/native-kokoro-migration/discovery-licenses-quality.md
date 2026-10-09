# Discovery: licenses, frontend integrity and model quality

Status: paper discovery. No application/SDK edits, model-weight downloads, synthesis, playback, build or new worker. Public text, directory metadata and a Prosody MIL program were inspected; existing prepared asset metadata was read without modifying it. Recommendations require joint ADR approval.

## 1. Component-level license findings

This is an evidence inventory, not a legal opinion or a final distribution NOTICE.

| Component | Inspected evidence | Distribution action / remaining gap |
|---|---|---|
| FluidAudio 0.17.4 | Local checkout LICENSE: Apache-2.0; package revision `21493f8dac5a97e65742e6ff26f42f164c2fda0f` | Preserve license and applicable third-party notices in the exported app. Do not assume SwiftPM resource copying creates a complete notice inventory. |
| Seven-stage Core ML conversion | Pinned HF `ANE/LICENSE` exists and contains Apache-2.0 with `Copyright 2026 laishere`; root model card declares Apache-2.0 | Include this actual asset license. The earlier missing ROOT LICENSE finding did not mean there was no license elsewhere. |
| Conversion documentation | At the same HF revision, `ANE/README.md` claims MIT, Lai Yongkang 2025 and FluidInference MIT, and points to an old loader/cache name | Conflicts with the actual Apache-2.0 license file. Treat the README as potentially stale, preserve provenance, and resolve/document the applicable notice chain rather than inventing an MIT grant or declaring the entire distribution cleared. |
| Original conversion project | `laishere/kokoro-coreml` commit `484907db6a8347a6afb6e7b86850ea2878c6a3fb`, LICENSE is Apache-2.0 | Supports the current Apache statement; does not prove the exact conversion commit for every HF compiled file. |
| Kokoro acoustic weights and original voices | `hexgrad/Kokoro-82M` metadata at `f3ff3571791e39611d31c381e3a41a3af07b4987` declares Apache-2.0 | Record upstream model/voice attribution alongside native converted artifacts. No independent speaker-rights assessment is inferred from metadata. |
| English BART G2P | Current mobius converter explicitly loads `PeterReid/graphemes_to_phonemes_en_us`; upstream metadata/card at `a5631b285d18d59483c32c0c3379cb9fac924f4b` declares Apache-2.0 | Include separate frontend-model attribution. Converter does not pin the checkpoint revision; compiled metadata records torch/coremltools/date, not original checkpoint identity. Exact historical source linkage remains unverified. |
| English lexicon | SDK says preprocessed Misaki; cached JSON root has only `lower` and `caseSensitive`, no provenance header. Misaki LICENSE at `fba1236595f2d2bf21d414ba6e57d25256afada3` is Apache-2.0 | Record Misaki attribution and the immutable native cache hash. Do not claim the cached file identifies its exact dictionary-source revision or every incorporated data notice. |
| NeMo normalizer | SDK Package.swift pins `NemoTextProcessing.xcframework.zip` v0.3.1 and checksum `5fa8c10d4ec26c1bb2413125f351a7222a4c68a23b74476680fbada7e26fc6aa` | SDK third-party note says v0.3.0, so use the actual package artifact identity, not that stale version label. |
| Normalizer's linked dependencies | v0.3.1 `NOTICE` and `THIRD-PARTY-LICENSES.md` identify text-processing-rs Apache-2.0, NVIDIA NeMo Apache-2.0, rustfst and flate2 MIT OR Apache-2.0, and additional permissive Rust dependencies | Preserve the actual NOTICE, applicable full licenses and exact dependency attribution. Generated/locked Rust inventory remains to be completed, not replaced by “all permissive” prose. |

The NeMo source declares its grammars/fixtures derived from NVIDIA commit `1f1263579fe57ba7ed783cad3dddee710fcc5064`. The package pins its binary independently of the downloaded Kokoro assets. Disable/change neither dependency nor normalization behavior merely to simplify notices; that would invalidate pronunciation evidence.

No new Python, spaCy or espeak runtime is required by the inspected native English path. This is not a blanket statement about the provenance of all upstream training/dictionary data. Existing Python files remain preserved locally for rollback.

### Proposed notice delivery

Ship a readable Third-Party Notices resource in the app, accessible from an existing suitable About/help entry, plus component/license references in the signed asset manifest and owned asset-version metadata. Voice conversion records source revision/hash and explicitly identifies the changed format and converter version. Do not imply that downloading assets directly from upstream eliminates notice obligations.

Before release, the maintainer must accept the finalized inventory, including stale conversion-license documentation, historical G2P/lexicon provenance limits and Rust dependencies. No upstream issue/contact, new publication or legal clearance has been performed here.

## 2. Additional G2P limits and silent omission

Pinned native `G2PEncoder.mlmodelc/metadata.json`: input_ids range `[1,1] × [1,64]`. SDK `TTS/G2P/G2PModel.swift` constructs `[BOS] + one ID per Swift Character + [EOS]`. Therefore fallback words have at most **62 Swift Characters** AFTER frontend normalization; this is not a 62-byte/scalar limit and is separate from the 510-scalar synthesis limit.

The SDK performs up to 64 greedy decoder steps. It breaks on EOS, but does not report whether the step cap was reached without EOS. It removes special tokens and may return nil if no phonemes remain.

`KokoroAneEnglishPhonemizer.swift`, `resolveWord`, lines 206–215, logs a warning and RETURNS NIL for a nil/empty fallback. The outer token loop then continues. A mixed sentence can thus produce audio while omitting an unresolved word. Its exceptions and warnings can also include the original/normalized input.

**Correction to acceptance wording:** source-span coverage proves the application's chunker did not discard/reorder input; it cannot, by itself, prove every source word survived the SDK frontend or that pronunciation is correct. The phoneme vocabulary can also drop out-of-vocabulary scalars (`KokoroAneSynthesisResult` documentation). These need separate assertions/qualification.

### Proposed handling and decision needed

- Use an explicit conservative lexical-length guard before fallback work; at minimum respect the normalized 62-Character bound. Never feed an unbounded token and hope the 510-phoneme guard protects it.
- Reject unsupported/pathological input without truncating or splitting a word's phonemes arbitrarily. A raw-token guard can conservatively reject a known word too; make that policy explicit.
- A strict frontend must fail a chunk on an unresolved word or decoder exhaustion rather than silently omit it. The current public `phonemes(for:)` API does not expose those diagnostics.
- Do NOT claim strict no-omission behavior is already implementable merely by wrapping that whole-candidate API.

Options for joint decision: (a) an app-owned strict frontend adapter using public APIs with normalization/token equivalence tests; (b) an explicitly approved, narrowly scoped SDK patch/version providing structured frontend outcomes; or (c) accept a clearly documented limitation for ordinary English while weakening the universal guarantee. **Recommend retaining the fail-not-skip requirement and first establishing the smallest supportable strict adapter/API path.** No SDK fork, upgrade or reimplementation is authorized by this recommendation.

Normalizing each raw word independently is not an automatic solution. `EnglishTextNormalizer.normalizeForFrontend` is internal; it runs public NeMo first, then a conservative fallback if NeMo leaves text unchanged. Currency, numbers, dates and phrases can change when split. A new adapter must preserve that behavior or deliberately qualify a changed frontend, not quietly bypass it.

## 3. Privacy configuration is an actual runtime requirement

Inspected `Shared/AppLogger.swift`: SDK minimumLevel defaults to debug; mirrorsToConsole defaults true. Release warnings/errors can be synchronously copied to stderr. Merely switching off console mirroring still routes messages to unified logging.

Candidate service policy before SDK work: disable console mirroring, set SDK minimumLevel to fault, and use separate app-owned structured error/phase logging. The inspected Kokoro/G2P source and Shared directory contain no fault logging call sites apart from the logger implementation. This can suppress the identified text-bearing warning/error paths without changing the SDK, but requires a packaged privacy check and renewed source audit whenever the pin changes.

Never forward arbitrary SDK localizedDescription/userInfo to ordinary diagnostics or UI errors that are logged by the host. Map to bounded application-owned categories with safe user messages. Do not enable CI's missing-G2P nil-return fallback in shipping service execution. Underlying native-library/system diagnostics are not proven content-free by this source audit.

## 4. Old Prosody graph and the fixed graph

The immutable native model card documents `KokoroProsody_v2.mlmodelc` as an fp32 compute fix for fp16 CPU/ANE corruption of F0/N at utterance onset when T_a is approximately 400 or larger (quiet first words). It links upstream issue #947 and conversion/SDK fixes.

The pinned SDK's `KokoroAneStage.bundleName` still returns `KokoroProsody.mlmodelc`. Existing experiment `AssetPreparation.bundles` also selects that old name. Its actual metadata reports mixed Float16/palettized storage and mixed compute. Consequently the earlier benchmark/quality evidence is for the OLD graph, not proof that the fix is present. This is a source-documented risk, not a reproduced Dikta failure.

The pinned HF tree contains both graphs. The v2 MIL has the same named fp16 inputs (`en` [1,640,T], `style_s` [1,128]), flexible T range 1...2000, and named outputs F0/N now fp32. SDK stage helpers rebuild F0 into float32 for Noise and F0/N into float16 for Vocoder. This makes a manifest-driven source-to-local-name mapping a plausible bounded option, not a proven drop-in replacement. The v2 directory does not expose the metadata.json requested in discovery; the MIL and tree are the inspected evidence.

**Recommended next decision:** qualify the fixed v2 artifact with an explicit manifest mapping to the filename expected by the pinned SDK, and an explicitly recorded public compute-plan setting, BEFORE shipping the old graph knowingly. The manager accepts public `KokoroAneComputeUnits`; do not assume a newer graph needs no routing review. If mapping/signatures/runtime are incompatible, return to the ADR for an approved narrow SDK change. Do not silently rename assets or upgrade dependencies now.

Any successful change requires new model manifest/hashes/size and a small matched Heart/paragraph/pronunciation requalification. The old 49-file/94,759,376-byte set remains a historical benchmark identity, not the final production manifest. Check first-word onset on longer output (including actual acousticFrames ≥400), natural level and all offered voices. Restricting input characters or phonemes alone does not prove acousticFrames remains below 400.

## 5. Voice/language semantics

Current Python server uses `KPipeline(lang_code='a')`. Native English uses US lexicon/G2P. Keep that English frontend scope explicit, even for British-labelled voice timbres; offering Emma/George does not establish British G2P parity or add a language setting. Speaker names and upstream quality grades are not a replacement for the app's bounded smoke/human checks.

## Primary evidence links

All native links use revision `006395f65025af251858b1ab0a7178a6a1e73f9f`:

- https://huggingface.co/FluidInference/kokoro-82m-coreml/raw/006395f65025af251858b1ab0a7178a6a1e73f9f/ANE/LICENSE
- https://huggingface.co/FluidInference/kokoro-82m-coreml/raw/006395f65025af251858b1ab0a7178a6a1e73f9f/ANE/README.md
- https://huggingface.co/FluidInference/kokoro-82m-coreml/raw/006395f65025af251858b1ab0a7178a6a1e73f9f/README.md
- https://huggingface.co/FluidInference/kokoro-82m-coreml/raw/006395f65025af251858b1ab0a7178a6a1e73f9f/G2PEncoder.mlmodelc/metadata.json
- https://huggingface.co/FluidInference/kokoro-82m-coreml/raw/006395f65025af251858b1ab0a7178a6a1e73f9f/ANE/KokoroProsody_v2.mlmodelc/model.mil
- https://raw.githubusercontent.com/laishere/kokoro-coreml/484907db6a8347a6afb6e7b86850ea2878c6a3fb/LICENSE
- https://raw.githubusercontent.com/hexgrad/misaki/fba1236595f2d2bf21d414ba6e57d25256afada3/LICENSE
- https://huggingface.co/PeterReid/graphemes_to_phonemes_en_us/raw/a5631b285d18d59483c32c0c3379cb9fac924f4b/README.md
- https://raw.githubusercontent.com/FluidInference/text-processing-rs/v0.3.1/NOTICE
- https://raw.githubusercontent.com/FluidInference/text-processing-rs/v0.3.1/THIRD-PARTY-LICENSES.md
- Converter discovery: https://raw.githubusercontent.com/FluidInference/mobius/main/models/tts/kokoro/coreml/g2p/convert-to-coreml.py ; directory tree identified converter blob `2b47ee447cda65e60aa5cb75d611f5828e34a778`. This current converter is not proof of the exact historical compiled-asset source revision.

Session retrieval IDs: `muys1a3aqybvn5`, `muys1mpt9qxnvt`, `muys41hq9rxuj7`, `muys7udcggu3yz`, `muys8yxs7oeaxt`, `muys9uotvxwvz4`, `muysan4txoff5f`. Search-generated license claims were not treated as primary clearance.
