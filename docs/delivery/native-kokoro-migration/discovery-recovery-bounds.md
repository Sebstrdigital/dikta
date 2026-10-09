# Discovery: isolation correction, recovery and resource bounds

Status: proposed engineering policy, not approved code or measured performance. No builds, model execution or application/process control were performed in this discovery. Numerical defaults below are reviewable starting policies, not properties derived from benchmarks.

## 1. Correction: separate sandbox does not require XPC

The earlier XPC recommendation relied too broadly on an archived XPC guide and current instructions for a helper INHERITING a sandboxed host's policy. Dikta's host is NOT sandboxed, which matters.

Apple Developer Technical Support's Quinn, **Resolving App Sandbox Inheritance Problems**, explicitly addresses a nonsandboxed parent launching a child with both sandbox and inherit entitlements. Under “Nothing to Inherit,” it gives three remedies; the third is:

> “Run the child in its own sandbox by removing the com.apple.security.inherit entitlement.”

Primary post: https://developer.apple.com/forums/thread/706390

The direct page's readable extraction was incomplete. The post text, author attribution and link were successfully retrieved from Apple's own forum listing at https://developer.apple.com/forums/tags/notarization/?page=5&sortBy=oldest&sortOrder=DESC . Session evidence `muyssi1nf195at` reproduces both the “Changing Sandbox” and “Nothing to Inherit” sections. A search-generated summary alone was not used as proof.

**Revised recommendation:** a directly owned, separately App-Sandboxed native executable, with NO sandbox-inherit entitlement, NO network-client/server entitlement and NO network-granting exceptions. Keep the parent unsandboxed. Use signed entitlements rather than shipping sandbox-exec. This returns to the lifecycle boundary wanted originally while adding a documented sandbox route.

This remains a candidate, not proof that its code identity, container, App Group and Core ML access work in the exported Developer-ID-signed app. The first approved Delivery slice must qualify those exact conditions, denial and forced retirement/restart. Bare-tool bundle identity/private-container layout is part of that gate.

A parent-allowed read/write pipe does not constitute a networking API: the host must not offer the worker arbitrary URL/file operations. The download installer is a separate explicit app action.

### XPC remains an alternative, with a real restart question

The locally installed `launchd.plist(5)` documents ThrottleInterval and a general default policy of not spawning jobs more than once every 10 seconds. This does NOT establish the exact throttling policy of this hypothetical bundled XPC service. It does establish that prompt restart is not implied by “launchd restarts services.” An XPC design would need its own retirement, throttling and restart qualification and cannot assume an unsupported Info.plist override solves it.

There is no reason to incur that launchd-owned lifecycle if the directly owned sandboxed child passes qualification. Do not survey more IPC engines or implement both backends. If the preferred boundary fails, stop and revisit the ADR.

## 2. Independent state dimensions

Avoid a single state enum that falsely makes generating and playing mutually exclusive.

| Dimension | Proposed states / meaning |
|---|---|
| Base assets | absent; staging; verifying; ready(version); repairRequired. Warm model state is NOT included. |
| Compatibility | eligible; knownUnsafeOS; unqualified/unsupported architecture/runtime. A missing known-warning is not broad OS qualification. |
| Optional voice | absent; downloading; verifying/converting; installed(version); failed/cancelled. Heart remains usable while another voice downloads. |
| Worker session | absent; starting(epoch); ready(epoch); active(epoch); retiring(epoch, reason); failed. Every spawned session has independent ownership. |
| Read request | accepted; awaitingStartup; frontend; generating; drainingPlayback; completed; cancelled; failed. Generation can continue while playback runs. |
| Playback | empty; prepared/playing(sequence); optional queued next(sequence); interrupted/failed. Owned by the app/request, not the worker. |

Readiness should mean verified compatible assets/selected voice, NOT a running loaded engine. Recommend a small typed readiness result at the injectable TTS seam (needsSetup, needsRepair, voiceNotInstalled, unsupported, readyToStart), replacing ambiguous server-loading UX. `speak` then waits through lazy startup. Preserve ViewModel request guards after every await; a stale readiness result must not notify/start audio.

SDK warmup is separate from Setup download readiness. Report loading accurately without requiring a second hotkey press. `speak` completes only after generation has ended AND the final accepted chunk has finished playing. The existing natural-stop feedback must not move to “last chunk generated.”

## 3. Event / recovery policy

| Event | App action | Owned worker/installer action |
|---|---|---|
| First read, valid assets | Retain selection/request and show loading; wait asynchronously | One lazy startup; verify protocol/assets and selected voice before inference |
| Stop during selection/startup | Invalidate request first; cancellation is silent | Cancel startup work or retire only that spawned session; no late audio |
| Stop during speech | Stop player, clear queue/credits, invalidate request | Cooperative cancel; parent watchdog retires the unreaped owned child if it cannot settle |
| New request during old retirement | Permit at most one pending latest request, cancellable; do not queue an unbounded history | Finish old owned reconciliation before replacement; never route new work into abandoned inference |
| Unexpected child exit / malformed protocol | Stop current playback; one safe actionable error; remain usable for dictation | Reconcile that session, not an arbitrary discovered PID. No background respawn/crash loop |
| Failure after partial speech | Stop and say reading failed; no automatic whole-text replay | Close/invalidate this request; leave valid asset installation intact |
| Natural generation completion | Drain existing audio, then finish request normally | May become idle; no eviction while accepted audio/work is still outstanding |
| Idle retirement | Expected event, no error notification | Proposed two-minute timer after request completion; release the process, including G2P singleton residency |
| Missing/corrupt asset | Open explicit repair path; no fallback engine/download during reading | Do not initialize SDK; preserve any valid version |
| Optional download cancellation | Leave previous voice/base readiness unchanged | Cancel current transfer; retain verified completed files for explicit retry |
| App shutdown / unexpected parent disappearance | Cancel queues and close owned control channels | Worker EOF/watchdog path must work independently of blocked synthesis; owned reconciliation only |

No automatic retry of a failed spoken request in the first implementation. The next explicit user request may start a healthy worker; persistent reproducible failures require actionable repair, not endless respawning. Expected Stop/idle retirement callbacks must never be relabelled as crashes.

A raw PID and a Process.isRunning snapshot are not sufficient signal authority. The spawn/reaper design must keep ownership valid until signalling/reconciliation ends; do not race automatic reaping followed by a raw kill. Process-group cleanup, if used, additionally requires a positively established owned group/session boundary. Register ownership before failing operations; close unneeded inherited descriptors. Do not copy the experimental Python guardian into the shipping runtime.

Failure isolation protects Dikta's state/process; it is not a promise that a 1.6 GB engine consumes no CPU/GPU/memory resources used by dictation. Qualify contention rather than altering dictation's runtime.

## 4. Proposed bounded transport

Use private parent/child pipes with a versioned length-prefixed header and bounded binary payload, not newline-delimited unbounded JSON or base64 WAVs. Metadata can be small typed JSON; text and WAV bytes are binary payload kinds with separate bounds. Reserve stdout for the protocol; configure/sanitize diagnostics independently.

Validate header lengths BEFORE allocation, allowlisted message types, protocol/session/request identity, exact payload length, sequence order and metadata values. Support partial reads/writes and truncated EOF. A stale old-session callback must not close a newer session's pipe or release its queue.

Pipe writing can block under backpressure. Use bounded asynchronous ownership and a dedicated I/O path, not the main actor or a blocking task on Swift's cooperative pool. Cancellation/control must not wait for a blocked large audio write; the parent-owned retirement watchdog is outside SDK execution. App acknowledgement follows playback consumption/invalidation, not receipt. Reserve at most two outstanding chunk credits: one playing and one lookahead.

Exact framing/endian fields belong in the approved shared protocol specification; no protocol source was written here.

## 5. Candidate numerical policies

| Resource | Candidate bound | Rationale / qualification |
|---|---:|---|
| Selected text | 1 MiB UTF-8 | Explicit whole-request memory cap; reject with a smaller-selection message, never truncate. This is a new product limit requiring ADR agreement. |
| Frontend candidate | 4 KiB UTF-8 AND at most 64 lexical tokens | Bound one normalization/G2P call; prefer much smaller early candidates. Tokens/entities must follow the chosen strict frontend, not a naive whitespace splitter. |
| Fallback word | At most 62 normalized Swift Characters | Derived from the inspected 64-position encoder with BOS/EOS; conservative raw-token rejection/normalization rules still need the strict-frontend decision. Does not prove decoder EOS completion. |
| First/later audio target | About 120 / 240 phoneme scalars | Proposed latency/prosody balance, not measured. Native hard bound remains 510; do not split inside a phoneme word. |
| Native acoustic frames | At most 2,000 | Actual pinned SDK cap; phoneme count alone does not guarantee it. |
| Audio chunk | At most 30 seconds, 24 kHz mono PCM16 | Proposed output/sample bound; genuine model frame overflow or oversized output needs bounded word-boundary splitting, not truncation. |
| WAV payload | At most 2 MiB; at most 4 MiB outstanding WAV payloads | 30 s × 24,000 × 2 + 44 = 1,440,044 bytes, below 2 MiB. Queue has at most two chunks/60 s. Copies/decoded buffers must also be observed; this is not a whole-process RSS cap. |
| Protocol metadata | At most 16 KiB per header | Text/audio live in separately bounded binary payloads; no arbitrary error strings/collections. |
| Startup | 60 s deadline | Proposed hang guard; observed first init ~10.2 s is not a universal upper bound. |
| Single frontend/synthesis work unit | 30 s deadline | Proposed hang guard, NOT a 30-second limit on the whole spoken selection. Stop remains independent. |
| Audible stop / owned reconciliation | 100 ms / 1 s goals | Previously proposed engineering targets, requiring real qualified playback and owned-child checks. |
| Idle eviction | Approximately 120 s | Proposed warm-reuse compromise; qualify races and process-memory release. |

Oversized phoneme/audio chunks are split at existing meaningful word boundaries with cached normalized phonemes, preserving order and punctuation. Put explicit ceilings on split depth/work attempts (candidate maximum depth 8 and 32 synthesis attempts per frontend candidate); an atomic token or exhausted budget fails explicitly. These numbers are proposed guards, not permission for a repair/benchmark loop. Validate ordinary text fits without pathological retry.

Normalize only bounded source candidates, once per candidate; partition their produced phonemes without rerunning normalization on arbitrarily cut subphrases. Keep source-candidate identity/range even when it emits several audio chunks. Scan the bounded whole input cheaply for unsupported pathological tokens before audio; do not phonemize the whole selection up front. This plan still needs the strict frontend outcome API identified in `discovery-licenses-quality.md`; normal candidate coverage is not proof of SDK word fidelity.

## 6. Audio safety

SDK `Shared/AudioConverter.swift`, `AudioWAV.data`, produces PCM16 mono and defaults to peak normalization. Its Kokoro manager passes normalize=false. Keep native-level output; do not accidentally adopt the helper's default normalization.

Use detailed synthesis results to check expected sample rate, positive bounded sample count, finite samples and valid/nonzero signal before PCM16 conversion. The converter casts to Int16; feeding NaN/Inf is not safe. Bound duration before allocating/transferring WAV Data. Receive-side format/size validation is separate. These production WAVs differ in encoding from the experimental float32 WAVs; preserve a small quality/level check, not an assumption of byte parity.

## 7. Setup retries, disk and activation

Proposed minimal resume behavior: FILE-LEVEL verified resume, not fragile opaque cross-launch HTTP resume blobs. Persist a pinned-manifest-owned staging job and reuse already complete/hash-valid files on explicit Retry. Re-download an interrupted file; progress distinguishes transferred bytes from verified/reused completion. One serialized installer owns activation (including across app instances through a kernel-owned file lock, not discovered-PID signalling). Optional voice jobs leave base readiness unchanged.

Use URLSession streaming/download-to-file, bounded HTTPS redirects, an ephemeral session without cookies/credential storage, no selected-text inputs and bounded retries. Network errors/denied permissions/disk-full/cancel are truthful states. Redirect host/trust policy must account for actual HF delivery without accepting local/file/downgrade URLs. Verify hashes against the manifest shipped in the signed app, not a freely replaceable downloaded manifest.

The historical base manifest totals 94,759,376 bytes. Its fixed-cache frontend subset is 12,015,574 bytes, and largest single file is 48,889,920 bytes. Therefore a shared canonical chain plus private frontend mirror is a plausible approximately 107 MB logical-storage layout; duplicating all models is not automatically necessary. It remains a signed cache-access qualification question. A corrected Prosody manifest changes these numbers.

Space checks account for missing staging files, the old valid version retained during activation, required private mirror, temporary-file move/copy peak and separate Core ML cache headroom. Measure cold-init disk demand before fixing the cache allowance. APFS clone/dedup savings are not guaranteed free-space credits.

Activation replaces only a complete verified version pointer/marker after all required paths and compatibility checks pass. Active requests retain a stable asset version; optional pack activation cannot change an active request's chosen voice. A partial transfer or migration failure never overwrites valid assets. Cleanup authority is limited to owned job/cache paths and separately approved runtime policy. No legacy venvs, unrelated user data or experiment assets were deleted during discovery.

## 8. Remaining joint decisions / execution gates

- Accept the revised owned separately sandboxed helper recommendation and numerical defaults, or adjust them.
- Resolve strict frontend diagnostics and fixed Prosody mapping without an unapproved SDK change.
- Finalize notice/provenance treatment.
- Then accept the ADR/implementation plan and approve a Delivery contract. Its first bounded qualification uses real signed packaging, exact entitlement denial/cache access, corrected assets, stop/restart and app-owned lifecycle evidence. If it fails, stop/revise rather than implementing both transports.
- Resolve full-app muter/test-fixture safety before any application code change. Existing 37 focused tests do not satisfy that gate. No builds/probes/builders begin during this discovery phase.
