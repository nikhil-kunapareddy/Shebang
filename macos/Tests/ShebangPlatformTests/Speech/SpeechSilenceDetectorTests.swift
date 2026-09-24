import Testing
@testable import ShebangPlatform

@Suite struct SpeechSilenceDetectorTests {
    private let loud: Float = 0.2
    private let quiet: Float = 0.001

    @Test func thresholdsMatchWindowsBuild() {
        #expect(SpeechSilenceDetector.defaultSilenceDuration == 1.8)
        #expect(SpeechSilenceDetector.defaultRMSThreshold == 0.01)
        #expect(SpeechSilenceDetector.defaultMinRecordingDuration == 0.5)
        #expect(SpeechSilenceDetector.defaultMaxDuration == 30)
    }

    @Test func stopsAfterTrailingSilenceFollowingSpeech() {
        var detector = SpeechSilenceDetector(startTime: 100)
        #expect(detector.process(rms: loud, at: 100.2) == .keepRecording)
        #expect(detector.process(rms: loud, at: 101.0) == .keepRecording)
        #expect(detector.process(rms: quiet, at: 102.0) == .keepRecording)
        #expect(detector.process(rms: quiet, at: 102.79) == .keepRecording)
        #expect(detector.process(rms: quiet, at: 102.81) == .stopAfterSilence)
        #expect(detector.hasSpeech)
    }

    @Test func silenceWithoutSpeechNeverEndsEarly_onlyAtMaxDuration() {
        var detector = SpeechSilenceDetector(startTime: 0)
        for tick in stride(from: 0.1, to: 30, by: 0.5) {
            #expect(detector.process(rms: quiet, at: tick) == .keepRecording)
        }
        #expect(detector.process(rms: quiet, at: 30) == .stopAtMaxDuration)
        #expect(!detector.hasSpeech)
    }

    @Test func continuousSpeechStopsAtMaxDuration() {
        var detector = SpeechSilenceDetector(startTime: 0)
        #expect(detector.process(rms: loud, at: 29.9) == .keepRecording)
        #expect(detector.process(rms: loud, at: 30.0) == .stopAtMaxDuration)
    }

    @Test func silenceDetectionWaitsForMinimumRecordingTime() {
        var detector = SpeechSilenceDetector(startTime: 0, silenceDuration: 0.1)
        #expect(detector.process(rms: loud, at: 0.0) == .keepRecording)
        #expect(detector.process(rms: quiet, at: 0.3) == .keepRecording)
        #expect(detector.process(rms: quiet, at: 0.5) == .stopAfterSilence)
    }

    @Test func renewedSpeechResetsTheSilenceTimer() {
        var detector = SpeechSilenceDetector(startTime: 0)
        _ = detector.process(rms: loud, at: 1)
        #expect(detector.process(rms: quiet, at: 2.5) == .keepRecording)
        _ = detector.process(rms: loud, at: 2.6)
        #expect(detector.process(rms: quiet, at: 4.3) == .keepRecording)
        #expect(detector.process(rms: quiet, at: 4.4) == .stopAfterSilence)
    }

    @Test func partialTranscriptCountsAsSpeech() {
        var detector = SpeechSilenceDetector(startTime: 0)
        detector.noteSpeech(at: 1)
        #expect(detector.hasSpeech)
        #expect(detector.evaluate(at: 2.7) == .keepRecording)
        #expect(detector.evaluate(at: 2.81) == .stopAfterSilence)
    }

    @Test func rmsThresholdBoundary() {
        var detector = SpeechSilenceDetector(startTime: 0)
        _ = detector.process(rms: 0.0099, at: 1)
        #expect(!detector.hasSpeech)
        _ = detector.process(rms: 0.01, at: 1.1)
        #expect(detector.hasSpeech)
    }

    @Test func rmsOfFloatSamples() {
        #expect(SpeechSilenceDetector.rms([Float]()) == 0)
        #expect(SpeechSilenceDetector.rms([0.5, -0.5, 0.5, -0.5]) == 0.5)
        #expect(abs(SpeechSilenceDetector.rms([1, 0]) - 0.70710678) < 0.0001)
    }

    @Test func rmsOfPCM16SamplesIsNormalized() {
        #expect(SpeechSilenceDetector.rms(pcm16: []) == 0)
        #expect(SpeechSilenceDetector.rms(pcm16: [16384, -16384]) == 0.5)
        #expect(SpeechSilenceDetector.rms(pcm16: [0, 0, 0]) == 0)
    }
}
