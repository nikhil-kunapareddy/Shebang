import Foundation

/// Jarvis-mode policy ported from Windows: every safe action runs automatically without confirmation,
/// deletion operations are strictly prohibited, and password managers are never automated.
public struct DefaultRiskPolicy: RiskPolicy {
    public let options: RiskPolicyOptions
    private let denyList: Set<String>
    private let prohibitedRegex: NSRegularExpression?

    public init(options: RiskPolicyOptions = .init()) {
        self.options = options
        denyList = Set(options.denyListedApps.map { $0.lowercased() })

        // Longest first so the reported match is deterministic; `\b` keeps "del" from matching "model".
        let terms = options.prohibitedTerms
            .filter { !$0.isEmpty }
            .sorted { ($0.count, $0) > ($1.count, $1) }
            .map(NSRegularExpression.escapedPattern(for:))
        prohibitedRegex = terms.isEmpty
            ? nil
            : NSRegularExpression(literal: #"\b("# + terms.joined(separator: "|") + #")\b"#, options: .caseInsensitive)
    }

    public func denialReason(for app: AppTarget) -> String? {
        let reason: String
        if denyList.contains(app.processName.lowercased()) {
            reason = "Application process '\(app.processName)' is on the security deny-list."
        } else if !app.bundleIdentifier.isEmpty, denyList.contains(app.bundleIdentifier.lowercased()) {
            reason = "Application '\(app.processName)' (\(app.bundleIdentifier)) is on the security deny-list."
        } else {
            return nil
        }
        Log.safety.warning("Security deny-list triggered: \(reason, privacy: .public)")
        return reason
    }

    /// Jarvis mode never asks for human confirmation; deletions are blocked by the prohibition checks instead.
    public func confirmationReason(for decision: AgentDecision, target: AccessibilityElement?, app: AppTarget) -> String? {
        nil
    }

    public func goalProhibitionReason(_ goal: String) -> String? {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let term = prohibitedTerm(in: goal)
        else { return nil }

        let reason = "Prohibited by safety policy: Deletion tasks (matching '\(term)') are strictly prohibited."
        Log.safety.warning("Goal prohibited by policy: \(reason)")
        return reason
    }

    public func actionProhibitionReason(for decision: AgentDecision, target: AccessibilityElement?, goal: String) -> String? {
        var texts = [decision.targetLabel, target?.label, target?.value]
        // Windows only inspects TypeText; TypeAndEnter is included too since it can submit a deletion command.
        if decision.operation == .typeText || decision.operation == .typeAndEnter {
            texts.append(decision.textValue)
        }

        for case let text? in texts where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let term = prohibitedTerm(in: text) else { continue }
            let label = target?.displayLabel ?? decision.targetLabel ?? ""
            let reason = "Prohibited by safety policy: Action '\(decision.operation.rawValue)' on '\(label)' "
                + "matches deletion term '\(term)'."
            Log.safety.warning("Action prohibited by policy: \(reason)")
            return reason
        }
        return nil
    }

    private func prohibitedTerm(in text: String) -> String? {
        prohibitedRegex?.firstMatch(in: text)?.group(0, in: text)
    }
}
