import Foundation

/// One JSONL line in the local audit log. Keys match the Windows build.
public struct AuditLogEntry: Sendable, Equatable, Codable {
    public var timestamp: Date
    public var goal: String
    public var operation: AgentOperation
    public var targetId: String?
    public var targetLabel: String?
    public var targetRole: String?
    public var appProcess: String
    public var appTitle: String
    /// `"auto"`, `"confirmed"`, `"rejected"`, or `"denied"`.
    public var decisionType: String
    public var reason: String?

    public init(
        timestamp: Date = Date(),
        goal: String = "",
        operation: AgentOperation,
        targetId: String? = nil,
        targetLabel: String? = nil,
        targetRole: String? = nil,
        appProcess: String = "",
        appTitle: String = "",
        decisionType: String = "auto",
        reason: String? = nil
    ) {
        self.timestamp = timestamp
        self.goal = goal
        self.operation = operation
        self.targetId = targetId
        self.targetLabel = targetLabel
        self.targetRole = targetRole
        self.appProcess = appProcess
        self.appTitle = appTitle
        self.decisionType = decisionType
        self.reason = reason
    }
}
