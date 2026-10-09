# ADR 0001: Native Kokoro for macOS Read Aloud — bounded v1

**Status:** Accepted by the maintainer through the submitted decision review (overall acceptance and all four proposed decisions accepted). Discovery for this scope is closed; implementation is not authorized.

**Acceptance source:** The submitted review identifies the reviewed ADR by SHA-256 `fec51fd8de846628907f28b5b531d612ff767f84c0ab30428792b9db4759423d`, verified against the file before recording acceptance. This acceptance establishes scope and direction, not implementation or shipping permission.

**Decision owner:** Dikta maintainer.

**Scope:** The first native macOS Read Aloud migration. “V1” means this migration's first iteration, not an application release number. Windows and dictation engines are unchanged.

## 1. Purpose and decision

Replace the Python/venv/pip and local HTTP Read Aloud runtime with native Kokoro. Preserve the existing hotkey, selection handling, voice choice and reliable Stop behavior. Make ordinary long selections start progressively, and avoid leaving the native models resident indefinitely.

The user has chosen a native-only new release, one-time asset download through Setup, Heart in the initial setup, explicit optional voice downloads, and older-app installation as rollback. Approximately three known users make a clean cutover preferable to maintaining two backends.

The selected v1 direction is a **bundled, directly owned, separately sandboxed Swift helper**, using the existing pinned FluidAudio SDK. Dikta owns selection, request identity, playback and user-visible state; the helper owns model initialization, the SDK English frontend and synthesis. The app stays unsandboxed. The helper runs without sandbox inheritance or networking entitlements.

There is enough evidence to approve this direction and proceed to a bounded implementation plan. Shipping qualification is still required. Remaining practical uncertainties belong in the first implementation slice, not another open-ended discovery round.

## 2. Scope and non-goals

### Required for v1

- Native-only Read Aloud: no Python installation, bundled server, backend selector or Python fallback in the new app.
- One-time verified Setup download for models, English frontend assets and Heart; truthful failure, cancellation and retry.
- Explicit optional downloads for voices from the existing English catalog; an uninstalled voice is not silently downloaded or substituted during speech.
- A signed isolated helper, offline inference, lazy startup and simple idle retirement.
- Ordered progressive delivery of ordinary long English selections within the SDK's limits.
- Prompt playback Stop, stale-result rejection, safe helper retirement and successful subsequent reading.
- Preserve current selection/hotkey behavior and dictation state.
- Required license/notice inclusion, Release validation and a practical old-release rollback route.

### Not part of v1

- A custom strict frontend, SDK fork or dependency upgrade solely to guarantee pronunciation/word fidelity for every possible input.
- Exhaustive treatment of pathological tokens, arbitrary documents, multilingual text or every Unicode combination.
- New languages, new voice IDs beyond the current catalog, voice cloning or configurable advanced speech controls.
- Sample-level streaming, a new audio engine, shared-memory transport or multiple runtime backends.
- Broader hardware/OS qualification, a benchmark framework, precise performance SLAs or extensive per-voice parity studies.
- Historical provenance reconstruction as a separate research project, unrelated cleanup or removal of users' legacy installations.

These exclusions do not permit the application's chunker to silently truncate a selection, unsafe process control, hidden networking, missing required notices or ignoring a reproducible failure on the agreed ordinary-use acceptance set.

## 3. Evidence supporting the decision

### Existing integration seam

Inspected production code provides a small injectable `TextToSpeechSpeaking` interface. `MenuBarViewModel` already checks request identities after asynchronous selection and availability. `TextToSpeechService` combines Python startup/HTTP, WAV playback and cancellation guards. `TTSSetupManager` in `OnboardingWindow.swift` performs Python setup; `AppPaths` defines legacy paths.

Replace the concrete runtime and Setup responsibilities without redesigning unrelated application behavior. Retain the existing request guards.

### Native feasibility and comparative performance

The Xcode lock pins FluidAudio 0.17.4 at `21493f8dac5a97e65742e6ff26f42f164c2fda0f`. The application already uses it. The isolated experiment prepared 49 files, 94,759,376 logical bytes, from `FluidInference/kokoro-82m-coreml` revision `006395f65025af251858b1ab0a7178a6a1e73f9f`. Heart inference succeeded and asset hashes were unchanged.

On the user's Apple M2 Max, 32 GiB RAM, macOS 26.6.2, three warm samples per matched fixture produced:

| Fixture | Python median audio readiness | Native median audio readiness | Reduction |
|---|---:|---:|---:|
| Short | 0.253 s | 0.102 s | 60% |
| Paragraph | 0.688 s | 0.252 s | 63% |
| Pronunciation sample | 1.065 s | 0.356 s | 67% |

These are small local prototype comparisons, not production hotkey-to-audible measurements. First observed native initialization was about 10.2 s; later cached initialization was about 0.27–0.31 s. Native peak RSS was approximately 1.53–1.59 GB. Python sampling was not equivalent, so memory superiority is not established.

The user gave an okay to continue on quality after paragraph playback. A short deliberate human quality check remains necessary; the assistant cannot hear the output through its tools.

### Validation already observed

The isolated harness passed 25 Release Swift tests and 14 mocked Python lifecycle tests. Sleep-fixture ownership cleanup does not prove interruption of active Core ML prediction.

The focused signed Release application baseline passed 37 tests, zero failures, exit 0, covering TTS cancellation, stale-server PID handling, Setup commands and Read Aloud ViewModel behavior. This is historical focused evidence, not the required fresh full-suite implementation baseline.

Sources: [native smoke results](../delivery/native-kokoro/results-native-smoke.md), [matched decision sprint](../delivery/native-kokoro/decision-sprint/results.md), and [focused baseline evidence](../delivery/native-kokoro-migration/baseline/).

## 4. Runtime boundary and offline operation

The app launches and directly owns one native helper with private control/result pipes. Enable App Sandbox on the helper; omit `com.apple.security.inherit`, network-client/server entitlements and network-granting exceptions. Do not pass network sockets or expose an arbitrary URL-fetching operation through the parent. The app alone performs explicit Setup/voice downloads.

Apple Developer Technical Support explicitly describes a child of a nonsandboxed parent establishing its own sandbox by removing the inherit entitlement. This corrects the earlier discovery conclusion that XPC was required. The source and correction are recorded in [recovery/bounds discovery](../delivery/native-kokoro-migration/discovery-recovery-bounds.md).

Qualify the exact Developer-ID-signed helper identity, sandbox/container, permitted asset/cache access and actual network denial in the first slice. The experiment's `sandbox-exec` profile and SDK offline flag are not a shipping enforcement mechanism. Do not sandbox the entire app as part of this migration.

Ownership must remain valid through signalling and reconciliation. Do not kill arbitrary discovered processes or use a racy PID snapshot as authority. Parent cancellation/watchdog handling must remain independent of blocked SDK work. App shutdown, helper failure and control-channel closure require bounded owned cleanup.

If this signed boundary cannot satisfy offline access and safe retirement, stop and bring back a focused architecture proposal. Do not implement a second transport or start an unlimited repair cycle without approval.

## 5. Startup, memory and request lifecycle

Do not load native TTS merely because Dikta launched. An installed, compatible first read retains its selected text and waits asynchronously for startup; it must not require another hotkey press. Distinguish asset readiness from a loaded engine, with a small interface adjustment if needed.

Keep a warm helper during active use. Use approximately **two minutes idle after request completion** as the initial simple retirement policy. No configurable timeout or eviction study is required for v1. Retire the process, not just one model store, because frontend/model caches can remain resident.

The app owns playback and request identity. Stop invalidates ownership first, stops/clears audio and rejects late results. Cancel generation cooperatively where possible; retire only the owned helper if it does not settle within a bounded deadline. The next read must obtain a healthy session rather than wait behind abandoned inference.

Natural completion means both generation and final playback have finished. Preserve existing start/stop cues and intentional-cancellation silence. A failure after partial speech must not automatically replay the selection, change voices or switch engines. No background crash/restart loop.

Release the helper's resident state on retirement. Do not claim immediate GPU/ANE job preemption, eviction of OS-global caches or zero resource contention with dictation.

## 6. Progressive playback and supported text

Use the pinned SDK's existing English frontend and phoneme-based synthesis APIs. Work on bounded sentence/word candidates rather than phonemizing the entire selection before the first audio. Preserve ordering and meaningful punctuation; avoid repeatedly normalizing arbitrarily cut fragments.

The native synthesis bound is **510 phoneme Unicode scalars**, not source characters. The SDK also caps acoustic frames at 2,000. Unknown-word G2P has a separate 64-position encoder including BOS/EOS, allowing at most 62 normalized Swift Characters. Respect known limits and provide a clear error for unsupported input instead of silently cutting it to fit.

Synthesize serially. Start with **one playing chunk and at most one generated lookahead chunk**, plus explicit byte/work limits. Use bounded versioned pipe framing and binary WAV payloads, with request/session IDs and sequence checks. Avoid shared audio-file lifecycle complexity. Prefer prepared completion-driven `AVAudioPlayer` playback behind an injectable seam, not the current polling interval at every transition.

Check finite, bounded samples before PCM conversion and keep native output level rather than accidentally enabling peak normalization. Stop/error/interruption handling must not depend solely on a natural-finish callback.

### Accepted v1 frontend limitation

The inspected SDK can skip an unresolved word, and its decoder does not expose a structured exhaustion outcome. Application source coverage is therefore not proof of universal spoken-word fidelity. V1 does not add a strict frontend adapter or SDK patch to eliminate every such case.

Validate ordinary prose, numbers, abbreviations and representative proper names through the bounded quality set. A reproducible ordinary-use omission or unacceptable pronunciation must be reported and resolved or explicitly reconsidered before acceptance; do not call it a chunker pass. Unusual/unsupported input remains a documented limitation.

### Details deliberately left to implementation

Choose practical protocol sizes, input guards, chunk targets and startup/work deadlines during the approved slice and test their boundaries with fakes. The earlier exhaustive numerical table, split-depth budgets, 100 ms/1 s targets and custom-frontend proposals are exploratory, not frozen v1 SLAs or prerequisites for more discovery. Bounded memory/work, reliable Stop and no stale playback remain requirements.

## 7. Assets, Setup and voices

Ship the signed helper, manifests and notices in the app; download model/frontend/voice assets separately. Pin source revisions, paths, sizes and SHA-256 identities through a manifest shipped with the signed app. Verify staging before activating a complete version. Never write into the signed bundle or replace a valid installation with partial downloads.

Prepare the complete tested English frontend, including its lexicon. SDK existence checks and automatic acquisition do not replace installer verification. A missing asset is an explicit Setup/repair condition, not permission for synthesis-time download or silent pronunciation fallback.

The SDK frontend uses fixed Foundation cache paths even when the chain model directory is overridden. Qualify a permitted owned layout/private mirror early; a shared App Group is a candidate, not an already-proven requirement. Do not redirect the whole app's home or reuse Python caches as native storage.

Setup must expose download/preparation progress, failure, cancellation and explicit retry. Verified file-level reuse is sufficient; sophisticated byte-range resume is not required. Check available space for staging, retained valid assets and required cache/mirror work without pretending the historical 95 MB is the complete disk peak.

Heart is included initially. Additional voices use explicit download actions, pinned source/conversion verification and installed status. Keep the active request's voice fixed; changes apply to the next request. Optional transfers do not disable reading with Heart. Do not silently substitute Heart for a missing selected pack.

All ten existing non-Heart English voice files are present at the inspected revision, but only Heart has been synthesized in the experiment. Each offered voice needs verified preparation and a short smoke check; no extended per-voice benchmark is required. British-labelled timbres do not add a British frontend or new language setting.

Include applicable licenses, NOTICE and component/conversion attribution before distribution. Use the inspected license inventory rather than reconstructing every historical training/conversion lineage. Record stale upstream documentation and raise any material licensing issue; one-time download does not remove obligations. See [license/quality discovery](../delivery/native-kokoro-migration/discovery-licenses-quality.md).

## 8. Known Prosody risk and bounded quality response

The pinned SDK and experiment select the older Prosody graph. The pinned model repository documents a v2 fp32 graph intended to fix quiet first words on longer utterances. Previous timing/quality observations are not evidence for the fixed graph.

Include first-word onset on ordinary longer chunks in the short human quality check. Do not assume waveform validity or overall RMS proves onset quality. Do not mandate an asset migration solely because a newer file exists, and do not silently mix graphs.

If onset quality fails, propose a bounded remedy: adjusted chunking or an explicitly pinned/qualified fixed-graph mapping with the current SDK. Any changed assets need updated hashes and a small matched quality/performance recheck. SDK upgrade/fork or materially different runtime remains a separate approval. This issue is a focused acceptance check, not permission to reopen an engine survey.

## 9. Compatibility, packaging and rollback

The qualification platform is the user's **Apple M2 Max / 32 GiB / macOS 26.6.2**. Do not require surveying other users, claim wider qualification, impose an exact-model whitelist or implicitly raise the application's macOS 15 deployment target.

Block native initialization on SDK-known unsafe macOS 26.4–26.5. The absence of that warning elsewhere is not compatibility proof. Unsupported environments receive an actionable explanation; there is no Python fallback.

Embed/sign the helper in the correct nested-code order and validate the exported Release app, not just a standalone CLI. Preserve dependency/build-entry consistency and the existing SDK pin. Selected text, phonemes and audio remain local and absent from ordinary diagnostics; suppress text-bearing SDK logs and map errors to safe app-owned messages.

Rollback is the older app release. The public [v1.5.3 release](https://github.com/Sebstrdigital/dikta/releases/tag/v1.5.3) lists DMG/checksum assets; the binary/signature and downgrade path have not yet been independently tested. Verify the practical artifact and settings compatibility before cutover. Preserve installed venvs, Python caches and user data; the new app must not signal a legacy listener.

No installation, deletion, commit, publication or notarization is authorized by this ADR. In particular, `build-release.sh --no-publish` still notarizes and cleans build outputs; approve exact validation/release actions separately.

## 10. Essential acceptance gates

| Gate | Required evidence |
|---|---|
| Signed isolated runtime | Packaged helper can access prepared assets/caches, initialize Heart and synthesize; its failure does not terminate Dikta or modify dictation state. |
| Offline/privacy | Actual signed-helper network denial after Setup; missing/corrupt assets fail explicitly; no hidden downloads or spoken content in ordinary diagnostics. |
| Setup and voices | No Python needed; verified activation, truthful failure/cancel/retry, Heart initially and explicit installed optional voices; partial work leaves valid assets usable. |
| Ordinary long reading | Selections beyond one native call play progressively and in order; chunker does not lose/repeat/truncate source; buffers/work remain bounded. |
| Stop and recovery | Stop during startup/frontend/inference/playback, helper failure and a subsequent read behave safely; no stale audio/state, unsafe signalling or indefinite ownership leak. |
| Quality and responsiveness | Short human Heart check including longer-chunk onset; offered-voice smoke checks; bounded packaged-path timing comparison with Python under matched conditions. Record startup/idle memory and explain integration regressions rather than claim prototype guarantees. |
| Release and rollback | Required signed Release tests, nested packaging checks, applicable notices and verified practical rollback route. |

Use fake runtime/assets/playback in unit tests. Real models, downloads, audio, microphone, process taps and live muter controls stay outside those tests. Separate approved integration checks exercise the actual helper/playback boundary; the previous sleep fixture does not satisfy active-inference retirement.

Follow [docs/validation.md](../validation.md) before and after code changes. Establish the fresh full Developer-ID-signed Release baseline before application changes and rerun the full suite at final acceptance. Preserve full logs, actual exits, nonzero executed test counts and reported skips. Focused tests do not substitute for the full gate.

The outstanding safety hold remains: permission to quit Dikta is not permission to control WhatsApp, Slack or other muter targets. Resolve those conditions and the agreed isolated transcript fixture before full validation; do not silently omit unsafe tests and claim a pass.

## 11. Alternatives and trade-offs

| Alternative | Disposition |
|---|---|
| Python retained/fallback | Rejected: contradicts the clean-cutover decision and retains two setup/lifecycle paths. |
| In-process native inference | Rejected for v1: exposes Dikta to uncatchable native failures and offers no independent forced retirement. |
| Directly owned sandboxed helper | Selected direction: supports isolation and owned shutdown, at the cost of packaging, IPC, cache access and ownership implementation. |
| XPC service | Retained only as a revisit option if the selected boundary fails. Its launchd-owned lifecycle adds retirement/restart questions; no second implementation now. |
| Bundled models | Rejected by the Setup-download choice; initial installation consequently needs networking. |
| Other engine or strict custom frontend | Deferred: broader evaluation/maintenance is not justified for this first migration. |

Expected benefits are simpler installation/runtime responsibilities, progressive reading and the observed opportunity for better warm responsiveness. Costs include substantial model memory, first-use loading, another signed executable and retained SDK pronunciation/Core ML limitations. Isolation reduces failure impact; it does not eliminate resource contention or prove quality.

## 12. Implementation outline, not a task breakdown

The following are candidate acceptance milestones, not approved task packets:

1. **Runtime foundation and qualification:** signed owned sandboxed helper, prepared Heart assets, offline access, failure isolation and retirement/restart. Stop here if the architecture cannot qualify.
2. **Setup and asset lifecycle:** verified base preparation, explicit optional voices, readiness/compatibility, retry and safe activation.
3. **Basic native Read Aloud integration:** existing hotkey/selection/interface path, startup waiting, ordinary short speech, request guards and feedback.
4. **Progressive playback and lifecycle:** ordinary long selections, bounded lookahead, Stop at each phase, late-result rejection, idle retirement and recovery.
5. **End-to-end acceptance and cutover:** packaged quality/timing checks, required Release validation/notices and rollback verification.

Each part can be implemented and accepted separately. **All required parts and final gates must pass before the migration is complete.** Foundation precedes wider integration; final acceptance follows the integrated result. No partial milestone is a shipping decision.

The detailed breakdown follows acceptance of this ADR: define bounded tasks, dependencies, allowed paths, tests, environment permissions and stopping rules. Select the execution mode explicitly and approve its work contract before implementation/delegation. The repository recommends takt planning for multi-story work; this record neither selects a worker mechanism nor launches one.

## 13. Authority and retained discovery records

The user authorized finalizing this bounded-v1 ADR and subsequently accepted it through the submitted decision review, not application changes. The older working plan and detailed discovery notes remain evidence; their broader strict-frontend requirements, proposed numerical limits and research tasks do **not** expand this scope. This ADR is the scope authority for the subsequent breakdown once accepted.

Supporting records: [runtime/assets](../delivery/native-kokoro-migration/discovery-runtime-assets.md), [license/quality findings](../delivery/native-kokoro-migration/discovery-licenses-quality.md), [sandbox correction and exploratory recovery/bounds](../delivery/native-kokoro-migration/discovery-recovery-bounds.md), and [optional voice metadata](../delivery/native-kokoro-migration/voice-catalog-discovery.json).

Preserve unrelated working-tree changes, `debug-active.md`, build backups, existing experiments/assets and legacy user installations. No builders, code edits or further experiments are authorized by finalizing this document.
