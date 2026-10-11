import Foundation
import AVFoundation
import AppKit
import CoreAudio

/// Events from one in-memory audio buffer. Tags let the service reject every
/// callback that belongs to a stopped or superseded request.
enum NativeTTSPlaybackEvent: Equatable {
    case started(UUID)
    case finished(UUID)
    case failed(UUID)
    case interrupted(UUID)
}

@MainActor
protocol NativeTTSPlayback: AnyObject {
    var eventHandler: ((NativeTTSPlaybackEvent) -> Void)? { get set }
    func play(wav: Data, tag: UUID) throws
    func stop()
}

@MainActor
protocol NativeAudioHandle: AnyObject {
    var duration: TimeInterval { get }
    var completion: ((Bool) -> Void)? { get set }
    func prepare()
    func play() -> Bool
    func stop()
}

@MainActor
private final class AVAudioHandle: NSObject, NativeAudioHandle, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var completion: ((Bool) -> Void)?
    var duration: TimeInterval { player.duration }

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        super.init()
        player.delegate = self
    }

    func prepare() { player.prepareToPlay() }
    func play() -> Bool { player.play() }
    func stop() { player.delegate = nil; player.stop() }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        completion?(flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        completion?(false)
    }
}

/// Production route/sleep notifications are deliberately outside AVAudioPlayer's
/// delegate contract: some interruptions provide no finish callback.
@MainActor
protocol NativeAudioInterruptionSource: AnyObject {
    func install(_ handler: @escaping () -> Void)
    func uninstall()
}

/// Read-only CoreAudio observation. Callbacks run on the main queue and each
/// returned closure removes exactly the listener registered by that call.
@MainActor
protocol NativeAudioHardwareObserving: AnyObject {
    var defaultOutputDevice: AudioObjectID { get }
    func observe(object: AudioObjectID, selector: AudioObjectPropertySelector,
                 handler: @escaping () -> Void) -> (() -> Void)?
}

@MainActor
private final class CoreAudioOutputObserver: NativeAudioHardwareObserving {
    var defaultOutputDevice: AudioObjectID {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == kAudioHardwareNoError else {
            return AudioObjectID(kAudioObjectUnknown)
        }
        return device
    }

    func observe(object: AudioObjectID, selector: AudioObjectPropertySelector,
                 handler: @escaping () -> Void) -> (() -> Void)? {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == kAudioHardwareNoError else {
            return nil // The tagged playback watchdog remains the fallback.
        }
        return {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

@MainActor
final class SystemNativeAudioInterruptionSource: NativeAudioInterruptionSource {
    // Immutable, inspectable binding: tests can verify the real default without
    // posting a synthetic sleep notification to the system workspace center.
    let workspaceCenter: NotificationCenter
    private let workspaceObject: AnyObject
    private let hardware: any NativeAudioHardwareObserving
    private var sleepToken: NSObjectProtocol?
    private var removeDefaultOutput: (() -> Void)?
    private var removeDeviceAlive: (() -> Void)?
    private var handler: (() -> Void)?
    private var generation: UInt64 = 0
    private var deviceGeneration: UInt64 = 0

    init(workspaceCenter: NotificationCenter? = nil, workspaceObject: AnyObject? = nil,
         hardware: (any NativeAudioHardwareObserving)? = nil) {
        self.workspaceCenter = workspaceCenter ?? NSWorkspace.shared.notificationCenter
        self.workspaceObject = workspaceObject ?? NSWorkspace.shared
        self.hardware = hardware ?? CoreAudioOutputObserver()
    }

    func install(_ handler: @escaping () -> Void) {
        uninstall()
        self.handler = handler
        let installed = generation
        sleepToken = workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: workspaceObject, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == installed else { return }
                self.handler?()
            }
        }
        removeDefaultOutput = hardware.observe(object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            guard let self, self.generation == installed else { return }
            self.observeDeviceAlive(generation: installed)
            self.handler?()
        }
        observeDeviceAlive(generation: installed)
    }

    private func observeDeviceAlive(generation installed: UInt64) {
        deviceGeneration &+= 1
        let revision = deviceGeneration
        removeDeviceAlive?()
        removeDeviceAlive = nil
        let device = hardware.defaultOutputDevice
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }
        removeDeviceAlive = hardware.observe(object: device, selector: kAudioDevicePropertyDeviceIsAlive) { [weak self] in
            guard let self, self.generation == installed, self.deviceGeneration == revision else { return }
            self.handler?()
        }
    }

    func uninstall() {
        generation &+= 1 // Reject already queued callbacks from old registrations.
        deviceGeneration &+= 1
        handler = nil
        if let sleepToken { workspaceCenter.removeObserver(sleepToken) }
        sleepToken = nil
        removeDefaultOutput?()
        removeDefaultOutput = nil
        removeDeviceAlive?()
        removeDeviceAlive = nil
    }

    deinit {
        if let sleepToken { workspaceCenter.removeObserver(sleepToken) }
        removeDefaultOutput?()
        removeDeviceAlive?()
    }
}

@MainActor
final class AVNativeTTSPlayer: NativeTTSPlayback {
    enum PlayerError: Error { case refused }

    var eventHandler: ((NativeTTSPlaybackEvent) -> Void)?
    private var handle: (any NativeAudioHandle)?
    private var buffer: Data?
    private var tag: UUID?
    private var watchdog: Task<Void, Never>?
    private let makeHandle: (Data) throws -> any NativeAudioHandle
    private let interruptionSource: any NativeAudioInterruptionSource
    private let sleep: @Sendable (UInt64) async throws -> Void

    init(
        makeHandle: ((Data) throws -> any NativeAudioHandle)? = nil,
        interruptionSource: (any NativeAudioInterruptionSource)? = nil,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.makeHandle = makeHandle ?? { try AVAudioHandle(data: $0) }
        self.interruptionSource = interruptionSource ?? SystemNativeAudioInterruptionSource()
        self.sleep = sleep
        self.interruptionSource.install { [weak self] in self?.interrupt() }
    }

    func play(wav: Data, tag: UUID) throws {
        stop()
        let candidate = try makeHandle(wav)
        candidate.completion = { [weak self, weak candidate] success in
            Task { @MainActor in
                guard let self, let candidate, self.handle === candidate else { return }
                self.finish(tag: tag, success: success)
            }
        }
        candidate.prepare()
        buffer = wav
        handle = candidate
        self.tag = tag
        guard candidate.play() else {
            clear()
            throw PlayerError.refused
        }
        eventHandler?(.started(tag))
        guard handle === candidate, self.tag == tag else { return }

        // Duration is supplied by the decoded WAV. Clamp malformed/extreme values
        // while allowing a small callback grace period.
        let duration = candidate.duration.isFinite && candidate.duration >= 0 ? candidate.duration : 0
        let seconds = max(1, min(duration + 2, 600))
        let delay = UInt64(seconds * 1_000_000_000)
        let sleeper = sleep
        watchdog = Task { @MainActor [weak self, weak candidate] in
            do { try await sleeper(delay) } catch { return }
            guard let self, let candidate, self.handle === candidate, self.tag == tag else { return }
            candidate.stop()
            self.clear()
            self.eventHandler?(.failed(tag))
        }
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        handle?.completion = nil
        handle?.stop()
        clear()
    }

    /// Called by the installed production interruption source and available to
    /// deterministic tests. It is terminal exactly once for the current tag.
    func interrupt() {
        guard let tag else { return }
        watchdog?.cancel()
        watchdog = nil
        handle?.completion = nil
        handle?.stop()
        clear()
        eventHandler?(.interrupted(tag))
    }

    private func finish(tag: UUID, success: Bool) {
        guard self.tag == tag else { return }
        watchdog?.cancel()
        watchdog = nil
        clear()
        eventHandler?(success ? .finished(tag) : .failed(tag))
    }

    private func clear() {
        handle = nil
        buffer = nil
        tag = nil
    }

    deinit {
        watchdog?.cancel()
        // The source removes its NotificationCenter tokens in its own deinit.
    }
}
