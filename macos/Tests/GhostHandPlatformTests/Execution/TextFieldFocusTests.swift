import Foundation
import Testing
@testable import GhostHandPlatform

/// Ported from the original macOS app's TextFieldFocusTests.
@Suite struct TextFieldFocusTests {
    private let noSleep: TextFieldFocus.Sleep = { _ in }

    @Test func alreadyFocusedFieldNeedsNoFocusChangeOrClick() async throws {
        try await TextFieldFocus.prepare(sleep: noSleep, check: {}, probe: { true }, requestFocus: {
            Issue.record("Already focused field needs no focus mutation")
        }, click: {
            Issue.record("Already focused field must not be clicked again")
        })
    }

    @Test func accessibilityFocusWorksWithoutClick() async throws {
        var focused = false
        try await TextFieldFocus.prepare(sleep: noSleep, check: {}, probe: { focused }, requestFocus: {
            focused = true
        }, click: { Issue.record("Successful AX focus must not require a click") })
    }

    @Test func clickFallbackStillRequiresConfirmedFocus() async throws {
        var focused = false
        var clicks = 0
        try await TextFieldFocus.prepare(attempts: 2, sleep: noSleep, check: {}, probe: { focused }, requestFocus: {}, click: {
            clicks += 1
            focused = true
        })
        #expect(clicks == 1)
    }

    @Test func clickWithoutFocusCannotProceedToTyping() async {
        do {
            try await TextFieldFocus.prepare(attempts: 1, sleep: noSleep, check: {}, probe: { false }, requestFocus: {}, click: {})
            Issue.record("Click alone cannot authorize typing")
        } catch {
            #expect(error as? TextFieldFocus.Failure == .unavailable)
        }
    }

    @Test func acceptsFieldAndInnerEditorButRejectsSiblingAndContainer() {
        let parents = ["editor": "field", "field": "window", "other": "window"]
        for focused in ["field", "editor"] {
            #expect(TextFieldFocus.contains(focused, target: "field", equal: ==, parent: { parents[$0] }))
        }
        for focused in ["other", "window"] {
            #expect(!TextFieldFocus.contains(focused, target: "field", equal: ==, parent: { parents[$0] }))
        }
    }

    @Test func brokenParentCycleIsBounded() {
        #expect(!TextFieldFocus.contains("other", target: "field", equal: ==, parent: { $0 }))
    }

    @Test func waitAcceptsDelayedFocus() async throws {
        var probes = 0
        var sleeps: [TimeInterval] = []
        try await TextFieldFocus.wait(attempts: 4, interval: 0.05, sleep: { sleeps.append($0) }, check: {}) {
            probes += 1
            return probes == 3
        }
        #expect(probes == 3)
        #expect(sleeps == [0.05, 0.05])
    }

    @Test func unconfirmedFocusStopsBeforeTyping() async {
        var typed = false
        do {
            try await TextFieldFocus.wait(attempts: 2, sleep: noSleep, check: {}) { false }
            typed = true
        } catch {
            #expect(error as? TextFieldFocus.Failure == .unavailable)
        }
        #expect(!typed)
    }

    @Test func appChangeDuringProbeStopsEvenWhenFieldReportsFocus() async {
        var appChanged = false
        do {
            try await TextFieldFocus.wait(sleep: noSleep, check: {
                if appChanged { throw TextFieldFocus.Failure.changed }
            }) {
                appChanged = true
                return true
            }
            Issue.record("App change must abort entry")
        } catch {
            #expect(error as? TextFieldFocus.Failure == .changed)
        }
    }

    @Test func cancellationStopsFocusPolling() async {
        let task = Task {
            try await TextFieldFocus.wait(sleep: { _ in }, check: {}) {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
