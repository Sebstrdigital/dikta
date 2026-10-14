# TTS download redirect outcome — v1.5.8

## Outcome

Investigation of issue #28 demonstrated a transport blocker matching the reported error: `NativeKokoroRedirectPolicy` refused the exact HTTPS redirect host `us.aws.cdn.hf.co`. The friend's failing setup has not been reproduced end-to-end, so this is not a claim of confirmed sole causality. The policy now allowlists that observed host explicitly. It continues to require HTTPS, an absent explicit port, and an exact host match; no wildcard or relaxed redirect rule was added. Pinned manifest, expected-size, and SHA-256 checks are unchanged.

Debug and Release marketing/build versions are both `1.5.8`.

## Evidence

Lead public-fixture verification is retained outside the repository at `/Users/sebastianstrandberg/work/artifacts/dikta-tts-1.5.8/lead-public-asset-check.json` and `lead-public-asset-summary.json`: all 49 public pinned assets passed size and SHA-256 validation (94,759,376 bytes total); observed final hosts were only `huggingface.co` and `us.aws.cdn.hf.co`; 29 assets were blocked by the former policy.

The standalone optimized Swift URLSession probe retained alongside those files reproduces the first pinned asset through the real redirect delegate: `live-transport-old.log` exits 1 with `InstallError.transport`; `live-transport-narrow-fixed.log` exits 0, returns 243 bytes, and matches the pinned SHA-256. It did not launch the app/helper or alter local caches.

Focused XCTest coverage exercises both `NativeKokoroRedirectPolicy.allows` and its `URLSessionTaskDelegate` redirect callback. It accepts the observed CDN redirect and refuses an unrelated host, HTTP, and an explicit HTTPS port.

## Validation

Full command output and exit status are retained at `/Users/sebastianstrandberg/work/artifacts/dikta-tts-1.5.8/`. The final signed Release filtered suite uses exactly the four documented real-muter exclusions and completed with exit 0: 749 tests executed, 11 tests skipped, and 0 failures. The four excluded real-muter absence checks remain coverage gaps; the 11 reported skips are test-controlled skips in the selected suite, not additional command exclusions.

## Review and packaging

Independent integrated review approved the technical candidate; its sole documentation blocker (unconfirmed sole causality) was corrected and independently re-reviewed with approval. No production changes followed that review.

The standard `build-release.sh --no-publish` completed with exit 0, without skipping tests. Its renewed signed Release filtered gate passed 749 tests, 11 test-controlled skips, and zero failures with the same four documented exclusions. All 179 tracked macOS file hashes matched the pre-package snapshot after packaging.

- Retained artifact: `/Users/sebastianstrandberg/work/artifacts/dikta-tts-1.5.8/Dikta-1.5.8.dmg`
- Size: 76,133,637 bytes
- SHA-256: `2f44ce8b91d1c466d56fc17d359c7fbedad3838207c89da0c6d424bc35a75be6`
- App notarization accepted: `801b0482-92f5-40e5-b779-87bc1547be5c`
- DMG notarization accepted: `894d04ea-34e7-4a5b-b38d-89b152e17872`
- App and DMG signatures, stapled tickets, Gatekeeper assessments, and DMG integrity passed. The read-only mounted image's app matched the retained signed export's 164 tree entries (contents, modes, and symlinks); no test bundle was packaged. The task-owned image mount was detached.
- The Sparkle Ed25519 signature verified against the packaged app's embedded public key. The actual candidate's extracted optimized Swift transport also passed the live pinned-asset URLSession check.

Evidence: `package-logs/`, `verify-package.log`, `pre-package-source-sha256.json`, `packaged-app-tree.json`, `verify-sparkle.log`, and `live-transport-candidate.log` under the artifact root above. Previous local build artifacts were preserved under `preexisting-build/`; the user's installed app, settings, and assets were not changed.

## Publication completed

- Source commit and annotated release tag: `b5f76335c83832fef77a3a60d4ca2e05b0f41ba6`, `v1.5.8`. Both were pushed to origin.
- Release: [Dikta v1.5.8 — Reliable Voice Downloads](https://github.com/Sebstrdigital/dikta/releases/tag/v1.5.8), published as latest. The retained DMG was uploaded first as a draft; GitHub's recorded digest and size matched the verified artifact before publication. No rebuild or existing-release replacement occurred.
- Signed appcast commit: `34d31ecdc60cd2d19d3c51120691c303020f384e`, pushed to main only after the release asset was publicly available. All 18 prior entries were preserved; the new entry advertises version/build `1.5.8`, minimum macOS `15.0`, exact verified signature, and 76,133,637-byte asset.
- At `2026-10-14T05:24:27Z`, an anonymous full download of the public release asset matched the retained DMG's SHA-256 and size. The live [Sparkle update feed](https://sebstrdigital.github.io/dikta/appcast.xml) matched the local v1.5.8 entry exactly and contained 19 entries. GitHub Pages reported the feed commit built, and GitHub's latest release was v1.5.8.
- Receipts: `draft-release-receipt.json`, `local-appcast-validation.json`, `public-release-receipt.json`, `public-appcast.xml`, and `verify-public-release.log` under the artifact root. The installed app and local assets remain untouched.

## Gap and manual follow-up

The friend's updater-to-setup path has not yet been verified end-to-end. Ask him to update through Dikta's updater to v1.5.8, then use Text-to-Speech **Retry** in About/Setup and confirm readiness and Read Aloud. He should not need to delete the app or clear assets first. If it still fails, collect the full error and relevant diagnostics before changing his installation. The 11 test-controlled skips and four excluded checks remain coverage gaps.
