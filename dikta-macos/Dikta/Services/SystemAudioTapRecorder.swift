import Foundation
import CoreAudio
import AVFoundation

/// Abstraction over "capture system audio, minus Dikta's own audio" so the
/// debrief pipeline (and its tests) never touch CoreAudio directly.
protocol SystemAudioCapturing: AnyObject {
    /// Called with converted 16 kHz mono Float32 samples as they arrive.
    /// Implementations may call this from a background queue — consumers
    /// must not assume the main thread.
    var onSamples: (([Float]) -> Void)? { get set }

    /// Starts capture. Throws `SystemAudioCaptureError` on failure.
    func start() async throws

    /// Stops capture. Idempotent — safe to call when not running, or more
    /// than once.
    func stop()
}

/// Errors surfaced by `SystemAudioCapturing` implementations.
enum SystemAudioCaptureError: Error, LocalizedError {
    /// A CoreAudio call failed with a status that isn't a privacy denial.
    /// `stage` names the call that failed (e.g. "AudioDeviceStart"), so logs
    /// and tests can tell which step broke.
    case unavailable(osStatus: OSStatus, stage: String)
    /// IO proc creation failed because the user has not granted (or has
    /// denied) System Audio Recording permission for Dikta.
    case permissionDenied
    /// `start()` was called while capture was already running.
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .unavailable(let osStatus, let stage):
            return "System audio capture unavailable at \(stage) (OSStatus \(osStatus))"
        case .permissionDenied:
            return "System audio recording permission denied"
        case .alreadyRunning:
            return "System audio capture is already running"
        }
    }

    /// Maps an IO-proc-creation `OSStatus` to the right case: a privacy
    /// denial (`kAudioDevicePermissionsError`, '!hog') becomes
    /// `.permissionDenied`; any other status becomes `.unavailable` tagged
    /// with stage `"createIOProc"` so it's distinguishable from other
    /// failing stages. Pure and CoreAudio-hardware-free, so it's
    /// unit-testable without opening a tap.
    static func mapIOProcError(_ status: OSStatus) -> SystemAudioCaptureError {
        if status == kAudioDevicePermissionsError {
            return .permissionDenied
        }
        return .unavailable(osStatus: status, stage: "createIOProc")
    }
}

/// Downmixes interleaved N-channel Float32 audio to mono and resamples it to
/// a target rate via a **persistent** `AVAudioConverter`.
///
/// The converter is created once (in `init`) and reused across every
/// `process()` call for the life of a capture session. Creating a fresh
/// converter per IO buffer — or feeding `.endOfStream` on every call —
/// resets the resampler's internal filter state each time: measured as
/// audible clicks (adjacent-sample jumps ~2.5x baseline) and 0.1-0.2% output
/// length drift at real IO buffer sizes (512-1024 frames). `process()`
/// instead returns `.noDataNow` (never `.endOfStream`) when it runs out of
/// input for a given call, which leaves the converter's state intact for
/// the next call.
///
/// Not thread-safe on its own — callers must serialize access. In
/// `SystemAudioTapRecorder` that's `deliveryQueue`, a serial queue.
final class StereoToMonoResampler {
    /// Channel count this instance was built for. Callers must feed
    /// interleaved buffers with exactly this many channels per frame.
    let inputChannels: Int

    private let inputSampleRate: Double
    private let targetSampleRate: Double
    private let monoInFormat: AVAudioFormat
    private let monoOutFormat: AVAudioFormat
    /// `nil` when input and target rates already match — no resampling
    /// needed, `process()` just downmixes.
    private let converter: AVAudioConverter?

    /// Sample rate + channel count only — deliberately not `AVAudioFormat`.
    /// `AVAudioFormat`'s interleaved-multichannel initializers require an
    /// explicit `AVAudioChannelLayout` for channel counts above 2 and
    /// return `nil` without one (verified: `AVAudioFormat(commonFormat:
    /// sampleRate:channels:interleaved:)` fails for `channels: 4`), and a
    /// real tap can report more than 2 channels. This type only ever needs
    /// the two numbers below, so it sidesteps that failure mode entirely.
    struct InputFormat {
        let sampleRate: Double
        let channelCount: Int
    }

    /// `inputFormat` carries the source's actual sample rate and channel
    /// count (in `SystemAudioTapRecorder` this comes from querying
    /// `kAudioTapPropertyFormat` on the tap, not an assumed constant).
    init?(inputFormat: InputFormat, targetSampleRate: Double) {
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else { return nil }
        guard let monoIn = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false),
              let monoOut = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false) else {
            return nil
        }
        self.inputChannels = inputFormat.channelCount
        self.inputSampleRate = inputFormat.sampleRate
        self.targetSampleRate = targetSampleRate
        self.monoInFormat = monoIn
        self.monoOutFormat = monoOut
        self.converter = inputFormat.sampleRate == targetSampleRate ? nil : AVAudioConverter(from: monoIn, to: monoOut)
    }

    /// Downmixes `frames` of interleaved `inputChannels`-channel Float32 to
    /// mono, then resamples through the persistent converter (if rates
    /// differ). Call repeatedly with consecutive chunks of one continuous
    /// stream — the converter's state carries across calls, so chunk
    /// boundaries don't click or drift the way a fresh-converter-per-call
    /// approach does.
    func process(_ interleaved: [Float], frames: Int) -> [Float] {
        guard frames > 0, interleaved.count >= frames * inputChannels else { return [] }

        var mono = [Float](repeating: 0, count: frames)
        let channels = inputChannels
        interleaved.withUnsafeBufferPointer { source in
            for frame in 0..<frames {
                var sum: Float = 0
                let base = frame * channels
                for channel in 0..<channels { sum += source[base + channel] }
                mono[frame] = sum / Float(channels)
            }
        }

        guard let converter else { return mono }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: monoInFormat, frameCapacity: AVAudioFrameCount(mono.count)) else {
            return mono
        }
        inBuffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { source in
            inBuffer.floatChannelData?[0].update(from: source.baseAddress!, count: mono.count)
        }

        let outCapacity = AVAudioFrameCount(Double(mono.count) * targetSampleRate / inputSampleRate) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: monoOutFormat, frameCapacity: outCapacity) else {
            return mono
        }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if fed {
                // Not .endOfStream: that would flush and reset the
                // converter's internal filter state on every call, which is
                // exactly the bug this type exists to avoid.
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuffer
        }

        guard status != .error, let channelData = outBuffer.floatChannelData else {
            AppLogger.audio.error("StereoToMonoResampler: resample failed: \(conversionError?.localizedDescription ?? "unknown")")
            return mono
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
    }

    /// Drains whatever the converter is still holding onto (its filter
    /// latency — a handful of frames) by signaling end-of-stream exactly
    /// once. Call at most once, after the last `process()` call for a
    /// session: a real capture session flushes at `stop()`; a one-shot
    /// conversion (`SystemAudioTapRecorder.downmixAndResample`) flushes
    /// immediately after its single `process()` call. Calling `process()`
    /// again afterwards is undefined — the converter has been told there's
    /// no more data.
    func flush() -> [Float] {
        guard let converter else { return [] }
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: monoOutFormat, frameCapacity: 4096) else { return [] }

        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }

        guard status != .error, let channelData = outBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
    }
}

/// Captures system audio (all playback minus Dikta's own) via a CoreAudio
/// process tap, converts it to 16 kHz mono Float32, and delivers it through
/// `onSamples`.
///
/// ## Permission gate (spike finding — tasks/decisions-call-debrief.md decisions 2/3/7)
///
/// `AudioHardwareCreateProcessTap` succeeds even when Dikta has **not** been
/// granted System Audio Recording permission — it happily returns a valid
/// tap object ID either way. The actual TCC gate sits one step later, inside
/// `AudioDeviceCreateIOProcIDWithBlock`: that call blocks while the
/// permission prompt is on screen, and fails with `kAudioDevicePermissionsError`
/// ('!hog') if the user denies it. Any other failing stage — pid
/// translation, tap creation, aggregate device creation, `AudioDeviceStart`
/// — is a genuine CoreAudio error rather than a permission problem, and is
/// surfaced as `.unavailable(osStatus:stage:)` (see
/// `SystemAudioCaptureError.mapIOProcError` for the IO-proc-specific
/// mapping) so it's distinguishable in logs and by callers.
///
/// The tap's real format is queried via `kAudioTapPropertyFormat` right
/// after creation (`bench/probes/process-tap-probe.swift:394-398`) rather
/// than assumed — the spike saw 48 kHz stereo Float32 interleaved on this
/// machine, but nothing guarantees that elsewhere, and the resampler is
/// built from whatever the tap actually reports (falling back to 48 kHz/2ch
/// only if the query itself fails).
///
/// The blocking CoreAudio setup — including the potentially long-blocking
/// `AudioDeviceCreateIOProcIDWithBlock` call above — runs on a dedicated
/// background queue via a checked continuation, so a `MainActor` caller
/// doesn't hang while the TCC prompt is up.
@available(macOS 14.2, *)
final class SystemAudioTapRecorder: SystemAudioCapturing, @unchecked Sendable {
    // @unchecked Sendable: mutable state below is guarded by `stateLock`
    // (via `withLock`); `onSamples` is set by the owner before `start()`
    // and read from `deliveryQueue`, same contract as the rest of
    // `SystemAudioCapturing`.
    var onSamples: (([Float]) -> Void)?

    /// Used only when querying the tap's real format fails.
    static let fallbackSourceSampleRate: Double = 48_000
    static let fallbackChannelCount = 2
    /// Format Dikta's transcription pipeline expects.
    static let targetSampleRate: Double = 16_000

    private let stateLock = NSLock()
    private var isRunning = false
    /// Set by `stop()` when it arrives while `start()`'s CoreAudio setup is
    /// still in flight (not yet committed to `isRunning`). Consumed by
    /// `performBlockingSetupAndStart()` at its commit point — see the doc
    /// comment there for what happens when it's set.
    private var stopRequested = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    /// Built once per session from the tap's real format; reused for every
    /// IO callback in that session (see `StereoToMonoResampler`'s doc for
    /// why a persistent instance matters).
    private var resampler: StereoToMonoResampler?

    private var droppedBuffers = 0
    private var loggedDropThisSession = false

    /// IO proc callbacks are invoked directly on this queue — it's the
    /// queue passed to `AudioDeviceCreateIOProcIDWithBlock`, not a separate
    /// CoreAudio-managed thread. Conversion and delivery happen here, off
    /// the caller's thread. Also used to serialize `stop()` against any
    /// in-flight callback — see `stop()`.
    private let deliveryQueue = DispatchQueue(label: "com.duadigital.dikta.systemaudiotap.delivery", qos: .userInitiated)
    /// Per-instance token (not shared across recorders) used to detect
    /// whether code is currently executing on `deliveryQueue` — see
    /// `isOnDeliveryQueue`.
    private let deliveryQueueKey = DispatchSpecificKey<Void>()

    init() {
        deliveryQueue.setSpecific(key: deliveryQueueKey, value: ())
    }

    /// True when called from code already running on `deliveryQueue` — most
    /// notably, from inside an `onSamples` callback. `stop()` uses this to
    /// avoid `deliveryQueue.sync`-ing onto itself, which would deadlock.
    private var isOnDeliveryQueue: Bool {
        DispatchQueue.getSpecific(key: deliveryQueueKey) != nil
    }

    /// Test-only seam: runs `body` synchronously on `deliveryQueue`, so
    /// tests can drive the exact reentrancy `stop()` guards against (calling
    /// `stop()` from a block already running on `deliveryQueue`) without
    /// opening a real tap.
    func runOnDeliveryQueueForTesting(_ body: () -> Void) {
        deliveryQueue.sync(execute: body)
    }

    /// Runs the blocking CoreAudio setup calls — including
    /// `AudioDeviceCreateIOProcIDWithBlock`, which blocks while a TCC
    /// permission prompt is on screen — off whatever executor `start()`'s
    /// caller happens to be on.
    private static let setupQueue = DispatchQueue(label: "com.duadigital.dikta.systemaudiotap.setup", qos: .userInitiated)

    /// Number of IO buffers dropped because they couldn't be interpreted
    /// (unexpected `AudioBufferList` layout, a channel-count mismatch
    /// against the session's resampler, or no resampler yet). Exposed for
    /// diagnostics; buffers are never dropped silently — the first drop in
    /// a session is logged at error level, and every drop is counted here.
    var droppedBufferCount: Int { withLock { droppedBuffers } }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    func start() async throws {
        let alreadyRunning = withLock { isRunning }
        if alreadyRunning {
            AppLogger.audio.warning("SystemAudioTapRecorder: start() called while already running")
            throw SystemAudioCaptureError.alreadyRunning
        }

        withLock {
            droppedBuffers = 0
            loggedDropThisSession = false
            stopRequested = false
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.setupQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SystemAudioCaptureError.unavailable(osStatus: -1, stage: "deallocated"))
                    return
                }
                do {
                    try self.performBlockingSetupAndStart()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs entirely on `Self.setupQueue`. Owns the whole CoreAudio setup
    /// sequence — pid exclusion, tap, format query + resampler, aggregate
    /// device, IO proc, start — and commits instance state under
    /// `stateLock` as each piece succeeds, tearing down everything created
    /// so far on any failure.
    private func performBlockingSetupAndStart() throws {
        // 1. Exclude our own process. Fail closed: if we can't resolve our
        // own audio process object, never fall back to building a tap with
        // an empty exclusion list (that would capture Dikta's own audio).
        let (translateStatus, selfProcessObject) = Self.audioProcessObject(forPID: getpid())
        guard let selfProcessObject else {
            AppLogger.audio.error("SystemAudioTapRecorder: translate pid \(getpid()) -> process object failed (\(translateStatus)); refusing to build an unscoped tap")
            throw SystemAudioCaptureError.unavailable(osStatus: translateStatus, stage: "translatePID")
        }

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfProcessObject])
        tapDescription.name = "Dikta System Audio Tap"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let createTapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard createTapStatus == noErr, newTapID != AudioObjectID(kAudioObjectUnknown) else {
            AppLogger.audio.error("SystemAudioTapRecorder: AudioHardwareCreateProcessTap failed (\(createTapStatus))")
            throw SystemAudioCaptureError.unavailable(osStatus: createTapStatus, stage: "AudioHardwareCreateProcessTap")
        }

        // 2. Query the tap's real format — never assume 48 kHz/stereo.
        var tapASBD = AudioStreamBasicDescription()
        let formatStatus = Self.getProperty(newTapID, kAudioTapPropertyFormat, into: &tapASBD)
        let sourceSampleRate: Double
        let sourceChannelCount: Int
        if formatStatus == noErr, tapASBD.mSampleRate > 0, tapASBD.mChannelsPerFrame > 0 {
            sourceSampleRate = tapASBD.mSampleRate
            sourceChannelCount = Int(tapASBD.mChannelsPerFrame)
        } else {
            AppLogger.audio.warning("SystemAudioTapRecorder: kAudioTapPropertyFormat query failed (\(formatStatus)) — falling back to \(Self.fallbackSourceSampleRate)Hz/\(Self.fallbackChannelCount)ch")
            sourceSampleRate = Self.fallbackSourceSampleRate
            sourceChannelCount = Self.fallbackChannelCount
        }

        let sourceFormat = StereoToMonoResampler.InputFormat(sampleRate: sourceSampleRate, channelCount: sourceChannelCount)
        guard let newResampler = StereoToMonoResampler(inputFormat: sourceFormat, targetSampleRate: Self.targetSampleRate) else {
            _ = AudioHardwareDestroyProcessTap(newTapID)
            AppLogger.audio.error("SystemAudioTapRecorder: failed to build resampler for \(sourceSampleRate)Hz/\(sourceChannelCount)ch")
            throw SystemAudioCaptureError.unavailable(osStatus: formatStatus, stage: "buildResampler")
        }

        // 3. Wrap the tap in a private aggregate device — the tap itself
        // isn't a device you can start IO on directly.
        let outputDeviceID = Self.defaultOutputDevice()
        let outputUID = Self.deviceUID(outputDeviceID) ?? ""
        let aggregateUID = "com.duadigital.dikta.systemaudiotap.\(tapDescription.uuid.uuidString)"
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dikta System Audio Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let createAggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &newAggregateID)
        guard createAggregateStatus == noErr, newAggregateID != AudioObjectID(kAudioObjectUnknown) else {
            _ = AudioHardwareDestroyProcessTap(newTapID)
            AppLogger.audio.error("SystemAudioTapRecorder: AudioHardwareCreateAggregateDevice failed (\(createAggregateStatus))")
            throw SystemAudioCaptureError.unavailable(osStatus: createAggregateStatus, stage: "AudioHardwareCreateAggregateDevice")
        }

        // 4. IO proc — this is where the permission gate actually lives
        // (see the doc comment above). Tap and aggregate device creation
        // above both succeed with or without permission.
        var newIOProcID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, _, _, _ in
            self?.handleIOProc(inInputData)
        }
        let createIOProcStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, newAggregateID, deliveryQueue, ioBlock)
        guard createIOProcStatus == noErr, let ioProc = newIOProcID else {
            _ = AudioHardwareDestroyAggregateDevice(newAggregateID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            let mappedError = SystemAudioCaptureError.mapIOProcError(createIOProcStatus)
            if case .permissionDenied = mappedError {
                AppLogger.audio.error("SystemAudioTapRecorder: system audio recording permission denied")
            } else {
                AppLogger.audio.error("SystemAudioTapRecorder: AudioDeviceCreateIOProcIDWithBlock failed (\(createIOProcStatus))")
            }
            throw mappedError
        }

        // Commit the resampler before starting IO so the very first
        // callback never races an unset resampler.
        withLock {
            resampler = newResampler
        }

        let startStatus = AudioDeviceStart(newAggregateID, ioProc)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(newAggregateID, ioProc)
            _ = AudioHardwareDestroyAggregateDevice(newAggregateID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            withLock { resampler = nil }
            AppLogger.audio.error("SystemAudioTapRecorder: AudioDeviceStart failed (\(startStatus))")
            throw SystemAudioCaptureError.unavailable(osStatus: startStatus, stage: "AudioDeviceStart")
        }

        // Commit point: if stop() arrived while we were doing the CoreAudio
        // setup above (isRunning was still false, so stop() had nothing to
        // tear down and just set stopRequested instead — see stop()), honor
        // it now rather than silently leaving a capture running that the
        // caller already asked to stop. We tear down what we just built and
        // throw, rather than returning normally, so the caller's `await
        // start()` doesn't report success for a session that's already
        // gone — callers that raced a stop() this way should treat it the
        // same as any other start failure, not retry-loop on it.
        let shouldTearDownInstead = withLock { () -> Bool in
            guard Self.shouldCommitStart(stopRequested: stopRequested) else {
                stopRequested = false
                return true
            }
            tapID = newTapID
            aggregateDeviceID = newAggregateID
            ioProcID = ioProc
            isRunning = true
            return false
        }

        guard !shouldTearDownInstead else {
            _ = AudioDeviceStop(newAggregateID, ioProc)
            _ = AudioDeviceDestroyIOProcID(newAggregateID, ioProc)
            _ = AudioHardwareDestroyAggregateDevice(newAggregateID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            withLock { resampler = nil }
            AppLogger.audio.warning("SystemAudioTapRecorder: stop() arrived during start() — tore down and aborting")
            throw SystemAudioCaptureError.unavailable(osStatus: 0, stage: "stoppedDuringStart")
        }

        AppLogger.audio.info("SystemAudioTapRecorder: capture started (tap=\(newTapID), aggregate=\(newAggregateID), sourceRate=\(sourceSampleRate), channels=\(sourceChannelCount))")
    }

    /// Pure decision behind the commit-point check above, pulled out so the
    /// flag semantics have a direct unit test — the full race (a real
    /// `stop()` landing mid-`performBlockingSetupAndStart()`) can't be
    /// exercised without a real tap.
    static func shouldCommitStart(stopRequested: Bool) -> Bool {
        !stopRequested
    }

    /// Synchronizes against `deliveryQueue` so that by the time this
    /// returns, no further `onSamples` call can happen for this session:
    /// anything already running/queued on `deliveryQueue` finishes first
    /// (capture was still active for it), and anything CoreAudio schedules
    /// afterwards sees `isRunning == false` and returns immediately without
    /// calling `onSamples`.
    ///
    /// Safe to call from inside an `onSamples` callback: `isOnDeliveryQueue`
    /// detects that case and runs the teardown inline instead of via
    /// `deliveryQueue.sync`, which would otherwise deadlock (a serial queue
    /// waiting on itself).
    func stop() {
        if isOnDeliveryQueue {
            performStopTeardown()
        } else {
            deliveryQueue.sync {
                performStopTeardown()
            }
        }
    }

    /// The actual teardown body — always runs on `deliveryQueue` (either
    /// because `stop()` dispatched onto it, or because we were already
    /// there). Not reentrant-safe by itself; `stop()` is what makes it so.
    private func performStopTeardown() {
        let torn = withLock { () -> (aggregate: AudioObjectID, tap: AudioObjectID, ioProc: AudioDeviceIOProcID?, resampler: StereoToMonoResampler?)? in
            guard isRunning else {
                // Not running — possibly because start()'s CoreAudio setup
                // is still in flight on setupQueue and hasn't committed
                // isRunning yet. Flag it so that commit point tears itself
                // down instead of leaving a capture running that stop()
                // already asked to cancel (see performBlockingSetupAndStart).
                stopRequested = true
                return nil
            }
            let result = (aggregate: aggregateDeviceID, tap: tapID, ioProc: ioProcID, resampler: resampler)
            isRunning = false
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            tapID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
            resampler = nil
            return result
        }
        guard let torn else { return }

        // Drain the last few frames still buffered in the converter's
        // filter latency — still ordered before stop() returns, same as any
        // other onSamples call for this session.
        let trailing = torn.resampler?.flush() ?? []
        if !trailing.isEmpty {
            onSamples?(trailing)
        }

        // Teardown in reverse creation order: stop + destroy IO proc, then
        // the aggregate device, then the tap itself.
        if let ioProc = torn.ioProc {
            _ = AudioDeviceStop(torn.aggregate, ioProc)
            _ = AudioDeviceDestroyIOProcID(torn.aggregate, ioProc)
        }
        if torn.aggregate != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyAggregateDevice(torn.aggregate)
        }
        if torn.tap != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(torn.tap)
        }

        AppLogger.audio.info("SystemAudioTapRecorder: capture stopped")
    }

    /// Runs on `deliveryQueue` — the queue passed to
    /// `AudioDeviceCreateIOProcIDWithBlock` — not a separate CoreAudio
    /// thread. Converts and forwards to `onSamples` from here; does no
    /// other work here to keep the queue free for the next callback.
    private func handleIOProc(_ bufferList: UnsafePointer<AudioBufferList>) {
        let (running, currentResampler) = withLock { (isRunning, resampler) }
        guard running else { return }

        guard let flattened = Self.flattenBufferList(bufferList) else {
            recordDroppedBuffer("unhandled AudioBufferList layout")
            return
        }
        guard let currentResampler, flattened.channels == currentResampler.inputChannels else {
            recordDroppedBuffer("no resampler or channel-count mismatch (buffer had \(flattened.channels) channels)")
            return
        }

        let samples = currentResampler.process(flattened.samples, frames: flattened.frames)
        guard !samples.isEmpty else { return }
        onSamples?(samples)
    }

    /// Counts every drop; logs only the first one per session so a bad
    /// stream can't flood the log.
    private func recordDroppedBuffer(_ reason: String) {
        let shouldLog = withLock { () -> Bool in
            droppedBuffers += 1
            guard !loggedDropThisSession else { return false }
            loggedDropThisSession = true
            return true
        }
        guard shouldLog else { return }
        AppLogger.audio.error("SystemAudioTapRecorder: dropping buffer (\(reason)) — further drops this session are counted (see droppedBufferCount) but not logged")
    }

    // MARK: - Buffer flattening (interleaved and non-interleaved, any channel count)

    /// Flattens a CoreAudio `AudioBufferList` to a single interleaved
    /// Float32 array, handling both layouts the tap can deliver: one
    /// interleaved buffer (`list.count == 1`), or one buffer per channel
    /// (non-interleaved — `process-tap-probe.swift:255-277`).
    private static func flattenBufferList(_ bufferList: UnsafePointer<AudioBufferList>) -> (samples: [Float], frames: Int, channels: Int)? {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard list.count > 0 else { return nil }

        if list.count == 1 {
            guard let buffer = list.first, let raw = buffer.mData else { return nil }
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { return nil }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard frames > 0 else { return nil }
            let pointer = raw.assumingMemoryBound(to: Float.self)
            return (Array(UnsafeBufferPointer(start: pointer, count: frames * channels)), frames, channels)
        }

        // Non-interleaved: one buffer per channel.
        let channelCount = list.count
        guard let firstBuffer = list.first else { return nil }
        let frames = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0 else { return nil }

        var pointers: [UnsafePointer<Float>] = []
        pointers.reserveCapacity(channelCount)
        for buffer in list {
            guard let raw = buffer.mData else { return nil }
            pointers.append(raw.assumingMemoryBound(to: Float.self))
        }

        var interleaved = [Float](repeating: 0, count: frames * channelCount)
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                interleaved[frame * channelCount + channel] = pointers[channel][frame]
            }
        }
        return (interleaved, frames, channelCount)
    }

    // MARK: - Conversion (pure, unit-testable — no CoreAudio involved)

    /// One-shot wrapper around a fresh `StereoToMonoResampler`: processes
    /// the whole buffer in a single `process()` call and immediately
    /// `flush()`es it, so the result is complete (no frames left trapped in
    /// the converter's filter latency). Kept for synthetic-signal unit
    /// tests and as a single-shot baseline to compare persistent, chunked
    /// resampling against. The real capture path uses a persistent
    /// resampler instance instead (`resampler`), fed by many `process()`
    /// calls and flushed once at `stop()` — see `StereoToMonoResampler`'s
    /// doc comment for why that distinction matters for real (chunked)
    /// audio.
    static func downmixAndResample(_ interleavedStereo: [Float], frames: Int, from sourceRate: Double, to targetRate: Double) -> [Float] {
        let inputFormat = StereoToMonoResampler.InputFormat(sampleRate: sourceRate, channelCount: 2)
        guard let resampler = StereoToMonoResampler(inputFormat: inputFormat, targetSampleRate: targetRate) else {
            return []
        }
        var result = resampler.process(interleavedStereo, frames: frames)
        result.append(contentsOf: resampler.flush())
        return result
    }

    // MARK: - CoreAudio helpers (ported from bench/probes/process-tap-probe.swift)

    private static func systemObject() -> AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    private static func getProperty<T>(_ objectID: AudioObjectID,
                                        _ selector: AudioObjectPropertySelector,
                                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                        into value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
    }

    /// AudioObjectID of an *audio process object* for a unix pid — needed
    /// because `CATapDescription` exclusion lists take audio object IDs,
    /// not pids. Returns the raw status alongside the id so callers can
    /// fail closed (and report why) rather than silently building an
    /// unscoped tap.
    private static func audioProcessObject(forPID pid: pid_t) -> (status: OSStatus, id: AudioObjectID?) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var inPID = pid
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &inPID) { qualifier -> OSStatus in
            AudioObjectGetPropertyData(systemObject(), &address, UInt32(MemoryLayout<pid_t>.size), qualifier, &size, &out)
        }
        guard status == noErr, out != AudioObjectID(kAudioObjectUnknown) else {
            return (status, nil)
        }
        return (status, out)
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        _ = getProperty(systemObject(), kAudioHardwarePropertyDefaultOutputDevice, into: &device)
        return device
    }

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        var value: CFString = "" as CFString
        let status = getProperty(device, kAudioDevicePropertyDeviceUID, into: &value)
        return status == noErr ? (value as String) : nil
    }
}
