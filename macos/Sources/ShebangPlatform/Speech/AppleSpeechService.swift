import AVFoundation
import Foundation
import ShebangCore
import Speech

public enum SpeechInputError: Error, LocalizedError, Equatable {
    case noMicrophone
    case microphoneDenied
    case speechRecognitionDenied
    case recognizerUnavailable
    case alreadyRecording
    case audioEngineFailed(String)
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No active microphone detected. Connect a microphone or headset, or check "
                + "System Settings → Privacy & Security → Microphone."
        case .microphoneDenied:
            return "Shebang doesn't have microphone access. Allow it in System Settings → Privacy & Security → Microphone."
        case .speechRecognitionDenied:
            return "Shebang doesn't have speech recognition access. Allow it in "
                + "System Settings → Privacy & Security → Speech Recognition."
        case .recognizerUnavailable:
            return "Speech recognition is not available for the current language right now."
        case .alreadyRecording:
            return "Voice input is already recording."
        case .audioEngineFailed(let detail):
            return "Microphone recording failed. Check microphone permissions. \(detail)"
        case .recognitionFailed(let detail):
            return "Speech transcription failed: \(detail)"
        }
    }
}

/// Dictation with SFSpeechRecognizer (on-device when supported) fed by an AVAudioEngine input tap.
/// Recording ends on trailing silence, the 30 s cap, `stopRecording()`, or task cancellation
/// (which throws `CancellationError`).
public final class AppleSpeechService: SpeechInput {
    private let locale: Locale
    private let environment: SpeechServiceEnvironment
    private let lock = NSLock()
    private var isBusy = false
    private var stopRequested = false
    private var session: SpeechRecognitionSession?

    public convenience init() {
        self.init(locale: .current, environment: SystemSpeechEnvironment())
    }

    init(locale: Locale, environment: SpeechServiceEnvironment) {
        self.locale = locale
        self.environment = environment
    }

    public func transcribe(onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        guard beginRecording() else { throw SpeechInputError.alreadyRecording }
        defer { endRecording() }

        do {
            return try await recognize(onPartial: onPartial)
        } catch is CancellationError {
            Log.speech.info("Voice recording cancelled")
            throw CancellationError()
        }
    }

    public func stopRecording() {
        lock.lock()
        let current = session
        if isBusy { stopRequested = true }
        lock.unlock()
        current?.stop()
    }

    private func recognize(onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        guard environment.hasAudioInputDevice else {
            Log.speech.warning("No audio input device found")
            throw SpeechInputError.noMicrophone
        }
        guard await environment.requestSpeechAuthorization() else { throw SpeechInputError.speechRecognitionDenied }
        try Task.checkCancellation()
        guard await environment.requestMicrophoneAuthorization() else { throw SpeechInputError.microphoneDenied }
        try Task.checkCancellation()
        guard let recognizer = environment.makeRecognizer(locale: locale) else {
            throw SpeechInputError.recognizerUnavailable
        }

        let session = SpeechRecognitionSession(recognizer: recognizer, onPartial: onPartial)
        let stoppedEarly = attach(session)
        defer { attach(nil) }
        if stoppedEarly { return "" }

        return try await withTaskCancellationHandler {
            try await session.run()
        } onCancel: {
            session.cancel()
        }
    }

    /// Publishes the active session for `stopRecording()`; returns true if a stop was already requested.
    @discardableResult
    private func attach(_ session: SpeechRecognitionSession?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
        return stopRequested
    }

    private func beginRecording() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isBusy else { return false }
        isBusy = true
        stopRequested = false
        return true
    }

    private func endRecording() {
        lock.lock()
        isBusy = false
        stopRequested = false
        lock.unlock()
    }
}

/// Seam over device discovery, TCC, and recognizer creation so tests never touch the microphone.
protocol SpeechServiceEnvironment: AnyObject {
    var hasAudioInputDevice: Bool { get }
    func requestSpeechAuthorization() async -> Bool
    func requestMicrophoneAuthorization() async -> Bool
    /// Returns nil when no recognizer is available for `locale`.
    func makeRecognizer(locale: Locale) -> SFSpeechRecognizer?
}

final class SystemSpeechEnvironment: SpeechServiceEnvironment {
    var hasAudioInputDevice: Bool {
        AVCaptureDevice.default(for: .audio) != nil
    }

    func requestSpeechAuthorization() async -> Bool {
        await Permissions.requestSpeechRecognition()
    }

    func requestMicrophoneAuthorization() async -> Bool {
        await Permissions.requestMicrophone()
    }

    func makeRecognizer(locale: Locale) -> SFSpeechRecognizer? {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable
        else { return nil }
        return recognizer
    }
}

/// One recording: audio engine tap → recognition request, with silence end-pointing.
final class SpeechRecognitionSession: @unchecked Sendable {
    private enum EndReason: String {
        case silence, maxDuration = "max duration", manual
    }

    /// How long to wait for the recognizer's final result after the audio ends.
    private static let finalizationTimeout: TimeInterval = 3

    private let recognizer: SFSpeechRecognizer
    private let onPartial: @Sendable (String) -> Void
    private let engine = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let control = DispatchQueue(label: "com.shebang.mac.speech-session")
    private let resultQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var detector: SpeechSilenceDetector
    private var latestTranscript = ""
    private var audioEnded = false
    private var finished = false
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false // control queue only

    init(recognizer: SFSpeechRecognizer, onPartial: @escaping @Sendable (String) -> Void) {
        self.recognizer = recognizer
        self.onPartial = onPartial
        self.detector = SpeechSilenceDetector(startTime: Self.now())
        recognizer.queue = resultQueue
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func run() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
            control.async { self.start() }
        }
    }

    func stop() {
        control.async { self.endAudio(.manual) }
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    private func start() {
        lock.lock()
        let alreadyFinished = finished
        lock.unlock()
        guard !alreadyFinished else { return }

        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        let onDevice = recognizer.supportsOnDeviceRecognition
        if onDevice { request.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            complete(.failure(SpeechInputError.noMicrophone))
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        tapInstalled = true
        engine.prepare()
        lock.lock()
        detector = SpeechSilenceDetector(startTime: Self.now())
        lock.unlock()
        do {
            try engine.start()
        } catch {
            complete(.failure(SpeechInputError.audioEngineFailed(error.localizedDescription)))
            return
        }

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
        lock.lock()
        let cancelledMeanwhile = finished
        if !cancelledMeanwhile { self.task = task }
        let maxDuration = detector.maxDuration
        lock.unlock()
        if cancelledMeanwhile {
            task.cancel()
            return
        }

        // Backstop in case the input stops delivering buffers (device unplugged).
        control.asyncAfter(deadline: .now() + maxDuration + 1) { [weak self] in
            self?.endAudio(.maxDuration)
        }
        Log.speech.info("Listening (on-device: \(onDevice, privacy: .public))")
    }

    /// Audio tap thread.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
        let level = Self.rms(of: buffer)
        lock.lock()
        let decision = detector.process(rms: level, at: Self.now())
        lock.unlock()

        switch decision {
        case .keepRecording: break
        case .stopAfterSilence: control.async { self.endAudio(.silence) }
        case .stopAtMaxDuration: control.async { self.endAudio(.maxDuration) }
        }
    }

    /// Control queue.
    private func endAudio(_ reason: EndReason) {
        lock.lock()
        guard !audioEnded, !finished else {
            lock.unlock()
            return
        }
        audioEnded = true
        let heardSpeech = detector.hasSpeech || !latestTranscript.isEmpty
        lock.unlock()

        stopEngine()
        request.endAudio()
        Log.speech.info("Recording stopped (\(reason.rawValue, privacy: .public))")

        if !heardSpeech && reason != .manual {
            Log.speech.info("No speech detected")
            complete(.success(""))
            return
        }
        control.asyncAfter(deadline: .now() + Self.finalizationTimeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let transcript = self.latestTranscript
            self.lock.unlock()
            self.complete(.success(transcript))
        }
    }

    /// Recognizer result queue.
    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            lock.lock()
            let isNew = !text.isEmpty && text != latestTranscript
            if isNew {
                latestTranscript = text
                detector.noteSpeech(at: Self.now())
            }
            let done = finished
            lock.unlock()

            if isNew && !done { onPartial(text) }
            if result.isFinal {
                complete(.success(text))
                return
            }
        }

        if let error {
            lock.lock()
            let transcript = latestTranscript
            let ended = audioEnded
            lock.unlock()

            let noSpeech = (error as NSError).code == 1110 // kAFAssistantErrorDomain "No speech detected"
            if ended || noSpeech || !transcript.isEmpty {
                complete(.success(transcript))
            } else {
                complete(.failure(SpeechInputError.recognitionFailed(error.localizedDescription)))
            }
        }
    }

    private func complete(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        lock.unlock()

        task?.cancel()
        control.async { self.stopEngine() }
        if case .success(let text) = result {
            Log.speech.info("Transcription finished (\(text.count, privacy: .public) chars)")
        }
        continuation?.resume(with: result)
    }

    /// Control queue.
    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        if let floats = buffer.floatChannelData {
            return SpeechSilenceDetector.rms(UnsafeBufferPointer(start: floats[0], count: frames))
        }
        if let ints = buffer.int16ChannelData {
            return SpeechSilenceDetector.rms(pcm16: Array(UnsafeBufferPointer(start: ints[0], count: frames)))
        }
        return 0
    }
}
