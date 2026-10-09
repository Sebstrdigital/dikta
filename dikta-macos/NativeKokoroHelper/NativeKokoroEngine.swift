import Foundation
import FluidAudio
#if canImport(NativeKokoroShared)
import NativeKokoroShared
#endif

// Not constructed by the inert helper loop yet. F2 qualification operations are pending.
// The manager is deliberately constructed only after policy and verified assets.
final class NativeKokoroEngine: NKEngineBackend {
    private var manager: KokoroAneManager?
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
    func synthesize(phonemes: String) async throws -> NKEngineSamples {
        guard let manager else { throw NKRuntimeFailure.notReady }
        let result = try await manager.synthesizeFromPhonemesDetailed(phonemes, voice: "af_heart", speed: 1)
        return NKEngineSamples(samples: result.samples, sampleRate: result.sampleRate)
    }
    func wav(samples: [Float]) throws -> Data {
        try AudioWAV.data(from: samples, sampleRate: 24000, normalize: false)
    }
}
