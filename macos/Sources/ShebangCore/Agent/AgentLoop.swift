import Foundation

/// Observe → decide → check policy → act, until the goal is verified, a guard trips, or the task is cancelled.
public final class AgentLoop {
    /// How long to wait for a loading screen before re-reading it after a stall.
    static let stallRetryDelay: TimeInterval = 1.5

    private let screenReader: ScreenReader
    private let decisionModel: DecisionModel
    private let actionExecutor: ActionExecutor
    private let options: AgentLoopOptions
    private let riskPolicy: RiskPolicy
    private let confirmationPrompt: ConfirmationPrompt?
    private let auditLog: AuditLog?
    private let windowTracker: WindowTracker?
    private let clock: Clock

    // Callbacks run on the loop's task, NOT the main thread. Set them before calling `run`.
    public var onStatus: ((String) -> Void)?
    public var onStepCompleted: ((Int, AgentDecision, ActionResult) -> Void)?
    public var onTargetChanged: ((AppTarget) -> Void)?

    public init(
        screenReader: ScreenReader,
        decisionModel: DecisionModel,
        actionExecutor: ActionExecutor,
        options: AgentLoopOptions,
        riskPolicy: RiskPolicy = DefaultRiskPolicy(),
        confirmationPrompt: ConfirmationPrompt? = nil,
        auditLog: AuditLog? = nil,
        windowTracker: WindowTracker? = nil,
        clock: Clock = SystemClock()
    ) {
        self.screenReader = screenReader
        self.decisionModel = decisionModel
        self.actionExecutor = actionExecutor
        self.options = options
        self.riskPolicy = riskPolicy
        self.confirmationPrompt = confirmationPrompt
        self.auditLog = auditLog
        self.windowTracker = windowTracker
        self.clock = clock
    }

    /// Returns `.cancelled` when the calling task is cancelled; never throws.
    public func run(goal: String, target: AppTarget) async -> AgentRunResult {
        let result = await runSteps(goal: goal, target: target)
        // Cancellation can land during a call that returns normally (a failed action, AskUser).
        guard Task.isCancelled, result.status != .cancelled else { return result }
        notify("Run cancelled by user.")
        return .cancelled(steps: result.stepsCompleted, history: result.actionHistory)
    }

    private func runSteps(goal: String, target: AppTarget) async -> AgentRunResult {
        var currentTarget = target
        var history: [String] = []
        var loopGuard = LoopGuard(maxConsecutiveStalls: options.maxConsecutiveStalls)
        var step = 0
        let maxSteps = options.maxSteps
        let maxStalls = options.maxConsecutiveStalls

        Log.agent.info(
            "Starting AgentLoop on target '\(target.processName, privacy: .public)' (dryRun: \(self.options.dryRun))")

        // Security check 1: the goal itself is prohibited (e.g. deletion tasks).
        if let reason = riskPolicy.goalProhibitionReason(goal) {
            Log.safety.warning("Goal prohibited by policy: \(reason)")
            notify(reason)
            await audit(goal: goal, decision: nil, element: nil, app: currentTarget, type: "prohibited", reason: reason)
            return .failed(steps: 0, history: history, error: reason)
        }

        // Security check 2: the target app is deny-listed (password managers).
        if let refusal = await refuseIfDenied(currentTarget, goal: goal, step: 0, history: history) {
            return refusal
        }

        do {
            while maxSteps <= 0 || step < maxSteps {
                try Task.checkCancellation()
                step += 1
                let stepPrefix = maxSteps > 0 ? "Step \(step)/\(maxSteps)" : "Step \(step)"

                // 0. Follow the foreground window if the user or the app moved focus elsewhere.
                if let tracked = windowTracker?.activeTarget(current: currentTarget),
                   tracked.windowNumber != currentTarget.windowNumber || tracked.processId != currentTarget.processId {
                    Log.agent.info("Active target auto-switched to \(tracked.processName, privacy: .public)")
                    if let refusal = await refuseIfDenied(tracked, goal: goal, step: step, history: history) {
                        return refusal
                    }
                    currentTarget = tracked
                    loopGuard.reset()
                    switchTarget(to: tracked)
                    notify("Target active: \(tracked.processName) (\"\(tracked.windowTitle)\")")
                }

                // 1. Observe.
                notify("\(stepPrefix): Reading screen...")
                var elements = try await screenReader.readElements(target: currentTarget)

                // 2. Stall check: the screen may still be loading, so wait once and re-read before giving up.
                if loopGuard.recordObservation(elements) {
                    let stalls = loopGuard.consecutiveStalls
                    Log.agent.warning("Stall detected: \(stalls) identical consecutive observations.")
                    notify("Waiting for screen to update... (stall \(stalls)/\(maxStalls))")
                    try await clock.sleep(seconds: Self.stallRetryDelay)
                    elements = try await screenReader.readElements(target: currentTarget)
                    if loopGuard.recordObservation(elements) {
                        let retryStalls = loopGuard.consecutiveStalls
                        Log.agent.warning("Screen still unchanged after retry stall \(retryStalls).")
                        notify("Screen state did not change — task may be complete or requires manual intervention.")
                        return .stalled(steps: step, history: history,
                                        reason: "Loop guard tripped: screen state did not change across actions.")
                    }
                }

                // 3. Jev call A: next action.
                notify("\(stepPrefix): Choosing next action...")
                let decision = try await decisionModel.decideNextAction(
                    goal: goal, target: currentTarget, elements: elements, history: history)

                // 4. Done must be verified; an inconclusive verification keeps the loop going.
                if decision.operation == .done {
                    notify("Verifying goal completion...")
                    if try await decisionModel.verifyCompletion(
                        goal: goal, target: currentTarget, elements: elements, history: history) {
                        notify("Goal successfully completed!")
                        return .completed(steps: step, history: history)
                    }
                    Log.agent.info("Done operation verification was inconclusive. Continuing loop.")
                }

                // 5. The model needs guidance.
                if decision.operation == .askUser {
                    notify("Guidance needed: \(decision.reason ?? "")")
                    return .needsHumanInput(steps: step, history: history, reason: decision.reason)
                }

                // 6. Locate the target element.
                let targetElement = decision.targetId.flatMap { id in
                    id.isEmpty ? nil : elements.first { $0.id == id }
                }

                // 7. Strictly prohibited actions (deletions) end the run.
                if let reason = riskPolicy.actionProhibitionReason(for: decision, target: targetElement, goal: goal) {
                    Log.safety.warning("Action prohibited by safety policy: \(reason)")
                    notify(reason)
                    await audit(goal: goal, decision: decision, element: targetElement, app: currentTarget,
                                type: "prohibited", reason: reason)
                    return .failed(steps: step, history: history, error: reason)
                }

                // 8. Confirmation gate. The default policy never asks; custom policies and opt-in model escalation can.
                var confirmationReason = riskPolicy.confirmationReason(
                    for: decision, target: targetElement, app: currentTarget)
                if confirmationReason == nil, decision.operation == .click,
                   let threshold = options.escalateOnModelRiskScore {
                    confirmationReason = try await modelEscalationReason(
                        goal: goal, app: currentTarget, decision: decision, element: targetElement, threshold: threshold)
                }

                if let reason = confirmationReason {
                    notify("Safety confirmation required: \(reason)")
                    let approved = await confirmationPrompt?.requestConfirmation(
                        decision: decision, target: targetElement, app: currentTarget, reason: reason) ?? false
                    try Task.checkCancellation()

                    guard approved else {
                        Log.safety.info("Action '\(decision.operation.rawValue, privacy: .public)' rejected by human.")
                        await audit(goal: goal, decision: decision, element: targetElement, app: currentTarget,
                                    type: "rejected", reason: reason)
                        notify("Action rejected. Execution halted.")
                        return .needsHumanInput(steps: step, history: history, reason: "Action rejected by human: \(reason)")
                    }
                    await audit(goal: goal, decision: decision, element: targetElement, app: currentTarget,
                                type: "confirmed", reason: reason)
                } else {
                    await audit(goal: goal, decision: decision, element: targetElement, app: currentTarget,
                                type: "auto", reason: "Harmless action allowed by safety policy.")
                }

                // 9. Execute (the executor itself honours dry-run).
                let actionLabel = targetElement.map { "'\($0.displayLabel)'" } ?? (decision.targetId ?? "")
                notify("\(stepPrefix): \(decision.operation.rawValue) on \(actionLabel)")

                // A kill switch that fired while deciding or confirming must not let the action through.
                try Task.checkCancellation()
                let result = try await actionExecutor.execute(decision, targetElement: targetElement)
                let outcome = result.success ? "ok" : (result.errorMessage ?? "")
                history.append(
                    "\(decision.operation.rawValue):\(decision.targetId ?? "") (\(decision.targetLabel ?? "")) -> \(outcome)")
                onStepCompleted?(step, decision, result)

                guard result.success else {
                    let error = result.errorMessage ?? "Action execution failed."
                    let failedStep = step
                    Log.agent.warning("Action execution failed at step \(failedStep): \(error)")
                    return .failed(steps: step, history: history, error: error)
                }

                // 10. OpenApp / OpenUrl moved us to a different app or window.
                // Re-opening the app or URL already in front is not progress, so it must not reset the loop guard.
                if let newTarget = result.newTarget,
                   newTarget.processId != currentTarget.processId || newTarget.windowNumber != currentTarget.windowNumber {
                    let oldName = currentTarget.processName
                    Log.agent.info(
                        "Target switched from '\(oldName, privacy: .public)' to '\(newTarget.processName, privacy: .public)'")
                    if let refusal = await refuseIfDenied(newTarget, goal: goal, step: step, history: history) {
                        return refusal
                    }
                    currentTarget = newTarget
                    loopGuard.reset()
                    switchTarget(to: newTarget)
                    notify("Switched target to \(newTarget.processName) (\"\(newTarget.windowTitle)\")")
                }
            }

            notify("Max steps (\(maxSteps)) reached.")
            return .maxStepsReached(steps: step, history: history)
        } catch {
            if error is CancellationError || Task.isCancelled {
                Log.agent.info("AgentLoop was cancelled.")
                notify("Run cancelled by user.")
                return .cancelled(steps: step, history: history)
            }
            let message = error.localizedDescription
            Log.agent.error("AgentLoop terminated unexpectedly: \(message)")
            notify("Error: \(message)")
            return .failed(steps: step, history: history, error: message)
        }
    }

    // MARK: - Helpers

    /// Checks the deny-list for the initial target and for every target switch, so the loop never reads or
    /// drives a password manager the user or an action brought to the front.
    private func refuseIfDenied(_ app: AppTarget, goal: String, step: Int, history: [String]) async -> AgentRunResult? {
        guard let reason = riskPolicy.denialReason(for: app) else { return nil }
        Log.safety.warning("App deny-list triggered: \(reason, privacy: .public)")
        notify("Security policy refusal: \(reason)")
        await audit(goal: goal, decision: nil, element: nil, app: app, type: "denied", reason: reason)
        return .failed(steps: step, history: history, error: reason)
    }

    /// Jev call B, only when enabled through `AgentLoopOptions.escalateOnModelRiskScore`. Model failures fall back
    /// to the deterministic verdict.
    private func modelEscalationReason(
        goal: String,
        app: AppTarget,
        decision: AgentDecision,
        element: AccessibilityElement?,
        threshold: ActionRiskScore
    ) async throws -> String? {
        let score: ActionRiskScore
        do {
            score = try await decisionModel.evaluateActionRisk(
                goal: goal, target: app, decision: decision, targetElement: element)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            Log.agent.debug("Jev risk evaluation failed; proceeding with deterministic verdict: \(error.localizedDescription)")
            return nil
        }
        guard score >= threshold else { return nil }
        switch score {
        case .irreversibleOrExternalEffect: return "Model escalated risk: Irreversible or external effect detected."
        case .reversibleEdit: return "Model escalated risk: Reversible edit detected."
        case .harmless: return "Model escalated risk: Action meets the configured escalation threshold."
        }
    }

    private func switchTarget(to target: AppTarget) {
        actionExecutor.retarget(target)
        onTargetChanged?(target)
    }

    private func audit(
        goal: String,
        decision: AgentDecision?,
        element: AccessibilityElement?,
        app: AppTarget,
        type: String,
        reason: String
    ) async {
        guard let auditLog else { return }
        await auditLog.log(AuditLogEntry(
            timestamp: clock.now,
            goal: goal,
            operation: decision?.operation ?? .askUser,
            targetId: decision?.targetId,
            targetLabel: element?.displayLabel ?? decision?.targetLabel,
            targetRole: element?.displayRole,
            appProcess: app.processName,
            appTitle: app.windowTitle,
            decisionType: type,
            reason: reason
        ))
    }

    private func notify(_ message: String) {
        Log.agent.debug("[AgentLoop] \(message)")
        onStatus?(message)
    }
}
