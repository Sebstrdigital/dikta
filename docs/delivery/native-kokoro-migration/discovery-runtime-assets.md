# Discovery: production isolation and pinned SDK asset behavior

Status: inspected-source and primary-documentation findings only. **Sandbox recommendation superseded:** the later specific Apple DTS evidence in [recovery/bounds](discovery-recovery-bounds.md) supports a separately sandboxed owned child of an unsandboxed host. This document retains the earlier XPC reasoning as history, not the current selected recommendation. No new code, signed targets, downloads of model/voice weights, processes, probes or builders were introduced during this discovery. Public documentation/model-card text was retrieved read-only. Proposed designs still require ADR approval and runtime qualification.

## 1. Asset loading is not just a model-directory override

SDK checkout: `dikta-macos/.build/checkouts/FluidAudio`, revision pinned by the Xcode lock to `21493f8dac5a97e65742e6ff26f42f164c2fda0f` (0.17.4).

- `Sources/FluidAudio/TTS/Shared/TtsCacheDirectory.swift`, `ensure()`: on macOS the path is `FileManager.default.homeDirectoryForCurrentUser/.cache/fluidaudio`. The Models subtree is added by consumers.
- `TTS/KokoroAne/KokoroAneManager.swift`, `initialize()`, lines 67–113: the Core ML chain uses the supplied store directory, but English G2P and lexicon preparation explicitly receive `directory: nil`. The comment explains that `G2PModel.shared` reads the fixed default cache.
- `TTS/G2P/G2PModel.swift`, `loadIfNeeded()`: expects `Models/<Repo.kokoro.folderName>/g2p_vocab.json` and the encoder/decoder under the default cache. It loads models lazily and retains them in a process-wide singleton.

Consequence: asset setup needs BOTH the chain and frontend in locations visible to the inference process. Redirecting HOME/CFFIXED_USER_HOME worked for the nonsandboxed experimental worker, but does not prove what Foundation returns in a sandboxed XPC service. Use the service's actual container/cache location or a verified supported mapping. Do not promise that the existing override will work unchanged.

A shared App Group is a supported candidate transfer/storage boundary between the unsandboxed application and sandboxed service. The fixed frontend cache may require a private verified materialization inside the service container. Exact layout, duplication cost and activation behavior remain runtime-qualification requirements.

## 2. SDK acquisition does not satisfy product setup requirements

Inspected `Shared/AssetDownloader.swift`:

- `ensure()` checks only file existence on its skip path, not hash integrity.
- It calls the supplied/default `URLSession` directly for data/download transfers.
- `fetchData()` also performs direct session requests; there is no offline check there.

Inspected `KokoroAneResourceDownloader.swift`:

- `ensureModels()` first invokes cache repair, then checks required path existence and calls ModelHub if incomplete.
- `ensureEnglishLexicon()` tries acquisition and catches failures, returning nil; the frontend can proceed with BART-only G2P. The SDK considers the lexicon best-effort.
- `ensureVoicePack()` accepts an existing binary by existence, otherwise attempts the variant binary URL and then English JSON conversion/download.

Inspected `ModelRegistry.swift`, lines 98–131: a revision override facility exists, but `resolveModel(repo,file,revision: "main")` constructs its URL directly from that revision argument and does not call the revision-mapping helper. The voice/lexicon callers above supply no revision. Do not assume the package lock or the revision-overrides property pins all these direct asset requests.

Recommendation: the app's Setup/voice installer owns immutable manifest-driven acquisition, validation and activation. Do not use SDK automatic downloading as the product installer. Inference preflight treats the English lexicon as REQUIRED for stable tested pronunciation, although the SDK itself does not. Pinning plus operating-system network restrictions guards against fallback requests rather than allowing them to fetch mutable upstream content.

`KokoroAneModelCacheMigration.swift` additionally moves/repairs old compiled bundles before the loader's ordinary existence shortcut. It checks `FlexibleShapeInformation` in `model.mil`, can download replacements, and rolls back on error. Include the relevant compatibility check in preparation/preflight so inference never enters a repair path for an accepted immutable asset version. No SDK source patch is currently proposed.

## 3. Optional voice acquisition can be explicit and lightweight

`KokoroAneVoicePack.swift` provides public `load(fromJSON:)` and `binaryData`. The JSON contains rows keyed 1 through 510, each with 256 numbers. The binary is 510 × 256 × 4 = 522,240 bytes. That binary size is derived from inspected constants/layout, not a measurement of JSON transfer size.

This permits explicit app-side conversion after a user requests a voice download, without loading the seven-model inference chain just to prepare a pack. Validate allowed voice ID, source hash, row/column count, finite representable values, output length and derived binary hash. Source and derived provenance must be recorded.

The candidate initial catalog is the existing English voice set, excluding Heart which is already in base setup. Offering a name still requires confirming the file/license at the chosen immutable repository revision and a quality smoke check. A selected but absent/corrupt voice causes an explicit repair/Heart-choice UX, not a hidden SDK download or silent substitution during speech.

Install changes must not mutate a file already used by an active request. Selection becomes effective on the next request. Runtime cannot expand a shared cache through network requests.

## 4. Apple's documented privilege-separation direction

### A. Separately sandboxed XPC services

Apple, **Creating XPC Services**, “Security” / “Understanding the Structure and Behavior”:

> “Other mechanisms for dividing an application into smaller parts, such as NSTask and posix_spawn, do not let you put each part of the application in its own sandbox, so it is not possible to use them to implement privilege separation. Each XPC service has its own sandbox...”

> “XPC services are managed by launchd, which launches them on demand, restarts them if they crash, and terminates them (by sending SIGKILL) when they are idle.”

> “By default, XPC services are run in the most restricted environment possible—sandboxed with minimal filesystem access, network access, and so on.”

Source: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html

This is an archived guide; current entitlement documentation below supplements it. It supports recommending a separately sandboxed service, not assuming every detail of its idle/cancellation behavior has been proved for this app.

### B. Command-line inheritance is a different design

Apple, **Embedding a command-line tool in a sandboxed app**, describes a tool whose entitlements include JUST `com.apple.security.app-sandbox` and `com.apple.security.inherit`; adding other entitlements can cause signing failures. Its example requires a sandboxed host.

Source: https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app

Retrieved primary document JSON: https://developer.apple.com/tutorials/data/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app.json

Dikta is currently unsandboxed. Inheritance is not a way to establish a new sandbox when the parent has none. Later specific Apple DTS guidance explicitly supports a child establishing its OWN sandbox with the inherit entitlement removed; the archived/general guidance above does not rule out that case. Sandboxing the whole app would enlarge this project into accessibility/audio/filesystem entitlement migration, which is not the selected scope.

### C. Network entitlement boundary

Apple, **com.apple.security.network.client**:

> “A Boolean value indicating whether your app may open outgoing network connections.”

> “Use this key to allow your sandboxed app to connect to a server process running on another machine, or on the same machine.”

The document distinguishes TCP connection initiation from subsequent data flow and UDP behavior. The proposed service has neither network-client nor network-server entitlements, no inherited network sockets and no network-granting exceptions. The unsandboxed app remains responsible for explicit Setup downloads. Verify actual Foundation/raw network denial in the signed service; entitlement inspection alone does not qualify the whole implementation.

Source: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client

Primary JSON: https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.security.network.client.json

### D. Shared local storage without sandboxing the entire app

Apple, **Configuring app groups**:

> “In macOS, app groups can facilitate communication between sandboxed apps, and between sandboxed and nonsandboxed apps.”

The document describes group-container lookup through `containerURL(forSecurityApplicationGroupIdentifier:)` and the macOS naming form `<Developer team ID>.<group name>`, where access is checked against the signing Team ID. This is a candidate for signed local shared storage, not approval to register/change signing capabilities now.

Source: https://developer.apple.com/documentation/xcode/configuring-app-groups

Primary JSON: https://developer.apple.com/tutorials/data/documentation/xcode/configuring-app-groups.json

Do not confuse App Group naming rules for global Mach IPC with the naming/embedding of an ordinary private bundled XPC service. Exact Developer ID entitlement/provisioning and current OS access must be verified for the selected layout.

## 5. Historical XPC recommendation — superseded

This discovery initially favored a **bundled sandboxed native XPC service**. The later Apple DTS post distinguishes a nonsandboxed parent's independently sandboxed child from an inherited sandbox. The current ADR therefore again prefers a **directly owned separately sandboxed Swift helper without inherit/network entitlements**, subject to signed qualification. See `discovery-recovery-bounds.md` for exact primary evidence and the correction.

If XPC is later reconsidered, its following ownership trade-offs still apply; these are not requirements to build an XPC target now.

However, this is NOT a free replacement for the owned executable lifecycle proven in the benchmark:

- The XPC service is launchd-owned, not an unreaped child Process the app can safely signal.
- Connection invalidation/interruption is not proof that active Core ML prediction has stopped or memory is released.
- No arbitrary PID-based killing of the service is proposed.
- Cancellation and watchdog processing must remain runnable independently of the synthesis work. A service-side bounded self-retirement path is a candidate, but must be qualified during actual frontend/prediction work.
- The app must silence playback and reject stale events immediately regardless of service cancellation success.
- Prove how a subsequent request obtains a fresh healthy service after retirement, and how explicit idle retirement releases singleton/model memory. Do not rely solely on unspecified launchd idle timing.

Current first Delivery slice, only AFTER ADR/contract approval: a minimal signed OWNED SANDBOXED HELPER with actual cache access, Heart offline inference, denial probes, parent-owned forced retirement and a subsequent healthy request. Bound that slice and stop if it cannot satisfy isolation/lifecycle requirements; do not build the installer/playback UI first and discover the architecture fails later.

Paper discovery cannot honestly prove sandboxed Core ML/cache compatibility or hard-stop/restart timing for either boundary. Preserve those as explicit qualification gates, not hide them in an “implementation detail.”

## 6. Resource/playback proposals for the ADR

Candidate defaults to evaluate, not acceptance facts:

- Lazy startup on first read; retain for approximately two minutes of idle time, then retire the entire service, not merely clear the chain store. G2P singleton caches can otherwise remain resident.
- Serial inference; one playing chunk plus at most one synthesized lookahead chunk. Define a byte/duration budget as well as count, since two pathological chunks can still be large.
- Sentence/word-aware candidates with a softer early-chunk goal below the hard 510-phoneme cap, without large up-front whole-selection G2P.
- Completion-driven prepared playback rather than carrying the current 100 ms polling interval across every chunk transition.
- Per-session/request IDs, strict chunk sequence and consumer acknowledgement/backpressure. With XPC, prefer bounded WAV Data payloads over per-chunk files: avoid shared audio paths, artifact cleanup and filesystem races while retaining a small audio queue. Measure actual transfer/decoding cost before freezing this choice.

The local Apple SDK header `AVFAudio.framework/Headers/AVAudioPlayer.h` confirms `initWithData:error:`, `prepareToPlay`, `playAtTime:` and `audioPlayerDidFinishPlaying:successfully:`. These support a completion-driven prepared Data playback implementation behind the existing injectable player seam without requiring an AVAudioEngine redesign. The header also warns that Stop blocks while releasing audio hardware and that the normal completion delegate is not called for an interruption. Therefore, explicitly clear state on Stop/error/interruption rather than waiting for a finish callback, and qualify real stop latency; fake tests cannot prove a 100 ms physical-silence target.

Measure pause quality, first-audio latency, peak/idle memory and stop/restart before freezing the numerical policies.

## 7. Licensing progress and remaining gap

The pinned model-card text advertises `license: apache-2.0` and `base_model: hexgrad/Kokoro-82M`:

https://huggingface.co/FluidInference/kokoro-82m-coreml/raw/006395f65025af251858b1ab0a7178a6a1e73f9f/README.md

The requested root LICENSE path at that revision returned “Entry not found”:

https://huggingface.co/FluidInference/kokoro-82m-coreml/raw/006395f65025af251858b1ab0a7178a6a1e73f9f/LICENSE

FluidAudio's local LICENSE identifies Apache 2.0. Subsequent discovery FOUND `ANE/LICENSE` at the pinned revision (Apache-2.0, Copyright 2026 laishere); the adjacent ANE README claims MIT, requiring documented notice treatment. See `discovery-licenses-quality.md` for the expanded component inventory. These findings are provenance, not a completed final license/NOTICE distribution. The model card's historical benchmark claims are NOT imported as measured Dikta results.

## 8. Optional voice availability and current UI

A read-only tree listing at the SAME immutable model revision confirms files for all ten non-Heart voices in the current app: Bella, Nicole, Sarah, Sky, Adam, Michael, Emma, Isabella, George and Lewis. Metadata is saved in `voice-catalog-discovery.json`. JSON transfer sizes are approximately 2.67–2.68 MB EACH; the converted binary is 522,240 bytes. Repository `oid` fields are Git blob identifiers, not content SHA-256 hashes. No optional voice data was downloaded, converted or synthesized in this discovery, so payload hashes, conversion outputs, detailed licensing and quality remain unqualified.

Primary metadata URL: https://huggingface.co/api/models/FluidInference/kokoro-82m-coreml/tree/006395f65025af251858b1ab0a7178a6a1e73f9f/voices?recursive=false

`Views/MenuBarView.swift` lines 401–414 currently lists every `KokoroVoice` as directly selectable. `MenuBarViewModel.setTtsVoice` immediately changes the runtime voice and reports “Voice Changed”; it does not prepare assets. For the new product, recommend keeping installed voices directly selectable and adding a Manage/Download Voices action for the uninstalled catalog. Downloading a voice must not report it as selected until verified preparation succeeds. Base-installed and per-voice download states are separate so an optional transfer does not block reading with Heart. Selection during speech affects the next request only. No new persistent voice preference is assumed from the existing setter.

## 9. Older-release rollback metadata

The installed app plist and Xcode version settings both report 1.5.3. The public GitHub releases API currently lists v1.5.3 as a non-draft, non-prerelease release with an uploaded `Dikta-1.5.3.dmg` asset (504,014,172 bytes) and a SHA256SUMS asset. This confirms the previous-version download is advertised publicly, not merely assumed from a Git tag.

- Release: https://github.com/Sebstrdigital/dikta/releases/tag/v1.5.3
- DMG: https://github.com/Sebstrdigital/dikta/releases/download/v1.5.3/Dikta-1.5.3.dmg
- Metadata source: https://api.github.com/repos/Sebstrdigital/dikta/releases?per_page=3
- Advertised DMG digest: `sha256:5951de59f779d12b8d356ed359ee183d43e2fb20773706bb070df1593027ae09`.

The 504 MB binary was NOT downloaded, independently hashed, signature-checked or reinstalled. Release notes describe Developer ID signing/notarization, but this discovery does not independently verify the binary's signature. Preserve the release/checksum links; verify the actual rollback artifact and downgrade behavior at cutover rather than downloading/installing it during read-only discovery. No release or user installation was modified.

## Evidence retrieval references

Primary documentation/model-card retrievals in this session: `muyr0no22baa1y` (archived XPC guide), `muyr0vaqdhwlkx` (Apple primary JSON documents), `muyr3rbabddit5` (pinned model-card/LICENSE response). These IDs aid session retrieval; stable URLs and exact passages above are the durable references. Search-provider summaries were discovery leads, not treated as primary proof.
