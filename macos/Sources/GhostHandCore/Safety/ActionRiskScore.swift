public enum ActionRiskScore: Int, Sendable, Codable, Comparable {
    case harmless = 1
    case reversibleEdit = 2
    case irreversibleOrExternalEffect = 3

    public static func < (lhs: ActionRiskScore, rhs: ActionRiskScore) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
