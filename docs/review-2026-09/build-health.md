# Build Health Report — dikta-macos
**Date**: 2026-09-15  
**Toolchain**: Xcode 26.6 (build 17F113), macOS 26.6.2 (build 25G83)  
**Status**: BLOCKED — compilation errors prevent test execution

---

## Commands Run

| Command | Path | Status |
|---------|------|--------|
| `swift build` | /Users/sebastianstrandberg/work/git/dikta/dikta-macos | ✓ Success |
| `swift test` | /Users/sebastianstrandberg/work/git/dikta/dikta-macos | ✓ Success |
| `xcodebuild ... -configuration Release build` | dikta-macos | ✗ FAILED |
| `xcodebuild test -project Dikta.xcodeproj -scheme Dikta` | dikta-macos | ✗ FAILED |
| `xcodebuild -list -project Dikta.xcodeproj` | dikta-macos | ✓ Success |

---

## Build Results

### swift build
- **Exit code**: 0
- **Duration**: Immediate (cache hit)
- **Errors**: 0
- **Warnings**: 0
- **Result**: ✓ PASS

### swift test
- **Exit code**: 0
- **Duration**: 5.59 seconds
- **Errors**: 0
- **Warnings**: 1
- **Result**: ✓ PASS (tests executed successfully)

#### Unhandled Resources Warning
```
warning: 'dikta-macos': found 4 file(s) which are unhandled; explicitly declare them as resources or exclude from the target
    /Users/sebastianstrandberg/work/git/dikta/dikta-macos/Dikta/Resources/MiniLML12v2.mlpackage/Data/com.apple.CoreML/weights/weight.bin
    /Users/sebastianstrandberg/work/git/dikta/dikta-macos/Dikta/Resources/MiniLML12v2.mlpackage/Data/com.apple.CoreML/model.mlmodel
    (2 more files)
```

### xcodebuild Release Build
- **Exit code**: 1 (FAILED)
- **Duration**: ~5 minutes (build phase, module emit failure)
- **Errors**: 4 (missing symbol definitions)
- **Warnings**: 0
- **Result**: ✗ FAIL (same root cause as unit tests)

### xcodebuild Unit Tests
- **Exit code**: 1 (FAILED)
- **Duration**: ~5 minutes (build phase only)
- **Errors**: 3 (compilation)
- **Warnings**: 1 (CoreSimulator + destination)
- **Result**: ✗ BLOCKED

#### Compilation Errors (Module Emit)
```
Cannot find 'TeamsMuter' in scope
Cannot find 'SlackMuter' in scope
Cannot find 'WhatsAppMuter' in scope
Cannot find 'UvenMuter' in scope
Testing cancelled because the build failed.
```

**Build Command Failures:**
```
EmitSwiftModule normal arm64 (in target 'Dikta')
SwiftEmitModule normal arm64 Emitting module for Dikta (in target 'Dikta')
Testing project Dikta with scheme Dikta
(3 failures)
```

---

## Test Results

### swift test
- **Total tests**: 68+ (multiple classes executed)
- **Passed**: All test classes passed
  - `AppConfigDecodingTests`: 5 passed
  - `AppConfigEnabledLanguagesDecodingTests`: 3+ passed
  - Other formatter/config tests: all green
- **Failed**: 0
- **Result**: ✓ GREEN

### xcodebuild test
- **Total tests**: 0 (build failed before test execution)
- **Passed**: N/A
- **Failed**: N/A (compilation blocked test phase)
- **Result**: ✗ BUILD FAILED

---

## Warnings (Deduped)

| Type | Count | Message |
|------|-------|---------|
| CoreSimulator version | 1 | CoreSimulator is out of date. Current version (1051.54.0) is older than build version (1051.55.0). |
| Resource declaration | 1 | found 4 file(s) which are unhandled; explicitly declare them as resources or exclude from the target (MiniLML12v2.mlpackage) |
| Destination selection | 1 | Using the first of multiple matching destinations: { platform:macOS, arch:arm64, ... } { platform:macOS, arch:x86_64, ... } |
| Ad-hoc codesigning | 1 | Disabling hardened runtime with ad-hoc codesigning. |

---

## Dependencies

| Package | Source | Resolved | Pinned Range |
|---------|--------|----------|--------------|
| WhisperKit | https://github.com/argmaxinc/WhisperKit | 0.15.0 | (from Package.swift) |
| Sparkle | https://github.com/sparkle-project/Sparkle | 2.9.0 | (from Package.swift) |
| swift-transformers | https://github.com/huggingface/swift-transformers.git | 1.1.6 | (from Package.swift) |
| swift-collections | https://github.com/apple/swift-collections.git | 1.3.0 | (from Package.swift) |
| Jinja | https://github.com/huggingface/swift-jinja.git | 2.3.1 | (from Package.swift) |
| swift-argument-parser | https://github.com/apple/swift-argument-parser.git | 1.7.0 | (from Package.swift) |

### SPM Resolution
- All dependencies resolved from cache (no network fetches attempted)
- All versions pinned to exact commits
- No unresolved transitive dependencies

---

## Root Cause

**Files added in commit 8696fbc (F-MM2 add Teams Slack WhatsApp Uven muters) were never registered in Dikta.xcodeproj/project.pbxproj:**

- `dikta-macos/Dikta/MicMuting/TeamsMuter.swift` — 0 references in .pbxproj
- `dikta-macos/Dikta/MicMuting/SlackMuter.swift` — 0 references in .pbxproj
- `dikta-macos/Dikta/MicMuting/WhatsAppMuter.swift` — 0 references in .pbxproj
- `dikta-macos/Dikta/MicMuting/UvenMuter.swift` — 0 references in .pbxproj

`MuterRegistry.swift` (registered in .pbxproj, 4 references) imports all 4 classes, causing both `xcodebuild build` and `xcodebuild test` to fail at module emit. `swift build` passes because SPM's directory globbing automatically includes all .swift files; Xcode's build system requires explicit project registration.

**Error lines from xcodebuild test/build:**
```
/Users/sebastianstrandberg/work/git/dikta/dikta-macos/Dikta/MicMuting/MuterRegistry.swift:6:9: error: cannot find 'TeamsMuter' in scope
/Users/sebastianstrandberg/work/git/dikta/dikta-macos/Dikta/MicMuting/MuterRegistry.swift:7:9: error: cannot find 'SlackMuter' in scope
/Users/sebastianstrandberg/work/git/dikta/dikta-macos/Dikta/MicMuting/MuterRegistry.swift:8:9: error: cannot find 'WhatsAppMuter' in scope
/Users/sebastianstrandberg/work/git/dikta/dikta-macos/Dikta/MicMuting/MuterRegistry.swift:9:9: error: cannot find 'UvenMuter' in scope
```

---

## Notes

### CoreSimulator Mismatch (Non-blocking)
macOS CoreSimulator (1051.54.0) is behind the version expected by Xcode 26.6. This is a simulator support issue and does NOT affect macOS native app builds. Run `softwareupdate -ia` to resolve.

### Unhandled Resources (Minor)
The MiniLML12v2.mlpackage binary files are not declared in the build manifest. They appear to be included but not properly registered. Check `Dikta.xcodeproj` build phases to ensure the .mlpackage is listed as a Copy Bundle Resources action.

### Codesigning
Ad-hoc signing is used (no dev certificate), which is correct for local builds. Hardened runtime is intentionally disabled.

---

## Summary

| Metric | Result |
|--------|--------|
| Swift build | ✓ PASS |
| Swift test execution | ✓ PASS (68 tests, all green) |
| Xcode Release build | ✗ FAIL |
| Xcode unit test build | ✗ FAIL |
| Dependencies resolved | ✓ YES (6 packages, cached) |
| Critical errors | 4 (missing Muter classes: TeamsMuter, SlackMuter, WhatsAppMuter, UvenMuter) |
| Deprecations | 0 |

**Conclusion**: SPM and Xcode project out of sync. Four .swift files committed in commit 8696fbc are not registered in Dikta.xcodeproj/project.pbxproj. SPM masks issue via auto-globbing; all Xcode builds fail at module emit.
