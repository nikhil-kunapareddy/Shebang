import Foundation

/// Raw values are the operation names sent to Jev and written to the audit log, so keep them stable.
public enum AgentOperation: String, Sendable, Codable, CaseIterable {
    case click = "Click"
    case typeText = "TypeText"
    case typeAndEnter = "TypeAndEnter"
    case clickText = "ClickText"
    case scrollUp = "ScrollUp"
    case scrollDown = "ScrollDown"
    case pressReturn = "PressReturn"
    case pressTab = "PressTab"
    case pressEscape = "PressEscape"
    case wait = "Wait"
    case openApp = "OpenApp"
    case openUrl = "OpenUrl"
    case pressSpace = "PressSpace"
    case pressMediaPlay = "PressMediaPlay"
    case done = "Done"
    case blocked = "Blocked"
    case askUser = "AskUser"
}

/// A concrete action chosen by the decision model.
public struct AgentDecision: Sendable, Equatable, Codable {
    public var operation: AgentOperation
    public var targetId: String?
    public var targetLabel: String?
    public var textValue: String?
    public var x: Int?
    public var y: Int?
    public var reason: String?
    public var confidence: Double

    public init(
        operation: AgentOperation,
        targetId: String? = nil,
        targetLabel: String? = nil,
        textValue: String? = nil,
        x: Int? = nil,
        y: Int? = nil,
        reason: String? = nil,
        confidence: Double = 1.0
    ) {
        self.operation = operation
        self.targetId = targetId
        self.targetLabel = targetLabel
        self.textValue = textValue
        self.x = x
        self.y = y
        self.reason = reason
        self.confidence = confidence
    }
}
