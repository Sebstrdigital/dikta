import Foundation
import AVFoundation

/// Service for generating audio feedback beeps
final class AudioFeedback {
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    private let sampleRate: Double = 44100
    private var phase: Double = 0
    private var targetFrequency: Double = 0
    private var isPlaying = false
    private var samplesToPlay: Int = 0
    private var samplesPlayed: Int = 0

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
                    let value = Float(sin(self.phase) * 0.2)
                    ptr?[frame] = value
                    self.phase += 2.0 * .pi * self.targetFrequency / self.sampleRate
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
        } catch {
            print("Failed to start audio engine for feedback: \(error)")
        }
    }

    /// Play a tone at the specified frequency and duration
    func playTone(frequency: Double, duration: Double) {
        phase = 0
        targetFrequency = frequency
        samplesToPlay = Int(sampleRate * duration)
        samplesPlayed = 0
        isPlaying = true
    }

    /// Beep when recording starts (350 Hz, 0.12s)
    func beepOn() {
        playTone(frequency: 350, duration: 0.12)
    }

    /// Beep when recording stops (280 Hz, 0.12s)
    func beepOff() {
        playTone(frequency: 280, duration: 0.12)
    }

    deinit {
        audioEngine?.stop()
    }
}
