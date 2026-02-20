import Foundation
import AVFoundation
import os

/// Service for generating audio feedback sounds
final class AudioFeedback {
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    var isMuted: Bool = false

    private let sampleRate: Double = 44100
    private var isReady = false

    // Lock for synchronizing shared mutable state between audio render thread and main thread
    private var lock = os_unfair_lock()

    // Shared mutable state — must be accessed while holding `lock`
    private var phase: Double = 0
    private var isPlaying = false
    private var samplesToPlay: Int = 0
    private var samplesPlayed: Int = 0
    private var startFrequency: Double = 0
    private var endFrequency: Double = 0
    private var attackSamples: Int = 0
    private var decaySamples: Int = 0

    init() {
        rebuildEngine()
    }

    /// Tears down the existing audio engine (if any) and builds a fresh one.
    private func rebuildEngine() {
        // --- Tear down old engine ---
        if let oldEngine = audioEngine {
            NotificationCenter.default.removeObserver(
                self,
                name: .AVAudioEngineConfigurationChange,
                object: oldEngine
            )
            if oldEngine.isRunning {
                oldEngine.stop()
            }
            if let oldNode = sourceNode {
                oldEngine.disconnectNodeOutput(oldNode)
                oldEngine.detach(oldNode)
            }
        }
        sourceNode = nil
        audioEngine = nil
        isReady = false

        // --- Build new engine ---
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let buffer = ablPointer[0]
            let ptr = buffer.mData?.assumingMemoryBound(to: Float.self)

            // Lock and copy shared state to local variables
            os_unfair_lock_lock(&self.lock)
            var localIsPlaying = self.isPlaying
            var localSamplesPlayed = self.samplesPlayed
            let localSamplesToPlay = self.samplesToPlay
            var localPhase = self.phase
            let localStartFrequency = self.startFrequency
            let localEndFrequency = self.endFrequency
            let localAttackSamples = self.attackSamples
            let localDecaySamples = self.decaySamples
            os_unfair_lock_unlock(&self.lock)

            for frame in 0..<Int(frameCount) {
                if localIsPlaying && localSamplesPlayed < localSamplesToPlay {
                    // Calculate progress (0 to 1)
                    let progress = Double(localSamplesPlayed) / Double(localSamplesToPlay)

                    // Frequency sweep (exponential for more natural sound)
                    let frequency = localStartFrequency * pow(localEndFrequency / localStartFrequency, progress)

                    // Envelope: attack then decay
                    var envelope: Double
                    if localSamplesPlayed < localAttackSamples {
                        // Attack phase - quick fade in
                        envelope = Double(localSamplesPlayed) / Double(localAttackSamples)
                        envelope = envelope * envelope // Quadratic for smoother attack
                    } else {
                        // Decay phase - smooth fade out
                        let decayProgress = Double(localSamplesPlayed - localAttackSamples) / Double(localDecaySamples)
                        envelope = 1.0 - decayProgress
                        envelope = envelope * envelope // Quadratic for smoother decay
                    }

                    // Generate sample with envelope
                    let value = Float(sin(localPhase) * 0.25 * envelope)
                    ptr?[frame] = value

                    // Update phase
                    localPhase += 2.0 * .pi * frequency / self.sampleRate
                    if localPhase > 2.0 * .pi {
                        localPhase -= 2.0 * .pi
                    }
                    localSamplesPlayed += 1
                } else {
                    ptr?[frame] = 0
                    localIsPlaying = false
                }
            }

            // Write back updated state
            os_unfair_lock_lock(&self.lock)
            self.isPlaying = localIsPlaying
            self.samplesPlayed = localSamplesPlayed
            self.phase = localPhase
            os_unfair_lock_unlock(&self.lock)

            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            isReady = true
        } catch {
            AppLogger.audio.error("Failed to start audio engine for feedback: \(error.localizedDescription)")
        }

        audioEngine = engine
        sourceNode = node

        // Observe configuration changes on the new engine
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    /// Called when the audio hardware configuration changes (e.g. headphones plugged/unplugged).
    @objc private func handleConfigurationChange(_ notification: Notification) {
        AppLogger.audio.info("Audio engine configuration changed, rebuilding...")
        rebuildEngine()
        AppLogger.audio.info("Audio engine restarted due to configuration change")
    }

    /// Play a frequency sweep with envelope
    /// - Parameters:
    ///   - startFreq: Starting frequency in Hz
    ///   - endFreq: Ending frequency in Hz
    ///   - duration: Total duration in seconds
    ///   - attackTime: Attack time in seconds (fade in)
    private func playBubble(startFreq: Double, endFreq: Double, duration: Double, attackTime: Double) {
        // Health check: restart engine if it stopped unexpectedly
        if isReady && !(audioEngine?.isRunning ?? false) {
            AppLogger.audio.warning("Audio engine stopped unexpectedly, restarting...")
            rebuildEngine()
        }

        guard isReady else { return }

        os_unfair_lock_lock(&lock)
        phase = 0
        startFrequency = startFreq
        endFrequency = endFreq
        samplesToPlay = Int(sampleRate * duration)
        attackSamples = Int(sampleRate * attackTime)
        decaySamples = samplesToPlay - attackSamples
        samplesPlayed = 0
        isPlaying = true
        os_unfair_lock_unlock(&lock)
    }

    /// Rising "bloop" when recording starts
    func beepOn() {
        guard !isMuted else { return }
        // Rising bubble: low to high frequency, quick attack
        playBubble(startFreq: 280, endFreq: 580, duration: 0.15, attackTime: 0.02)
    }

    /// Descending "pop" when recording stops / transcription done
    func beepOff() {
        guard !isMuted else { return }
        // Falling pop: high to low frequency, quick attack
        playBubble(startFreq: 520, endFreq: 320, duration: 0.12, attackTime: 0.015)
    }

    deinit {
        if let engine = audioEngine {
            NotificationCenter.default.removeObserver(
                self,
                name: .AVAudioEngineConfigurationChange,
                object: engine
            )
        }
        audioEngine?.stop()
    }
}
