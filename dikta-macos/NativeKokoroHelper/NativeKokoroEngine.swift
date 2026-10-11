import Foundation
import Darwin
import FluidAudio
#if canImport(NativeKokoroShared)
import NativeKokoroShared
#endif

// Not constructed by the inert helper loop yet. F2 qualification operations are pending.
// The manager is deliberately constructed only after policy and verified assets.
final class NativeKokoroEngine: NKEngineBackend {
    private static let acousticObservationLock = NSLock()
    private static var acousticCallActive = false
    private var manager: KokoroAneManager?

    // Qualification-only, content-free observation of the exact SDK acoustic-call boundary.
    // The lock lets the control owner attest that cancellation arrived before this call returned.
    static var isAcousticCallActive: Bool {
        acousticObservationLock.lock(); defer { acousticObservationLock.unlock() }
        return acousticCallActive
    }
    private static func setAcousticCallActive(_ active: Bool) {
        acousticObservationLock.lock(); acousticCallActive = active; acousticObservationLock.unlock()
        let marker = active ? "NK_QUAL_ACOUSTIC_CALL_BEGIN\n" : "NK_QUAL_ACOUSTIC_CALL_RETURN\n"
        marker.withCString { pointer in _ = Darwin.write(STDERR_FILENO, pointer, strlen(pointer)) }
    }
    static func qualificationEngine(manifestData: Data) throws -> NKVerifiedEngine {
        let manifest = try NKAssetManifest.decodePinned(manifestData)
        let layout = NKAssetLayout()
        return NKVerifiedEngine(backend: NativeKokoroEngine(), layout: layout,
                                os: ProcessInfo.processInfo.operatingSystemVersion,
                                policy: privacyPolicy,
                                verify: { try NKAssetVerifier.verify(manifest, layout: layout) })
    }
    static func privacyPolicy() {
        ModelHub.offlineMode = true
        AppLogger.minimumLevel = .fault
        AppLogger.mirrorsToConsole = false
    }
    func initialize(modelsRoot: URL) async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else { throw NKRuntimeFailure.layout }
        Self.privacyPolicy()
        let instance = KokoroAneManager(variant: .english, defaultVoice: "af_heart", directory: modelsRoot)
        try await instance.initialize()
        manager = instance
    }
    func phonemes(text: String) async throws -> String {
        guard let manager else { throw NKRuntimeFailure.notReady }
        return try await manager.phonemes(for: text)
    }
    func synthesize(phonemes: String, voiceID: String, speed: Float) async throws -> NKEngineSamples {
        guard let manager, NKVoiceCatalog.entry(voiceID) != nil else { throw NKRuntimeFailure.notReady }
        Self.setAcousticCallActive(true)
        defer { Self.setAcousticCallActive(false) }
        // The manager remains English for both American and British timbres. The
        // verified request-pinned voice pack is the only per-request variation.
        let result = try await manager.synthesizeFromPhonemesDetailed(phonemes, voice: voiceID, speed: speed)
        return NKEngineSamples(samples: result.samples, sampleRate: result.sampleRate)
    }
    func wav(samples: [Float]) throws -> Data {
        try AudioWAV.data(from: samples, sampleRate: 24000, normalize: false)
    }
}
