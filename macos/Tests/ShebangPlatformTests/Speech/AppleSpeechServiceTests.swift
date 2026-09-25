import Foundation
import ShebangCore
import Speech
import Testing
@testable import ShebangPlatform

/// Never touches the microphone, TCC, or a real recognizer.
private final class FakeSpeechEnvironment: SpeechServiceEnvironment, @unchecked Sendable {
    var hasAudioInputDevice = true
    var speechAuthorized = true
    var microphoneAuthorized = true
    var recognizerRequests = 0
    /// When set, speech authorization suspends until `releaseGate()`.
    var gated = false

    private let lock = NSLock()
    private var gateContinuation: CheckedContinuation<Void, Never>?

    var isWaitingAtGate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gateContinuation != nil
    }

    func releaseGate() {
        lock.lock()
        let continuation = gateContinuation
        gateContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func requestSpeechAuthorization() async -> Bool {
        if gated {
            await withCheckedContinuation { continuation in
                lock.lock()
                gateContinuation = continuation
                lock.unlock()
            }
        }
        return speechAuthorized
    }

    func requestMicrophoneAuthorization() async -> Bool {
        microphoneAuthorized
    }

    func makeRecognizer(locale: Locale) -> SFSpeechRecognizer? {
        recognizerRequests += 1
        return nil
    }
}

@Suite struct AppleSpeechServiceTests {
    private func makeService(_ environment: FakeSpeechEnvironment) -> AppleSpeechService {
        AppleSpeechService(locale: Locale(identifier: "en-US"), environment: environment)
    }

    @Test func noAudioDevice_throwsDescriptiveError() async {
        let environment = FakeSpeechEnvironment()
        environment.hasAudioInputDevice = false

        do {
            _ = try await makeService(environment).transcribe(onPartial: { _ in })
            Issue.record("Expected an error")
        } catch {
            #expect(error as? SpeechInputError == .noMicrophone)
            #expect(error.localizedDescription.lowercased().contains("microphone"))
        }
        #expect(environment.recognizerRequests == 0)
    }

    @Test func recognizerUnavailable_throws() async {
        let environment = FakeSpeechEnvironment()
        await #expect(throws: SpeechInputError.recognizerUnavailable) {
            _ = try await makeService(environment).transcribe(onPartial: { _ in })
        }
        #expect(environment.recognizerRequests == 1)
    }

    @Test func speechRecognitionDenied_throwsWithoutCreatingRecognizer() async {
        let environment = FakeSpeechEnvironment()
        environment.speechAuthorized = false
        await #expect(throws: SpeechInputError.speechRecognitionDenied) {
            _ = try await makeService(environment).transcribe(onPartial: { _ in })
        }
        #expect(environment.recognizerRequests == 0)
    }

    @Test func microphoneDenied_throwsDescriptiveError() async {
        let environment = FakeSpeechEnvironment()
        environment.microphoneAuthorized = false
        await #expect(throws: SpeechInputError.microphoneDenied) {
            _ = try await makeService(environment).transcribe(onPartial: { _ in })
        }
        #expect(SpeechInputError.microphoneDenied.localizedDescription.contains("Microphone"))
    }

    @Test func cancelledTask_throwsCancellationError() async {
        let environment = FakeSpeechEnvironment()
        environment.hasAudioInputDevice = false
        let service = makeService(environment)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.transcribe(onPartial: { _ in })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test(.timeLimit(.minutes(1)))
    func secondConcurrentTranscription_isRejected() async throws {
        let environment = FakeSpeechEnvironment()
        environment.gated = true
        environment.speechAuthorized = false
        let service = makeService(environment)

        let first = Task { try await service.transcribe(onPartial: { _ in }) }
        while !environment.isWaitingAtGate { await Task.yield() }

        await #expect(throws: SpeechInputError.alreadyRecording) {
            _ = try await service.transcribe(onPartial: { _ in })
        }

        environment.releaseGate()
        await #expect(throws: SpeechInputError.speechRecognitionDenied) { _ = try await first.value }

        // The service is reusable afterwards.
        environment.gated = false
        environment.hasAudioInputDevice = false
        await #expect(throws: SpeechInputError.noMicrophone) {
            _ = try await service.transcribe(onPartial: { _ in })
        }
    }

    @Test func stopRecordingWhileIdle_isHarmless() {
        makeService(FakeSpeechEnvironment()).stopRecording()
    }
}
