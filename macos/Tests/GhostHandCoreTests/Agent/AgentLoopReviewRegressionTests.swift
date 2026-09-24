import Testing
@testable import GhostHandCore

@Suite struct AgentLoopReviewRegressionTests {
    let target = AppTarget.fake()

    @Test func reopeningTheSameAppDoesNotResetTheLoopGuard() async {
        let reader = FakeScreenReader(elements: [AccessibilityElement(id: "e1", role: "AXButton", label: "Home")])
        let model = FakeDecisionModel { _, _, _ in AgentDecision(operation: .openApp, targetId: "TestApp") }
        let executor = FakeActionExecutor(handler: { [target] _, _ in .targetChanged(target, message: "Already running") })
        let loop = AgentLoop(screenReader: reader, decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 50, dryRun: true, maxConsecutiveStalls: 3), clock: FakeClock())

        let result = await loop.run(goal: "open TestApp", target: target)

        #expect(result.status == .stalled)
        #expect(executor.executed.count == 2)
        #expect(executor.retargets.isEmpty)
    }

    @Test func cancellationDuringAFailedActionReportsCancelled() async {
        let reader = FakeScreenReader.changing()
        let model = FakeDecisionModel { _, _, _ in AgentDecision(operation: .click, targetId: "e1") }
        let executor = FakeActionExecutor()
        let loop = AgentLoop(screenReader: reader, decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 5, dryRun: true), clock: FakeClock())

        let task = Task { () -> AgentRunResult in
            executor.handler = { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .failed("Foreground process changed mid-action")
            }
            return await loop.run(goal: "click it", target: target)
        }

        #expect(await task.value.status == .cancelled)
    }
}
