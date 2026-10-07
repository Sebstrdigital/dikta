import XCTest
@testable import Dikta

final class AudioFeedbackCueTests: XCTestCase {
    func testProductionRoutingUsesDedicatedCuesAndUnchangedRecordingSweeps() {
        var cues: [AudioFeedbackCue] = []
        let feedback = AudioFeedback(sweepSink: { cues.append($0) })
        feedback.beepOn()
        feedback.beepOff()
        feedback.readAloudStart()
        feedback.readAloudStop()
        XCTAssertEqual(cues, [
            AudioFeedbackCue(startFrequency: 280, endFrequency: 580, duration: 0.15, attack: 0.02),
            AudioFeedbackCue(startFrequency: 520, endFrequency: 320, duration: 0.12, attack: 0.015),
            AudioFeedbackCue(startFrequency: 740, endFrequency: 1100, duration: 0.15, attack: 0.02),
            AudioFeedbackCue(startFrequency: 1000, endFrequency: 700, duration: 0.12, attack: 0.015)
        ])
        XCTAssertNotEqual(AudioFeedbackCue.recordingStart, .readAloudStart)
        XCTAssertNotEqual(AudioFeedbackCue.recordingStop, .readAloudStop)
    }

    func testProductionMuteSuppressesBothReadAloudAndRecordingCues() {
        var cues: [AudioFeedbackCue] = []
        let feedback = AudioFeedback(sweepSink: { cues.append($0) })
        feedback.isMuted = true
        feedback.readAloudStart()
        feedback.readAloudStop()
        feedback.beepOn()
        feedback.beepOff()
        XCTAssertTrue(cues.isEmpty)
        feedback.isMuted = false
        feedback.readAloudStart()
        feedback.readAloudStop()
        XCTAssertEqual(cues, [.readAloudStart, .readAloudStop])
    }
}
