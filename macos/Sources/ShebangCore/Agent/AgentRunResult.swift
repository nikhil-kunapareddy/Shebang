public enum AgentRunStatus: String, Sendable, Equatable {
    case completed
    case needsHumanInput
    case stalled
    case maxStepsReached
    case cancelled
    case failed
}

public struct AgentRunResult: Sendable, Equatable {
    public var status: AgentRunStatus
    public var stepsCompleted: Int
    public var actionHistory: [String]
    public var message: String?

    public init(status: AgentRunStatus, stepsCompleted: Int = 0, actionHistory: [String] = [], message: String? = nil) {
        self.status = status
        self.stepsCompleted = stepsCompleted
        self.actionHistory = actionHistory
        self.message = message
    }

    public static func completed(steps: Int, history: [String]) -> AgentRunResult {
        AgentRunResult(status: .completed, stepsCompleted: steps, actionHistory: history, message: "Goal successfully achieved.")
    }

    public static func needsHumanInput(steps: Int, history: [String], reason: String?) -> AgentRunResult {
        AgentRunResult(status: .needsHumanInput, stepsCompleted: steps, actionHistory: history,
                       message: reason ?? "Human input required.")
    }

    public static func stalled(steps: Int, history: [String], reason: String?) -> AgentRunResult {
        AgentRunResult(status: .stalled, stepsCompleted: steps, actionHistory: history,
                       message: reason ?? "Loop guard tripped: screen state unchanged.")
    }

    public static func maxStepsReached(steps: Int, history: [String]) -> AgentRunResult {
        AgentRunResult(status: .maxStepsReached, stepsCompleted: steps, actionHistory: history,
                       message: "Reached maximum step limit (\(steps)).")
    }

    public static func failed(steps: Int, history: [String], error: String) -> AgentRunResult {
        AgentRunResult(status: .failed, stepsCompleted: steps, actionHistory: history, message: error)
    }

    public static func cancelled(steps: Int, history: [String]) -> AgentRunResult {
        AgentRunResult(status: .cancelled, stepsCompleted: steps, actionHistory: history, message: "Run was cancelled.")
    }
}
