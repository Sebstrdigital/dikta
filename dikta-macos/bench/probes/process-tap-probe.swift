import Foundation
import CoreAudio
import AVFoundation

// THROWAWAY SPIKE PROBE — decisions 2/3/9 in tasks/decisions-call-debrief.md.
//
// Captures "all system audio minus this process" with a CoreAudio process tap
// and answers the four spike questions for the call-debrief feature:
//   1. Does AudioHardwareCreateProcessTap work on this machine, and what TCC
//      prompt (if any) does it raise for the host process?
//   2. What stream format does the tap actually deliver?
//   3. Does macOS show a recording indicator while a tap is running?
//   4. Does the tap survive a default-output-device switch mid-capture?
//
// API surface used (all verified against the macOS SDK headers):
//   CATapDescription                              CATapDescription.h:45  (macos 12.0)
//   init(stereoGlobalTapButExcludeProcesses:)     CATapDescription.h:66  (Swift overlay,
//                                                 CoreAudio.swiftinterface:457)
//   AudioHardwareCreateProcessTap                 AudioHardwareTapping.h:43 (macos 14.2)
//   AudioHardwareDestroyProcessTap                AudioHardwareTapping.h:54 (macos 14.2)
//   kAudioTapPropertyFormat                       AudioHardware.h:2022
//   kAudioAggregateDeviceTapListKey  ("taps")     AudioHardware.h:1627
//   kAudioSubTapUIDKey               ("uid")      AudioHardware.h:1861
//   kAudioSubTapDriftCompensationKey ("drift")    AudioHardware.h:1887
//   kAudioAggregateDeviceIsPrivateKey("private")  AudioHardware.h:1609
//   kAudioHardwarePropertyTranslatePIDToProcessObject  AudioHardware.h:634
//
// Build:
//   swiftc -O -framework CoreAudio -framework AVFoundation \
//     -o ../results/process-tap/probe process-tap-probe.swift
//
// Does NOT touch dikta-macos/Dikta/ — standalone, like the other bench probes.

// MARK: - CLI

let args = CommandLine.arguments
func argValue(_ flag: String, default def: String) -> String {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return def }
    return args[i + 1]
}
let captureSeconds = Double(argValue("--seconds", default: "15")) ?? 15
// Default next to the binary (bench/results/process-tap, which is gitignored)
// so the documented validation command never writes into bench/probes/.
let defaultOutDir = (args[0] as NSString).deletingLastPathComponent
let outDir = argValue("--out", default: defaultOutDir.isEmpty ? FileManager.default.currentDirectoryPath : defaultOutDir)
let wavPath = (outDir as NSString).appendingPathComponent("capture.wav")
// --log lets the probe run inside a .app bundle (launched via `open`, where the
// TCC responsible process is the bundle itself rather than the terminal) and
// still leave a readable transcript.
let logPath = argValue("--log", default: "")
if !logPath.isEmpty {
    _ = freopen(logPath, "w", stdout)
    _ = freopen(logPath, "a", stderr)
    setvbuf(stdout, nil, _IONBF, 0)
}

func log(_ s: String) {
    let t = String(format: "%7.3f", Date().timeIntervalSince(startWall))
    print("[\(t)s] \(s)")
    fflush(stdout)
}
let startWall = Date()

func fourCC(_ v: UInt32) -> String {
    let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? "\(v)"
}
func osStatusString(_ s: OSStatus) -> String {
    let u = UInt32(bitPattern: s)
    let cc = fourCC(u)
    let printable = cc.allSatisfy { $0.isLetter || $0.isNumber || $0 == "!" || $0 == "?" || $0 == " " }
    return printable ? "\(s) ('\(cc)')" : "\(s)"
}

// MARK: - CoreAudio property helpers

func systemObject() -> AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

func getProperty<T>(_ objID: AudioObjectID,
                    _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    into value: inout T) -> OSStatus {
    var addr = AudioObjectPropertyAddress(mSelector: selector,
                                          mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(objID, &addr, 0, nil, &size, $0)
    }
}

func getVariableProperty(_ objID: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         qualifier: UnsafeRawPointer? = nil,
                         qualifierSize: UInt32 = 0) -> (OSStatus, Data) {
    var addr = AudioObjectPropertyAddress(mSelector: selector,
                                          mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    var st = AudioObjectGetPropertyDataSize(objID, &addr, qualifierSize, qualifier, &size)
    guard st == noErr, size > 0 else { return (st, Data()) }
    var buf = [UInt8](repeating: 0, count: Int(size))
    st = buf.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(objID, &addr, qualifierSize, qualifier, &size, $0.baseAddress!)
    }
    return (st, Data(buf.prefix(Int(size))))
}

func deviceUID(_ dev: AudioObjectID) -> String? {
    var cf: CFString = "" as CFString
    let st = getProperty(dev, kAudioDevicePropertyDeviceUID, into: &cf)
    return st == noErr ? (cf as String) : nil
}

func deviceName(_ dev: AudioObjectID) -> String? {
    var cf: CFString = "" as CFString
    let st = getProperty(dev, kAudioObjectPropertyName, into: &cf)
    return st == noErr ? (cf as String) : nil
}

/// All devices that have at least one output stream.
func outputDevices() -> [AudioObjectID] {
    let (st, data) = getVariableProperty(systemObject(), kAudioHardwarePropertyDevices)
    guard st == noErr else { return [] }
    let ids = data.withUnsafeBytes { raw -> [AudioObjectID] in
        Array(raw.bindMemory(to: AudioObjectID.self))
    }
    return ids.filter { dev in
        let (s, d) = getVariableProperty(dev, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        return s == noErr && d.count >= MemoryLayout<AudioObjectID>.size
    }
}

func setDefaultOutputDevice(_ dev: AudioObjectID) -> OSStatus {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var d = dev
    return AudioObjectSetPropertyData(systemObject(), &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioObjectID>.size), &d)
}

func defaultOutputDevice() -> AudioObjectID {
    var dev = AudioObjectID(kAudioObjectUnknown)
    _ = getProperty(systemObject(), kAudioHardwarePropertyDefaultOutputDevice, into: &dev)
    return dev
}

/// AudioObjectID of an *audio process object* for a unix pid — needed because
/// CATapDescription exclusion lists take audio object IDs, not pids.
/// kAudioHardwarePropertyTranslatePIDToProcessObject — AudioHardware.h:634
func audioProcessObject(forPID pid: pid_t) -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var inPID = pid
    var out = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = withUnsafeMutablePointer(to: &inPID) { q -> OSStatus in
        AudioObjectGetPropertyData(systemObject(), &addr,
                                   UInt32(MemoryLayout<pid_t>.size), q,
                                   &size, &out)
    }
    guard st == noErr, out != AudioObjectID(kAudioObjectUnknown) else {
        log("translate pid \(pid) -> process object failed: \(osStatusString(st))")
        return nil
    }
    return out
}

func describe(_ asbd: AudioStreamBasicDescription, label: String) {
    var flags: [String] = []
    let f = asbd.mFormatFlags
    if f & kAudioFormatFlagIsFloat != 0 { flags.append("Float") }
    if f & kAudioFormatFlagIsSignedInteger != 0 { flags.append("SignedInteger") }
    if f & kAudioFormatFlagIsBigEndian != 0 { flags.append("BigEndian") } else { flags.append("LittleEndian") }
    if f & kAudioFormatFlagIsPacked != 0 { flags.append("Packed") }
    if f & kAudioFormatFlagIsAlignedHigh != 0 { flags.append("AlignedHigh") }
    if f & kAudioFormatFlagIsNonInterleaved != 0 { flags.append("NonInterleaved") } else { flags.append("Interleaved") }
    print("""
    \(label):
      mFormatID        = '\(fourCC(asbd.mFormatID))'
      mSampleRate      = \(asbd.mSampleRate)
      mChannelsPerFrame= \(asbd.mChannelsPerFrame)
      mBitsPerChannel  = \(asbd.mBitsPerChannel)
      mBytesPerFrame   = \(asbd.mBytesPerFrame)
      mBytesPerPacket  = \(asbd.mBytesPerPacket)
      mFramesPerPacket = \(asbd.mFramesPerPacket)
      mFormatFlags     = 0x\(String(f, radix: 16)) [\(flags.joined(separator: ", "))]
    """)
    fflush(stdout)
}

// MARK: - Capture sink (written from the IO thread, read after stop)

final class MonoSink {
    private var storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var count: Int = 0
    private let lock = NSLock()
    /// frames delivered per wall-clock second, so a device switch shows as a gap
    private(set) var perSecond: [Int] = []
    /// per-second energy, so "tap running but TCC not yet granted" shows as
    /// frames arriving with zero level rather than as a gap
    private(set) var perSecondSumSq: [Double] = []
    private(set) var perSecondPeak: [Float] = []
    private var callbacks = 0
    private var maxSeenChannels = 0
    private var sawNonInterleaved = false

    init(capacitySeconds: Double, sampleRate: Double) {
        capacity = Int(capacitySeconds * sampleRate) + 48000
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        perSecond = [Int](repeating: 0, count: Int(capacitySeconds) + 6)
        perSecondSumSq = [Double](repeating: 0, count: Int(capacitySeconds) + 6)
        perSecondPeak = [Float](repeating: 0, count: Int(capacitySeconds) + 6)
    }

    private func note(_ bucket: Int, _ v: Float) {
        guard bucket >= 0 && bucket < perSecondSumSq.count else { return }
        perSecondSumSq[bucket] += Double(v) * Double(v)
        perSecondPeak[bucket] = max(perSecondPeak[bucket], abs(v))
    }
    deinit { storage.deallocate() }

    func append(abl: UnsafePointer<AudioBufferList>, secondBucket: Int) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        lock.lock()
        defer { lock.unlock() }
        callbacks += 1
        guard list.count > 0 else { return }

        if list.count == 1 {
            // interleaved (or genuine mono)
            let b = list[0]
            let ch = Int(b.mNumberChannels)
            maxSeenChannels = max(maxSeenChannels, ch)
            guard ch > 0, let raw = b.mData else { return }
            let frames = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let p = raw.assumingMemoryBound(to: Float.self)
            var written = 0
            for f in 0..<frames {
                guard count < capacity else { break }
                var acc: Float = 0
                for c in 0..<ch { acc += p[f * ch + c] }
                let v = acc / Float(ch)
                storage[count] = v
                note(secondBucket, v)
                count += 1
                written += 1
            }
            if secondBucket >= 0 && secondBucket < perSecond.count { perSecond[secondBucket] += written }
        } else {
            // non-interleaved: one buffer per channel
            sawNonInterleaved = true
            maxSeenChannels = max(maxSeenChannels, list.count)
            let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            var ptrs: [UnsafeMutablePointer<Float>] = []
            for i in 0..<list.count {
                guard let raw = list[i].mData else { return }
                ptrs.append(raw.assumingMemoryBound(to: Float.self))
            }
            var written = 0
            for f in 0..<frames {
                guard count < capacity else { break }
                var acc: Float = 0
                for p in ptrs { acc += p[f] }
                let v = acc / Float(ptrs.count)
                storage[count] = v
                note(secondBucket, v)
                count += 1
                written += 1
            }
            if secondBucket >= 0 && secondBucket < perSecond.count { perSecond[secondBucket] += written }
        }
    }

    func snapshot() -> (samples: [Float], callbacks: Int, channels: Int, nonInterleaved: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (Array(UnsafeBufferPointer(start: storage, count: count)),
                callbacks, maxSeenChannels, sawNonInterleaved)
    }
}

// MARK: - WAV writer (RIFF / IEEE float 32, mono)

func writeFloat32WAV(_ samples: [Float], sampleRate: Int, to path: String) throws {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

    let channels: UInt16 = 1
    let bits: UInt16 = 32
    let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bits / 8)
    let blockAlign = UInt16(channels * bits / 8)
    let dataBytes = UInt32(samples.count * MemoryLayout<Float>.size)

    data.append(contentsOf: Array("RIFF".utf8))
    u32(36 + dataBytes)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    u32(16)
    u16(3)                  // WAVE_FORMAT_IEEE_FLOAT
    u16(channels)
    u32(UInt32(sampleRate))
    u32(byteRate)
    u16(blockAlign)
    u16(bits)
    data.append(contentsOf: Array("data".utf8))
    u32(dataBytes)
    samples.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
    try data.write(to: URL(fileURLWithPath: path))
}

/// Offline resample mono Float32 srcRate -> dstRate using AVAudioConverter.
func resampleMono(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
    guard srcRate != dstRate, !input.isEmpty else { return input }
    guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcRate,
                                    channels: 1, interleaved: false),
          let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: dstRate,
                                     channels: 1, interleaved: false),
          let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
        log("AVAudioConverter unavailable — writing at source rate instead")
        return input
    }
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(input.count)) else {
        return input
    }
    inBuf.frameLength = AVAudioFrameCount(input.count)
    memcpy(inBuf.floatChannelData![0], input, input.count * MemoryLayout<Float>.size)

    let outCapacity = AVAudioFrameCount(Double(input.count) * dstRate / srcRate) + 4096
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCapacity) else { return input }

    var fed = false
    var err: NSError?
    let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
        if fed { outStatus.pointee = .endOfStream; return nil }
        fed = true
        outStatus.pointee = .haveData
        return inBuf
    }
    if status == .error {
        log("resample failed: \(err?.localizedDescription ?? "unknown")")
        return input
    }
    return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
}

// MARK: - Main

print("=== Dikta process-tap probe ===")
print("pid              = \(getpid())")
print("macOS            = \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("capture seconds  = \(captureSeconds)")
print("output wav       = \(wavPath)")
fflush(stdout)

guard #available(macOS 14.2, *) else {
    print("FATAL: process taps require macOS 14.2+")
    exit(2)
}

// 1. Exclude our own process so the tap is "all system audio minus self".
let selfObj = audioProcessObject(forPID: getpid())
if let s = selfObj {
    log("self audio process object = \(s) (pid \(getpid()))")
} else {
    log("WARNING: could not resolve own audio process object; tap will include self")
}

// 2. Global stereo tap, excluding self. CATapDescription.h:66
let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: selfObj.map { [$0] } ?? [])
tapDesc.name = "Dikta Call-Debrief Spike Tap"
tapDesc.uuid = UUID()
tapDesc.isPrivate = true          // privateTap — CATapDescription.h:160
tapDesc.muteBehavior = .unmuted   // keep playback audible — CATapDescription.h:173
log("tap description: uuid=\(tapDesc.uuid.uuidString) exclusive=\(tapDesc.isExclusive) mono=\(tapDesc.isMono) mixdown=\(tapDesc.isMixdown) private=\(tapDesc.isPrivate)")

var tapID = AudioObjectID(kAudioObjectUnknown)
log("calling AudioHardwareCreateProcessTap (this is where a TCC prompt would appear)...")
let createStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
log("AudioHardwareCreateProcessTap -> \(osStatusString(createStatus)), tapID=\(tapID)")
guard createStatus == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
    print("FATAL: tap creation failed. Most likely cause: System Audio Recording permission denied for the host process.")
    exit(3)
}

// 3. Delivered tap format — kAudioTapPropertyFormat, AudioHardware.h:2022
var tapASBD = AudioStreamBasicDescription()
let fmtStatus = getProperty(tapID, kAudioTapPropertyFormat, into: &tapASBD)
log("kAudioTapPropertyFormat -> \(osStatusString(fmtStatus))")
if fmtStatus == noErr { describe(tapASBD, label: "TAP DELIVERED FORMAT") }

let srcRate = tapASBD.mSampleRate > 0 ? tapASBD.mSampleRate : 48000

// 4. Private aggregate device wrapping the tap.
let outDev = defaultOutputDevice()
let outUID = deviceUID(outDev) ?? ""
log("default output device = \(outDev) '\(deviceName(outDev) ?? "?")' uid=\(outUID)")

let aggUID = "com.duadigital.dikta.probe.agg.\(UUID().uuidString)"
let tapUID = tapDesc.uuid.uuidString
let aggDict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Dikta Probe Aggregate",
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceIsPrivateKey: true,           // AudioHardware.h:1609
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
    kAudioAggregateDeviceTapAutoStartKey: true,        // AudioHardware.h:1640
    kAudioAggregateDeviceTapListKey: [                 // AudioHardware.h:1627
        [
            kAudioSubTapUIDKey: tapUID,                // AudioHardware.h:1861
            kAudioSubTapDriftCompensationKey: true     // AudioHardware.h:1887
        ]
    ]
]

var aggID = AudioObjectID(kAudioObjectUnknown)
let aggStatus = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
log("AudioHardwareCreateAggregateDevice -> \(osStatusString(aggStatus)), aggID=\(aggID)")
guard aggStatus == noErr, aggID != AudioObjectID(kAudioObjectUnknown) else {
    _ = AudioHardwareDestroyProcessTap(tapID)
    print("FATAL: aggregate device creation failed")
    exit(4)
}

var aggRate: Float64 = 0
_ = getProperty(aggID, kAudioDevicePropertyNominalSampleRate, into: &aggRate)
log("aggregate nominal sample rate = \(aggRate) Hz")

var aggInASBD = AudioStreamBasicDescription()
let aggFmtSt = getProperty(aggID, kAudioDevicePropertyStreamFormat,
                           kAudioObjectPropertyScopeInput, into: &aggInASBD)
if aggFmtSt == noErr { describe(aggInASBD, label: "AGGREGATE INPUT STREAM FORMAT") }
else { log("aggregate input stream format -> \(osStatusString(aggFmtSt))") }

// 5. Watch for default-output-device changes during capture (decision 2: AirPods switch).
var switchEvents: [String] = []
var switchAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                            mScope: kAudioObjectPropertyScopeGlobal,
                                            mElement: kAudioObjectPropertyElementMain)
let listenerQueue = DispatchQueue(label: "probe.devicelistener")
let listenerBlock: AudioObjectPropertyListenerBlock = { _, _ in
    let d = defaultOutputDevice()
    let msg = "default output changed -> \(d) '\(deviceName(d) ?? "?")'"
    switchEvents.append(msg)
    log("EVENT: \(msg)")
}
_ = AudioObjectAddPropertyListenerBlock(systemObject(), &switchAddr, listenerQueue, listenerBlock)

// 6. IO proc.
let sink = MonoSink(capacitySeconds: captureSeconds + 3, sampleRate: srcRate)
let ioQueue = DispatchQueue(label: "probe.ioproc", qos: .userInitiated)
var captureStart = Date()
var procID: AudioDeviceIOProcID?

let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
    let bucket = Int(Date().timeIntervalSince(captureStart))
    sink.append(abl: inInputData, secondBucket: bucket)
}
let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue, ioBlock)
log("AudioDeviceCreateIOProcIDWithBlock -> \(osStatusString(procStatus))")
guard procStatus == noErr, let proc = procID else {
    _ = AudioHardwareDestroyAggregateDevice(aggID)
    _ = AudioHardwareDestroyProcessTap(tapID)
    print("FATAL: IO proc creation failed")
    exit(5)
}

captureStart = Date()
let startStatus = AudioDeviceStart(aggID, proc)
log("AudioDeviceStart -> \(osStatusString(startStatus))")
guard startStatus == noErr else {
    _ = AudioDeviceDestroyIOProcID(aggID, proc)
    _ = AudioHardwareDestroyAggregateDevice(aggID)
    _ = AudioHardwareDestroyProcessTap(tapID)
    print("FATAL: AudioDeviceStart failed")
    exit(6)
}

log("CAPTURING for \(captureSeconds)s — make noise now")

// Optional mid-capture default-output-device switch (spike question: AirPods
// swapped in mid-call). SwitchAudioSource is not installed on this machine, so
// the probe does the switch itself via the settable
// kAudioHardwarePropertyDefaultOutputDevice and restores it afterwards.
let switchAt = Double(argValue("--switch-at", default: "-1")) ?? -1
var restoreDevice: AudioObjectID? = nil
var switchDone = false

let deadline = Date().addingTimeInterval(captureSeconds)
while Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    let elapsed = Date().timeIntervalSince(captureStart)
    if switchAt >= 0, !switchDone, elapsed >= switchAt {
        switchDone = true
        let current = defaultOutputDevice()
        let candidates = outputDevices().filter { $0 != current && $0 != aggID }
        if let target = candidates.first {
            restoreDevice = current
            let st = setDefaultOutputDevice(target)
            log("SWITCH: default output \(current) '\(deviceName(current) ?? "?")' -> \(target) '\(deviceName(target) ?? "?")' status=\(osStatusString(st))")
        } else {
            log("SWITCH: no alternative output device available, skipped")
        }
    }
}
if let r = restoreDevice {
    let st = setDefaultOutputDevice(r)
    log("SWITCH: restored default output to \(r) '\(deviceName(r) ?? "?")' status=\(osStatusString(st))")
}

let stopStatus = AudioDeviceStop(aggID, proc)
log("AudioDeviceStop -> \(osStatusString(stopStatus))")
_ = AudioObjectRemovePropertyListenerBlock(systemObject(), &switchAddr, listenerQueue, listenerBlock)

// Re-read the tap format after capture: did a device switch change it?
var tapASBDAfter = AudioStreamBasicDescription()
let fmtAfterSt = getProperty(tapID, kAudioTapPropertyFormat, into: &tapASBDAfter)
if fmtAfterSt == noErr {
    let changed = tapASBDAfter.mSampleRate != tapASBD.mSampleRate
        || tapASBDAfter.mChannelsPerFrame != tapASBD.mChannelsPerFrame
        || tapASBDAfter.mFormatFlags != tapASBD.mFormatFlags
    log("tap format after capture: \(changed ? "CHANGED" : "unchanged")")
    if changed { describe(tapASBDAfter, label: "TAP FORMAT AFTER CAPTURE") }
}

_ = AudioDeviceDestroyIOProcID(aggID, proc)
_ = AudioHardwareDestroyAggregateDevice(aggID)
let destroyStatus = AudioHardwareDestroyProcessTap(tapID)
log("AudioHardwareDestroyProcessTap -> \(osStatusString(destroyStatus))")

// 7. Results.
let snap = sink.snapshot()
print("")
print("--- capture stats ---")
print("io callbacks        = \(snap.callbacks)")
print("channels seen       = \(snap.channels) (nonInterleaved=\(snap.nonInterleaved))")
print("frames captured     = \(snap.samples.count) @ \(srcRate) Hz  (~\(String(format: "%.2f", Double(snap.samples.count) / srcRate))s)")
print("per-second frames / rms / peak  (zero level with non-zero frames == tap running but muted by TCC):")
for (i, n) in sink.perSecond.enumerated() where i <= Int(captureSeconds) + 1 {
    let rms = n > 0 ? sqrt(sink.perSecondSumSq[i] / Double(n)) : 0
    print(String(format: "  t=%2ds: frames=%6d  rms=%.6f  peak=%.6f", i, n, rms, sink.perSecondPeak[i]))
}
if switchEvents.isEmpty {
    print("default-output-device switches during capture: none observed")
} else {
    print("default-output-device switches during capture:")
    switchEvents.forEach { print("  \($0)") }
}

guard !snap.samples.isEmpty else {
    print("FATAL: captured zero frames")
    exit(7)
}

let mono16k = resampleMono(snap.samples, from: srcRate, to: 16000)
var peak: Float = 0
var sumSq: Double = 0
for s in mono16k {
    peak = max(peak, abs(s))
    sumSq += Double(s) * Double(s)
}
let rms = mono16k.isEmpty ? 0 : sqrt(sumSq / Double(mono16k.count))
let dbfs = rms > 0 ? 20 * log10(rms) : -.infinity

do {
    try writeFloat32WAV(mono16k, sampleRate: 16000, to: wavPath)
} catch {
    print("FATAL: WAV write failed: \(error)")
    exit(8)
}

print("")
print("--- 16 kHz mono output ---")
print("samples             = \(mono16k.count)  (\(String(format: "%.2f", Double(mono16k.count) / 16000.0))s)")
print(String(format: "peak                = %.6f", peak))
print(String(format: "rms                 = %.6f  (%.1f dBFS)", rms, dbfs))
print("silent?             = \(peak < 1e-5 ? "YES — CAPTURE IS SILENT" : "no — capture has signal")")
print("wav                 = \(wavPath)")
exit(0)
