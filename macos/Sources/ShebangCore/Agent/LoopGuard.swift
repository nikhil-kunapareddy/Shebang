/// Detects when consecutive screen observations are identical, i.e. actions are having no visible effect.
public struct LoopGuard: Sendable {
    public let maxConsecutiveStalls: Int
    public private(set) var consecutiveStalls = 0
    private var lastStateSignature: String?

    public var isStalled: Bool { consecutiveStalls >= maxConsecutiveStalls }

    public init(maxConsecutiveStalls: Int = 10) {
        self.maxConsecutiveStalls = maxConsecutiveStalls
    }

    /// Records an observation and returns `isStalled`. The first observation of a new state counts as 1.
    @discardableResult
    public mutating func recordObservation(_ elements: [AccessibilityElement]) -> Bool {
        let signature = Self.signature(of: elements)
        if let lastStateSignature, lastStateSignature == signature {
            consecutiveStalls += 1
        } else {
            consecutiveStalls = 1
        }
        lastStateSignature = signature
        return isStalled
    }

    public mutating func reset() {
        lastStateSignature = nil
        consecutiveStalls = 0
    }

    /// Id, role, label, value, focus, and enabled state of every element; frames are left out so layout jitter alone
    /// does not count as progress.
    private static func signature(of elements: [AccessibilityElement]) -> String {
        var signature = ""
        for element in elements {
            signature += "\(element.id)|\(element.role)|\(element.displayLabel)|\(element.value)|"
            signature += "\(element.focused)|\(element.enabled);"
        }
        return signature
    }
}
