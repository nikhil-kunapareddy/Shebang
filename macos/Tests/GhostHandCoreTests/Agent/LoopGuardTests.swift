import Foundation
import Testing
@testable import GhostHandCore

@Suite struct LoopGuardTests {
    private let screen = [
        AccessibilityElement(id: "e1", role: "AXButton", label: "Search"),
        AccessibilityElement(id: "e2", role: "AXTextField", label: "Query", value: "swift"),
    ]

    @Test func identicalObservations_tripAtThreshold() {
        var guardrail = LoopGuard(maxConsecutiveStalls: 3)
        let verdicts = (1...3).map { _ in guardrail.recordObservation(screen) }
        #expect(verdicts == [false, false, true])
        #expect(guardrail.isStalled)
        #expect(guardrail.consecutiveStalls == 3)
    }

    @Test(arguments: [
        AccessibilityElement(id: "e2", role: "AXTextField", label: "Query", value: "swifty"),
        AccessibilityElement(id: "e2", role: "AXTextField", label: "Query", value: "swift", focused: true),
        AccessibilityElement(id: "e2", role: "AXTextField", label: "Query", value: "swift", enabled: false),
        AccessibilityElement(id: "e3", role: "AXTextField", label: "Query", value: "swift"),
        AccessibilityElement(id: "e2", role: "AXComboBox", label: "Query", value: "swift"),
        AccessibilityElement(id: "e2", role: "AXTextField", label: "Search query", value: "swift"),
    ])
    func anyVisibleChange_resetsCount(_ changed: AccessibilityElement) {
        var guardrail = LoopGuard(maxConsecutiveStalls: 2)
        guardrail.recordObservation(screen)
        let stalled = guardrail.recordObservation([screen[0], changed])
        #expect(!stalled)
        #expect(guardrail.consecutiveStalls == 1)
    }

    @Test func frameChangesAloneDoNotCount() {
        var guardrail = LoopGuard(maxConsecutiveStalls: 2)
        guardrail.recordObservation(screen)
        var moved = screen
        moved[0].frame = CGRect(x: 10, y: 10, width: 50, height: 20)
        let stalled = guardrail.recordObservation(moved)
        #expect(stalled)
    }

    @Test func reset_forgetsPreviousState() {
        var guardrail = LoopGuard(maxConsecutiveStalls: 2)
        guardrail.recordObservation(screen)
        guardrail.reset()
        #expect(guardrail.consecutiveStalls == 0)
        #expect(!guardrail.isStalled)
        let stalled = guardrail.recordObservation(screen)
        #expect(!stalled)
        #expect(guardrail.consecutiveStalls == 1)
    }

    @Test func emptyScreensAreComparedToo() {
        var guardrail = LoopGuard(maxConsecutiveStalls: 2)
        guardrail.recordObservation([])
        let stalled = guardrail.recordObservation([])
        #expect(stalled)
        #expect(LoopGuard().maxConsecutiveStalls == 10)
    }
}
