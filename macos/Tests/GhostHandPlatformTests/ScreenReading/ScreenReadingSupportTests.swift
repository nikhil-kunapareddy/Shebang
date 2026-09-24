import Foundation
import GhostHandCore
import Testing
@testable import GhostHandPlatform

@Suite struct ChromiumDetectorTests {
    @Test func knownChromiumBundlesAreDetected() {
        #expect(ChromiumDetector.isChromiumBased(bundleIdentifier: "com.google.Chrome", bundleURL: nil))
        #expect(ChromiumDetector.isChromiumBased(bundleIdentifier: "com.microsoft.VSCode", bundleURL: nil))
        #expect(!ChromiumDetector.isChromiumBased(bundleIdentifier: "com.apple.Safari", bundleURL: nil, fileExists: { _ in false }))
    }

    @Test func electronAndCEFFrameworksAreDetected() {
        let app = URL(fileURLWithPath: "/Applications/Some Chat.app")
        #expect(ChromiumDetector.isChromiumBased(bundleIdentifier: "com.example.chat", bundleURL: app, fileExists: {
            $0 == "/Applications/Some Chat.app/Contents/Frameworks/Electron Framework.framework"
        }))
        #expect(ChromiumDetector.isChromiumBased(bundleIdentifier: "com.example.player", bundleURL: app, fileExists: {
            $0.hasSuffix("Chromium Embedded Framework.framework")
        }))
        #expect(!ChromiumDetector.isChromiumBased(bundleIdentifier: "com.example.native", bundleURL: app, fileExists: { _ in false }))
    }

    @Test func derivesBundleFromExecutablePath() {
        #expect(ChromiumDetector.appBundleURL(fromExecutable: "/Applications/Slack.app/Contents/MacOS/Slack")?.path
                == "/Applications/Slack.app")
        #expect(ChromiumDetector.appBundleURL(fromExecutable: "/usr/bin/true") == nil)
    }
}

@Suite struct AsyncDeadlineTests {
    @Test func returnsTheOperationResult() async throws {
        let value = try await withDeadline(seconds: 5, message: "slow") { 42 }
        #expect(value == 42)
    }

    @Test func doesNotWaitForAnUncooperativeOperation() async {
        let started = Date()
        do {
            _ = try await withDeadline(seconds: 0.05, message: "capture timed out") {
                // Ignores cancellation, like some system frameworks.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { continuation.resume() }
                }
                return 1
            }
            Issue.record("Expected a timeout")
        } catch {
            #expect((error as? DeadlineExceededError)?.message == "capture timed out")
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test func propagatesOperationErrors() async {
        await #expect(throws: FakeError.self) {
            try await withDeadline(seconds: 5, message: "slow") { () -> Int in throw FakeError(message: "boom") }
        }
    }

    @Test func honoursCancellation() async {
        let task = Task {
            try await withDeadline(seconds: 5, message: "slow") { () -> Int in
                try await Task.sleep(nanoseconds: 3_000_000_000)
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
