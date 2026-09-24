import Foundation
import Testing
@testable import ShebangCore

/// Core side of Windows AuditLogTests: the entries the loop hands to `AuditLog`. The JSONL writer and its
/// secret scrubbing are tested with `JSONLAuditLog` in ShebangPlatformTests.
@Suite struct AuditTrailTests {
    let explorer = AppTarget.fake(pid: 321, name: "Finder", bundleId: "com.apple.finder", title: "Documents Folder")

    @Test func executedAction_isAuditedWithAllFields() async throws {
        let element = AccessibilityElement(id: "e12", role: "AXButton", label: "Download PDF")
        let decision = AgentDecision(operation: .click, targetId: "e12", targetLabel: "download")
        let audit = FakeAuditLog()
        let clock = FakeClock()
        let loop = AgentLoop(screenReader: FakeScreenReader(elements: [element]),
                             decisionModel: FakeDecisionModel(script: [decision]), actionExecutor: FakeActionExecutor(),
                             options: AgentLoopOptions(maxSteps: 5), auditLog: audit, clock: clock)

        _ = await loop.run(goal: "Search for quarterly reports", target: explorer)

        let entry = try #require(audit.entries.first)
        #expect(audit.entries.count == 1)
        #expect(entry.goal == "Search for quarterly reports")
        #expect(entry.operation == .click)
        #expect(entry.targetId == "e12")
        #expect(entry.targetLabel == "Download PDF") // the on-screen label wins over the model's label
        #expect(entry.targetRole == "Button")
        #expect(entry.appProcess == "Finder")
        #expect(entry.appTitle == "Documents Folder")
        #expect(entry.decisionType == "auto")
        #expect(entry.reason == "Harmless action allowed by safety policy.")
        #expect(entry.timestamp == clock.now)
    }

    @Test func unresolvedTarget_fallsBackToDecisionLabel() async throws {
        let decision = AgentDecision(operation: .click, targetId: "gone", targetLabel: "Old Button")
        let audit = FakeAuditLog()
        let loop = AgentLoop(screenReader: FakeScreenReader.changing(), decisionModel: FakeDecisionModel(script: [decision]),
                             actionExecutor: FakeActionExecutor(), options: AgentLoopOptions(maxSteps: 5),
                             auditLog: audit, clock: FakeClock())

        _ = await loop.run(goal: "click", target: explorer)

        let entry = try #require(audit.entries.first)
        #expect(entry.targetLabel == "Old Button")
        #expect(entry.targetRole == nil)
    }

    @Test func everyExecutedStep_isAuditedInOrder() async {
        let audit = FakeAuditLog()
        let model = FakeDecisionModel(script: [
            AgentDecision(operation: .scrollDown),
            AgentDecision(operation: .pressTab),
            AgentDecision(operation: .pressReturn),
        ])
        let loop = AgentLoop(screenReader: FakeScreenReader.changing(), decisionModel: model, actionExecutor: FakeActionExecutor(),
                             options: AgentLoopOptions(maxSteps: 10), auditLog: audit, clock: FakeClock())

        _ = await loop.run(goal: "navigate", target: explorer)

        #expect(audit.entries.map(\.operation) == [.scrollDown, .pressTab, .pressReturn])
        #expect(audit.entries.allSatisfy { $0.decisionType == "auto" })
    }
}
