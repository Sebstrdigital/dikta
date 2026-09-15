# Apple DictationTranscriber — Engine Spec

Scout: sonnet, 2026-09-15. Verified by compiling + running probe on macOS 26.6.2 / Xcode 26.6. Signatures from `Speech.framework/.../arm64e-apple-macos.swiftinterface` (line refs = that file).

## 1. Minimal path (verified: compiled, ran on `say -v Alva` sv wav → correct transcript)

```swift
let transcriber = DictationTranscriber(locale: locale, preset: .shortDictation)          // :50
if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { // :36
    try await req.downloadAndInstall()                                                    // :498
}
guard let wantFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) // :233
else { throw ... }
let inputBuffer = /* [Float] 16k mono → AVAudioPCMBuffer in wantFormat, see §2 */
let analyzer = SpeechAnalyzer(modules: [transcriber])                                      // :207
let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
continuation.yield(AnalyzerInput(buffer: inputBuffer))                                     // :243
continuation.finish()
try await analyzer.start(inputSequence: stream)                                            // :217
try await analyzer.finalizeAndFinishThroughEndOfInput()                                    // :220
var text = ""
for try await result in transcriber.results { text += String(result.text.characters) }
return text
```

Compile: `swiftc -sdk $(xcrun --show-sdk-path) -target arm64-apple-macos26.0 -parse-as-library streamprobe.swift -o streamprobe` → exit 0 (Sendable warnings only).

## 2. Audio format — Int16, NOT Float32

`bestAvailableAudioFormat` returned `1 ch, 16000 Hz, Int16` for sv-SE. Dikta `AudioRecorder.swift:98-105` produces 16k mono `.pcmFormatFloat32`. Need `AVAudioConverter(from: float32Fmt, to: wantFormat).convert(to:error:withInputFrom:)`. Build source `AVAudioPCMBuffer` from `[Float]` via `floatChannelData[0].update(from:count:)` (reverse of `AudioRecorder.swift:191-193`). Round-trip verified identical output.

## 3. Assets

- `AssetInventory.assetInstallationRequest(supporting:)` (:36) = reliable signal.
  - Unsupported locale (`xx-XX`): throws `SFSpeechErrorDomain Code=15` = `SFSpeechError.Code.cannotAllocateUnsupportedLocale` (:648) → surface "language not supported".
  - Supported not installed (`id-ID`) and installed (`sv-SE`): both return non-nil request. `downloadAndInstall()` (:498) idempotent, near-instant when installed.
- Caveat: `AssetInventory.status(forModules:)` (:35) returned `.supported` for sv-SE while `installedLocales` listed it installed. Disagree. **Don't gate UI on `status`. Always call `assetInstallationRequest`: throw → unsupported; non-nil → `downloadAndInstall()` (cheap if installed); nil → ready.**
- Network requirement for install: UNVERIFIED (no airplane-mode test).

Probe source: scratchpad `apple-probe/streamprobe.swift` (session-temp; copy into `bench/` if wanted).

## 4. Locale — no auto-detect

Dikta `Language` (`Models/Language.swift:4-16`): fixed list en, sv, id, es, fr, de, pt, it, nl, fi, no, da. No `.auto`. `MenuBarViewModel.swift:223` always passes concrete `language.whisperCode`.

`DictationTranscriber` has NO language detection. `locale` required on both inits (:50-51). `LocaleDependentSpeechModule` (:44-48) exposes only `supportedLocales`, `supportedLocale(equivalentTo:)`, `selectedLocales`.

**Spec:** map each `Language` → BCP-47 (sv→sv-SE, en→en-US, id→id-ID, es→es-ES, fr→fr-FR, de→de-DE, pt→pt-BR?, it→it-IT, nl→nl-NL, fi→fi-FI, no→nb-NO, da→da-DK), resolve via `DictationTranscriber.supportedLocale(equivalentTo:)` before init. If nil → engine unavailable for that language, UI must say so (fall back to Whisper engine).

## 5. Inverse text normalization — NOT configurable (verified from interface)

`DictationTranscriber.TranscriptionOption` (:81-84): `punctuation`, `emoji`, `etiquetteReplacements`. Nothing else. `ReportingOption`: `volatileResults`, `alternativeTranscriptions`, `frequentFinalization`. `ResultAttributeOption`: `audioTimeRange`, `transcriptionConfidence`. **No ITN toggle anywhere.**

Presets (probe `presetprobe.swift`):
- `.shortDictation`: contentHints=[shortForm], transcriptionOptions=[.punctuation], reporting=[]
- `.progressiveShortDictation`: same + reporting=[.volatileResults, .frequentFinalization]
- `.phrase`: transcriptionOptions=[], reporting=[]
- `.longDictation`: transcriptionOptions=[.punctuation], reporting=[]

Numbers/dates/currency/times arrive normalized regardless. Must measure vs formatter before default. Formatter may need "already-normalized" mode.

## 6. Threading, availability, reuse

- `@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)` (:47-48). Dikta deployment target = macOS 14 → engine must be `if #available(macOS 26, *)` gated; hide menu option otherwise.
- `SpeechAnalyzer` = `final public actor` (:207). `DictationTranscriber` = `Sendable` class. Callable from any isolation.
- **CRITICAL (verified, 2 probes): do NOT reuse instances across utterances.** Same `DictationTranscriber`+`SpeechAnalyzer` fed twice → utterance 2 returns `""` silently, no error. Fresh pair per call → correct both times. **Spec: construct new `DictationTranscriber` + `SpeechAnalyzer` per push-to-talk recording.** Lifecycle is per-utterance, unlike WhisperKit load-once. `load()` for this engine = asset check only; `transcribe()` builds instances.

## 7. Risks / unknowns

- `status(forModules:)` vs `installedLocales` disagree — unexplained. Don't use `status` for UI.
- Offline asset install: UNVERIFIED. Needs airplane-mode test.
- No auto-detect. Product decision, not workaround.
- ITN unconditional, hits sv too (numbers/dates/currency/times). Measure vs formatter before default.
- Real human Swedish WER: none. All samples `say -v Alva`, n=1.
- Instance-reuse silent `""` — call out in code review, not just here.
- `AnalysisContext.contextualStrings` / `SFCustomLanguageModelData` (:~468+) exist, unexercised. Bias recognition, not normalization → unlikely ITN mitigation.

## Probes

Verified probe source copied to `dikta-macos/Bench/probes/apple-streamprobe.swift` (compile line in §1). Others (status/req/preset/reuse) were session-temp.
