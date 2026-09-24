import Foundation
import Testing
@testable import ShebangCore

/// Core side of Windows ConfirmationDialogTests (RS03) plus the confirmation gate that the default Jarvis
/// policy never triggers: custom policies and opt-in model risk escalation (Jev call B) still reach it.
@Suite struct ConfirmationFlowTests {
    let checkout = AppTarget.fake(pid: 4444, name: "Microsoft Edge", bundleId: "com.microsoft.edgemac",
                                  title: "Checkout - Store", window: 0x4444)
    let confirmButton = AccessibilityElement(id: "e42", role: "AXButton", label: "Confirm Order")
    let confirmDecision = AgentDecision(operation: .click, targetId: "e42", targetLabel: "Confirm Order")

    private func policyRequiringConfirmation() -> StubRiskPolicy {
        StubRiskPolicy(confirmation: { decision, _, _ in
            decision.operation == .click ? "Action matches sensitive verb 'Confirm'" : nil
        })
    }

    private func makeLoop(
        prompt: FakeConfirmationPrompt?,
        policy: RiskPolicy,
        model: FakeDecisionModel,
        executor: FakeActionExecutor,
        audit: FakeAuditLog,
        options: AgentLoopOptions = AgentLoopOptions(maxSteps: 5)
    ) -> AgentLoop {
        AgentLoop(screenReader: FakeScreenReader(elements: [confirmButton]), decisionModel: model,
                  actionExecutor: executor, options: options, riskPolicy: policy, confirmationPrompt: prompt,
                  auditLog: audit, clock: FakeClock())
    }

    // RS03: the prompt receives the exact action, target, window, and reason to display.
    @Test func rs03_promptReceivesExactActionTargetAndWindow() async throws {
        let prompt = FakeConfirmationPrompt(approve: true)
        let loop = makeLoop(prompt: prompt, policy: policyRequiringConfirmation(),
                            model: FakeDecisionModel(script: [confirmDecision]), executor: FakeActionExecutor(),
                            audit: FakeAuditLog())

        _ = await loop.run(goal: "Buy the cart", target: checkout)

        let request = try #require(prompt.requests.first)
        #expect(prompt.requests.count == 1)
        #expect(request.decision.operation.rawValue == "Click")
        #expect(request.target?.displayLabel == "Confirm Order")
        #expect(request.app.processName == "Microsoft Edge")
        #expect(request.app.windowTitle == "Checkout - Store")
        #expect(request.reason.contains("sensitive verb 'Confirm'"))
    }

    @Test func approvedAction_executesAndIsAuditedAsConfirmed() async {
        let executor = FakeActionExecutor()
        let audit = FakeAuditLog()
        let loop = makeLoop(prompt: FakeConfirmationPrompt(approve: true), policy: policyRequiringConfirmation(),
                            model: FakeDecisionModel(script: [confirmDecision]), executor: executor, audit: audit)
        var statuses: [String] = []
        loop.onStatus = { statuses.append($0) }

        let result = await loop.run(goal: "Buy the cart", target: checkout)

        #expect(result.status == .completed)
        #expect(executor.executed.count == 1)
        #expect(audit.entries.map(\.decisionType) == ["confirmed"])
        #expect(audit.entries.first?.reason == "Action matches sensitive verb 'Confirm'")
        #expect(statuses.contains("Safety confirmation required: Action matches sensitive verb 'Confirm'"))
    }

    @Test func rejectedAction_haltsWithoutExecuting() async {
        let executor = FakeActionExecutor()
        let audit = FakeAuditLog()
        let loop = makeLoop(prompt: FakeConfirmationPrompt(approve: false), policy: policyRequiringConfirmation(),
                            model: FakeDecisionModel(script: [confirmDecision]), executor: executor, audit: audit)

        let result = await loop.run(goal: "Buy the cart", target: checkout)

        #expect(result.status == .needsHumanInput)
        #expect(result.message == "Action rejected by human: Action matches sensitive verb 'Confirm'")
        #expect(result.stepsCompleted == 1)
        #expect(executor.executed.isEmpty)
        #expect(audit.entries.map(\.decisionType) == ["rejected"])
    }

    @Test func missingPrompt_treatsConfirmationAsRejected() async {
        let executor = FakeActionExecutor()
        let audit = FakeAuditLog()
        let loop = makeLoop(prompt: nil, policy: policyRequiringConfirmation(),
                            model: FakeDecisionModel(script: [confirmDecision]), executor: executor, audit: audit)

        let result = await loop.run(goal: "Buy the cart", target: checkout)

        #expect(result.status == .needsHumanInput)
        #expect(executor.executed.isEmpty)
        #expect(audit.entries.map(\.decisionType) == ["rejected"])
    }

    @Test func modelEscalation_optIn_asksForConfirmationOnRiskyClick() async throws {
        let model = FakeDecisionModel(script: [confirmDecision])
        model.risk = { _ in .irreversibleOrExternalEffect }
        let prompt = FakeConfirmationPrompt(approve: true)
        let audit = FakeAuditLog()
        let loop = makeLoop(prompt: prompt, policy: DefaultRiskPolicy(), model: model, executor: FakeActionExecutor(),
                            audit: audit,
                            options: AgentLoopOptions(maxSteps: 5, escalateOnModelRiskScore: .irreversibleOrExternalEffect))

        let result = await loop.run(goal: "Buy the cart", target: checkout)

        #expect(result.status == .completed)
        #expect(model.riskRequests == [confirmDecision])
        let request = try #require(prompt.requests.first)
        #expect(request.reason == "Model escalated risk: Irreversible or external effect detected.")
        #expect(audit.entries.map(\.decisionType) == ["confirmed"])
    }

    @Test func modelEscalation_belowThresholdOrNonClick_runsAutomatically() async {
        let typing = AgentDecision(operation: .typeText, targetId: "e42", textValue: "hello")
        let model = FakeDecisionModel(script: [confirmDecision, typing])
        model.risk = { _ in .reversibleEdit }
        let prompt = FakeConfirmationPrompt(approve: false)
        let audit = FakeAuditLog()
        let executor = FakeActionExecutor()
        var tick = 0
        let loop = AgentLoop(
            screenReader: FakeScreenReader { _, _ in
                tick += 1
                return [AccessibilityElement(id: "e42", role: "AXButton", label: "Confirm Order", value: "\(tick)")]
            },
            decisionModel: model, actionExecutor: executor,
            options: AgentLoopOptions(maxSteps: 5, escalateOnModelRiskScore: .irreversibleOrExternalEffect),
            confirmationPrompt: prompt, auditLog: audit, clock: FakeClock())

        let result = await loop.run(goal: "Fill the cart", target: checkout)

        #expect(result.status == .completed)
        #expect(model.riskRequests.map(\.operation) == [.click]) // only clicks are scored
        #expect(prompt.requests.isEmpty)
        #expect(executor.executed.count == 2)
        #expect(audit.entries.map(\.decisionType) == ["auto", "auto"])
    }

    @Test func modelEscalation_failure_fallsBackToDeterministicVerdict() async {
        let model = FakeDecisionModel(script: [confirmDecision])
        model.risk = { _ in throw TestError(message: "gateway timeout") }
        let prompt = FakeConfirmationPrompt(approve: false)
        let executor = FakeActionExecutor()
        let loop = makeLoop(prompt: prompt, policy: DefaultRiskPolicy(), model: model, executor: executor,
                            audit: FakeAuditLog(),
                            options: AgentLoopOptions(maxSteps: 5, escalateOnModelRiskScore: .reversibleEdit))

        let result = await loop.run(goal: "Buy the cart", target: checkout)

        #expect(result.status == .completed)
        #expect(prompt.requests.isEmpty)
        #expect(executor.executed.count == 1)
    }
}
