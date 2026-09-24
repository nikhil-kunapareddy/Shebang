import Foundation

public struct AgentLoopOptions: Sendable, Equatable {
    /// 0 = unlimited: runs until the goal is completed, the run stalls, or it is cancelled.
    public var maxSteps: Int
    public var dryRun: Bool
    public var maxConsecutiveStalls: Int
    /// Not enforced by the loop.
    public var actionTimeoutSeconds: Int
    /// Jev Call B: when set, Click actions the risk policy allows are scored with `DecisionModel.evaluateActionRisk`
    /// and need confirmation at or above this score. `nil` (the default) skips the call.
    public var escalateOnModelRiskScore: ActionRiskScore?

    public init(
        maxSteps: Int = 0,
        dryRun: Bool = true,
        maxConsecutiveStalls: Int = 15,
        actionTimeoutSeconds: Int = 10,
        escalateOnModelRiskScore: ActionRiskScore? = nil
    ) {
        self.maxSteps = maxSteps
        self.dryRun = dryRun
        self.maxConsecutiveStalls = maxConsecutiveStalls
        self.actionTimeoutSeconds = actionTimeoutSeconds
        self.escalateOnModelRiskScore = escalateOnModelRiskScore
    }

    /// Reads `DRY_RUN` (true/false) and `MAX_STEPS_PER_RUN` (integer); unparseable values keep the defaults.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> AgentLoopOptions {
        var options = AgentLoopOptions()
        switch env["DRY_RUN"]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true": options.dryRun = true
        case "false": options.dryRun = false
        default: break
        }
        if let raw = env["MAX_STEPS_PER_RUN"], let maxSteps = Int(raw.trimmingCharacters(in: .whitespaces)) {
            options.maxSteps = maxSteps
        }
        return options
    }
}
