import Foundation
import Testing
@testable import TranscriptCore

@Suite struct PauseDetectorTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func detector() -> PauseDetector {
        var detector = PauseDetector(silenceTimeout: 2, noSpeechTimeout: 8)
        detector.start(at: t0)
        return detector
    }

    @Test func finishesAfterSilenceFollowingWords() {
        var vad = detector()
        vad.words(3, at: t0 + 1)
        #expect(!vad.shouldFinish(at: t0 + 2.9))
        #expect(vad.shouldFinish(at: t0 + 3.0))
    }

    @Test func newWordsResetTheSilence() {
        var vad = detector()
        vad.words(3, at: t0 + 1)
        vad.words(5, at: t0 + 2.5)
        #expect(!vad.shouldFinish(at: t0 + 4))
        #expect(vad.shouldFinish(at: t0 + 4.5))
    }

    @Test func finalizingWithoutNewWordsDoesNotDelay() {
        var vad = detector()
        vad.words(4, at: t0 + 1)
        vad.words(4, at: t0 + 2)  // same words, finalized
        #expect(vad.shouldFinish(at: t0 + 3))
    }

    @Test func loudLevelsCountAsVoice() {
        var vad = detector()
        vad.level(0.05, at: t0 + 0.1)  // quiet room
        vad.words(2, at: t0 + 1)
        vad.level(0.7, at: t0 + 2.5)   // still talking, words not in yet
        #expect(!vad.shouldFinish(at: t0 + 3.5))
        #expect(vad.shouldFinish(at: t0 + 4.5))
    }

    @Test func steadyRoomNoiseDoesNotCountAsVoice() {
        var vad = detector()
        vad.words(2, at: t0 + 1)
        // A noisy room just under the absolute minimum, steady: never voice.
        for step in 0..<30 {
            vad.level(0.28, at: t0 + 1 + Double(step) * 0.1)
        }
        #expect(vad.shouldFinish(at: t0 + 3.1))
    }

    @Test func givesUpIfNothingIsSaid() {
        let vad = detector()
        #expect(!vad.shouldFinish(at: t0 + 7.9))
        #expect(vad.shouldFinish(at: t0 + 8))
        #expect(!vad.heardSpeech)
    }

    @Test func levelsAloneDoNotEndTheWaitForWords() {
        var vad = detector()
        vad.level(0.8, at: t0 + 1)  // a noise, but no words
        #expect(!vad.shouldFinish(at: t0 + 3.5))  // still waiting for speech (8 s)
    }
}
