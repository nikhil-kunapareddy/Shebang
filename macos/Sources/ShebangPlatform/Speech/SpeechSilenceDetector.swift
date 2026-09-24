import Foundation

/// Voice-activity end-pointing: once speech has been heard and the minimum recording time has passed,
/// recording stops after `silenceDuration` of quiet; it always stops at `maxDuration`. Times are seconds
/// on any monotonic clock.
public struct SpeechSilenceDetector: Sendable {
    public enum Decision: Equatable, Sendable {
        case keepRecording
        case stopAfterSilence
        case stopAtMaxDuration
    }

    /// Trailing silence that ends a recording.
    public static let defaultSilenceDuration: TimeInterval = 1.8
    /// RMS below this is silence.
    public static let defaultRMSThreshold: Float = 0.01
    /// Silence detection starts only after this much recording.
    public static let defaultMinRecordingDuration: TimeInterval = 0.5
    /// Hard cap on a recording.
    public static let defaultMaxDuration: TimeInterval = 30

    public let silenceDuration: TimeInterval
    public let rmsThreshold = SpeechSilenceDetector.defaultRMSThreshold
    public let minRecordingDuration = SpeechSilenceDetector.defaultMinRecordingDuration
    public let maxDuration = SpeechSilenceDetector.defaultMaxDuration

    public private(set) var hasSpeech = false
    private let startTime: TimeInterval
    private var silenceSince: TimeInterval

    public init(startTime: TimeInterval, silenceDuration: TimeInterval = defaultSilenceDuration) {
        self.startTime = startTime
        self.silenceSince = startTime
        self.silenceDuration = silenceDuration
    }

    /// Feeds the energy of one audio buffer captured at `time`.
    public mutating func process(rms: Float, at time: TimeInterval) -> Decision {
        if rms >= rmsThreshold {
            noteSpeech(at: time)
        }
        return evaluate(at: time)
    }

    /// Marks speech activity from another signal (e.g. a new partial transcript).
    public mutating func noteSpeech(at time: TimeInterval) {
        hasSpeech = true
        silenceSince = max(silenceSince, time)
    }

    public func evaluate(at time: TimeInterval) -> Decision {
        let elapsed = time - startTime
        if elapsed >= maxDuration { return .stopAtMaxDuration }
        if hasSpeech && elapsed >= minRecordingDuration && time - silenceSince >= silenceDuration {
            return .stopAfterSilence
        }
        return .keepRecording
    }

    /// Root-mean-square of float samples in [-1, 1].
    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples {
            sum += Double(sample) * Double(sample)
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    /// Root-mean-square of 16-bit PCM, normalized to [-1, 1] by dividing by 32768.
    public static func rms(pcm16 samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples {
            let normalized = Double(sample) / 32768
            sum += normalized * normalized
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }
}
