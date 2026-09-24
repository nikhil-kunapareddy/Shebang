import Foundation
import GhostHandCore
@testable import GhostHandApp

enum Samples {
    static let safari = AppTarget(
        processId: 4242, processName: "Safari", bundleIdentifier: "com.apple.Safari",
        windowTitle: "Apply — Example Jobs", windowNumber: 77, windowBounds: CGRect(x: 100, y: 50, width: 1200, height: 800))
    static let notes = AppTarget(
        processId: 5151, processName: "Notes", bundleIdentifier: "com.apple.Notes",
        windowTitle: "Notes", windowNumber: 88, windowBounds: CGRect(x: 0, y: 25, width: 900, height: 700))

    static func outcome(_ status: AgentRunStatus = .completed) -> RunOutcome {
        RunOutcome(result: AgentRunResult(status: status, message: "message"))
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` elapses.
@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}

struct TestError: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

final class FakeCredentialStore: CredentialStore {
    var stored: String?
    var saveError: Error?
    private(set) var readCount = 0

    init(stored: String? = nil) {
        self.stored = stored
    }

    func apiKey() -> String? {
        readCount += 1
        return stored
    }

    var hasKey: Bool { stored != nil }

    func setAPIKey(_ apiKey: String) throws {
        if let saveError { throw saveError }
        stored = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func deleteAPIKey() throws {
        stored = nil
    }
}

/// Scripted `SpeechInput`: emits `partials`, optionally waits for `stopRecording()` (or cancellation), then returns
/// `result`.
final class FakeSpeech: SpeechInput, @unchecked Sendable {
    private let lock = NSLock()
    private let partials: [String]
    private let result: Result<String, Error>
    private let waitsForStop: Bool
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var _stopCalls = 0
    private var _started = 0

    init(partials: [String] = [], result: Result<String, Error> = .success(""), waitsForStop: Bool = false) {
        self.partials = partials
        self.result = result
        self.waitsForStop = waitsForStop
    }

    var stopCalls: Int { lock.withLock { _stopCalls } }
    var startCount: Int { lock.withLock { _started } }

    func transcribe(onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        lock.withLock { _started += 1 }
        for partial in partials { onPartial(partial) }
        if waitsForStop {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow = lock.withLock { () -> Bool in
                        if released { return true }
                        waiter = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                self.release()
            }
            try Task.checkCancellation()
        }
        return try result.get()
    }

    func stopRecording() {
        lock.withLock { _stopCalls += 1 }
        release()
    }

    private func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }
}
