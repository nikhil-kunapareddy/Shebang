import Foundation
import GhostHandCore
import Speech
import Testing
@testable import GhostHandPlatform

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

private final class FakeFallbackSpeech: SpeechInput, @unchecked Sendable {
    let transcript: String
    private(set) var calls = 0

    init(_ transcript: String) {
        self.transcript = transcript
    }

    func transcribe(onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        calls += 1
        onPartial(transcript)
        return transcript
    }

    func stopRecording() {}
}

@Suite struct AppleSpeechServiceTests {
    private func makeService(_ environment: FakeSpeechEnvironment, fallback: SpeechInput? = nil) -> AppleSpeechService {
        AppleSpeechService(locale: Locale(identifier: "en-US"), fallback: fallback, environment: environment)
    }

    @Test func VO01_noAudioDevice_fallsBackToSecondaryService() async throws {
        let environment = FakeSpeechEnvironment()
        environment.hasAudioInputDevice = false
        let fallback = FakeFallbackSpeech("fallback transcript")

        let result = try await makeService(environment, fallback: fallback).transcribe(onPartial: { _ in })
        #expect(result == "fallback transcript")
        #expect(fallback.calls == 1)
        #expect(environment.recognizerRequests == 0)
    }

    @Test func VO01_noDeviceAndNoFallback_throwsDescriptiveError() async {
        let environment = FakeSpeechEnvironment()
        environment.hasAudioInputDevice = false

        do {
            _ = try await makeService(environment).transcribe(onPartial: { _ in })
            Issue.record("Expected an error")
        } catch {
            #expect(error as? SpeechInputError == .noMicrophone)
            #expect(error.localizedDescription.lowercased().contains("microphone"))
        }
    }

    @Test func VO03_recognizerUnavailable_fallsBackGracefully() async throws {
        let environment = FakeSpeechEnvironment()
        let fallback = FakeFallbackSpeech("fallback result")

        let result = try await makeService(environment, fallback: fallback).transcribe(onPartial: { _ in })
        #expect(result == "fallback result")
        #expect(environment.recognizerRequests == 1)
    }

    @Test func recognizerUnavailableWithoutFallback_throws() async {
        await #expect(throws: SpeechInputError.recognizerUnavailable) {
            _ = try await makeService(FakeSpeechEnvironment()).transcribe(onPartial: { _ in })
        }
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

    @Test func cancelledTask_throwsCancellationErrorAndSkipsFallback() async {
        let environment = FakeSpeechEnvironment()
        environment.hasAudioInputDevice = false
        let fallback = FakeFallbackSpeech("unused")
        let service = makeService(environment, fallback: fallback)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.transcribe(onPartial: { _ in })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fallback.calls == 0)
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

    @Test func fallbackForwardsPartialsAndTranscript() async throws {
        let environment = FakeSpeechEnvironment()
        environment.hasAudioInputDevice = false
        let partials = PartialCollector()
        let transcript = try await makeService(environment, fallback: FakeFallbackSpeech("open calculator"))
            .transcribe(onPartial: { partials.append($0) })
        #expect(transcript == "open calculator")
        #expect(partials.values == ["open calculator"])
    }
}

private final class PartialCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
