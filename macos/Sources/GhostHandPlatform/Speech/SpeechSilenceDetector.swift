import Foundation

/// Voice-activity end-pointing ported from WhisperSpeechService: once speech has been heard and the
/// minimum recording time has passed, recording stops after `silenceDuration` of quiet; it always
/// stops at `maxDuration`. Times are seconds on any monotonic clock.
public struct SpeechSilenceDetector: Sendable {
    public enum Decision: Equatable, Sendable {
        case keepRecording
        case stopAfterSilence
        case stopAtMaxDuration
    }

    /// Trailing silence that ends a recording (C# `SilenceThresholdMs` = 1800).
    public static let defaultSilenceDuration: TimeInterval = 1.8
    /// RMS below this is silence (C# `SilenceRmsThreshold` = 0.01).
    public static let defaultRMSThreshold: Float = 0.01
    /// Silence detection starts only after this much recording (C# `MinRecordingMs` = 500).
    public static let defaultMinRecordingDuration: TimeInterval = 0.5
    /// Hard cap on a recording (C# 30 s timeout).
    public static let defaultMaxDuration: TimeInterval = 30

    public let silenceDuration: TimeInterval
    public let rmsThreshold: Float
    public let minRecordingDuration: TimeInterval
    public let maxDuration: TimeInterval

    public private(set) var hasSpeech = false
    private let startTime: TimeInterval
    private var silenceSince: TimeInterval

    public init(
        startTime: TimeInterval,
        silenceDuration: TimeInterval = defaultSilenceDuration,
        rmsThreshold: Float = defaultRMSThreshold,
        minRecordingDuration: TimeInterval = defaultMinRecordingDuration,
        maxDuration: TimeInterval = defaultMaxDuration
    ) {
        self.startTime = startTime
        self.silenceSince = startTime
        self.silenceDuration = silenceDuration
        self.rmsThreshold = rmsThreshold
        self.minRecordingDuration = minRecordingDuration
        self.maxDuration = maxDuration
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

    public static func rms(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rms($0) }
    }

    /// Root-mean-square of 16-bit PCM, normalized by 32768 as in the Windows build.
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
