import Foundation
import AVFoundation

/// Service for generating audio feedback sounds
final class AudioFeedback {
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    private let sampleRate: Double = 44100
    private var phase: Double = 0
    private var isPlaying = false
    private var samplesToPlay: Int = 0
    private var samplesPlayed: Int = 0
    private var isReady = false
    
    // Sound parameters
    private var startFrequency: Double = 0
    private var endFrequency: Double = 0
    private var attackSamples: Int = 0
    private var decaySamples: Int = 0

    init() {
        setupAudioEngine()
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()

        guard let audioEngine = audioEngine else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let buffer = ablPointer[0]
            let ptr = buffer.mData?.assumingMemoryBound(to: Float.self)

            for frame in 0..<Int(frameCount) {
                if self.isPlaying && self.samplesPlayed < self.samplesToPlay {
                    // Calculate progress (0 to 1)
                    let progress = Double(self.samplesPlayed) / Double(self.samplesToPlay)
                    
                    // Frequency sweep (exponential for more natural sound)
                    let frequency = self.startFrequency * pow(self.endFrequency / self.startFrequency, progress)
                    
                    // Envelope: attack then decay
                    var envelope: Double
                    if self.samplesPlayed < self.attackSamples {
                        // Attack phase - quick fade in
                        envelope = Double(self.samplesPlayed) / Double(self.attackSamples)
                        envelope = envelope * envelope // Quadratic for smoother attack
                    } else {
                        // Decay phase - smooth fade out
                        let decayProgress = Double(self.samplesPlayed - self.attackSamples) / Double(self.decaySamples)
                        envelope = 1.0 - decayProgress
                        envelope = envelope * envelope // Quadratic for smoother decay
                    }
                    
                    // Generate sample with envelope
                    let value = Float(sin(self.phase) * 0.25 * envelope)
                    ptr?[frame] = value
                    
                    // Update phase
                    self.phase += 2.0 * .pi * frequency / self.sampleRate
                    if self.phase > 2.0 * .pi {
                        self.phase -= 2.0 * .pi
                    }
                    self.samplesPlayed += 1
                } else {
                    ptr?[frame] = 0
                    self.isPlaying = false
                }
            }

            return noErr
        }

        guard let sourceNode = sourceNode else { return }

        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: format)

        do {
            try audioEngine.start()
            isReady = true
        } catch {
            AppLogger.audio.error("Failed to start audio engine for feedback: \(error.localizedDescription)")
        }
    }

    /// Play a frequency sweep with envelope
    /// - Parameters:
    ///   - startFreq: Starting frequency in Hz
    ///   - endFreq: Ending frequency in Hz
    ///   - duration: Total duration in seconds
    ///   - attackTime: Attack time in seconds (fade in)
    private func playBubble(startFreq: Double, endFreq: Double, duration: Double, attackTime: Double) {
        guard isReady else { return }
        phase = 0
        startFrequency = startFreq
        endFrequency = endFreq
        samplesToPlay = Int(sampleRate * duration)
        attackSamples = Int(sampleRate * attackTime)
        decaySamples = samplesToPlay - attackSamples
        samplesPlayed = 0
        isPlaying = true
    }

    /// Rising "bloop" when recording starts
    func beepOn() {
        // Rising bubble: low to high frequency, quick attack
        playBubble(startFreq: 280, endFreq: 580, duration: 0.15, attackTime: 0.02)
    }

    /// Descending "pop" when recording stops / transcription done
    func beepOff() {
        // Falling pop: high to low frequency, quick attack
        playBubble(startFreq: 520, endFreq: 320, duration: 0.12, attackTime: 0.015)
    }

    deinit {
        audioEngine?.stop()
    }
}
