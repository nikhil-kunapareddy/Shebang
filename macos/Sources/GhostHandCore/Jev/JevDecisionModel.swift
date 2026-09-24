import Foundation

/// `DecisionModel` backed by Jev.
///
/// - Call A (`decideNextAction`): one `choice` over deterministically built candidate actions plus a
///   `goalAchieved` boolean.
/// - Completion check (`verifyCompletion`): a single `done` boolean.
/// - Call B (`evaluateActionRisk`): a 3-level `score`, escalated to irreversible on strong evidence.
public final class JevDecisionModel: DecisionModel {
    private let client: JevEvaluating
    private let options: JevOptions

    public init(client: JevEvaluating, options: JevOptions) {
        self.client = client
        self.options = options
    }

    public func decideNextAction(
        goal: String,
        target: AppTarget,
        elements: [AccessibilityElement],
        history: [String]
    ) async throws -> AgentDecision {
        // 1. Candidate actions, built deterministically.
        let candidateChoices = Self.buildCandidateChoices(goal: goal, elements: elements)

        // 2. Compact, text-only state. Secrets were already stripped by the screen reader.
        let state: JevJSON = [
            "task": .string(Self.truncate(goal, 4000)),
            "app": .string(Self.truncate(target.processName, 100)),
            "window": .string(Self.truncate(target.windowTitle, 150)),
            "step": .int(history.count + 1),
            "actionAttempts": .array((history.isEmpty ? ["nothing yet"] : Array(history.suffix(8))).map(JevJSON.string)),
            "elementCount": .int(elements.count),
            "elements": .array(elements.prefix(40).map { element -> JevJSON in
                [
                    "id": .string(element.id),
                    "role": .string(element.displayRole),
                    "label": .string(Self.truncate(element.displayLabel, 160)),
                    "enabled": .bool(element.enabled),
                    "focused": .bool(element.focused),
                    "source": .string(element.source),
                ]
            }),
        ]

        // 3. Call A.
        let request = EvaluateRequest(
            model: options.modelId,
            state: state,
            questions: [
                "nextAction": .choice(
                    candidateChoices,
                    instructions: "Select the single best next action to advance toward: \"\(goal)\""),
                "goalAchieved": .boolean(
                    "Has the user's task \"\(goal)\" already been completely fulfilled by the current screen state?"),
            ],
            providerOptions: providerOptions(only: ["typesafe-ai"]))

        let response = try await client.evaluate(request)

        if let achieved = response.booleanAnswer("goalAchieved"), achieved.isTrue,
           achieved.probability >= options.decisionConfidenceThreshold {
            return AgentDecision(
                operation: .done,
                reason: "Goal achieved (confidence: \(Self.percent(achieved.probability)))",
                confidence: achieved.probability)
        }

        guard let answer = response.choiceAnswer("nextAction") else {
            Log.jev.warning("Failed to parse nextAction choice from Jev response. Asking user.")
            return AgentDecision(operation: .askUser, reason: "Could not parse decision")
        }

        // Only offered keys can become actions, so a malformed answer cannot inject text or apps.
        guard let chosenKey = Self.offeredKey(matching: answer.choice, in: candidateChoices) else {
            Log.jev.warning("Jev chose an action that was not offered. Asking user.")
            return AgentDecision(operation: .askUser, reason: "Jev chose an action that was not offered",
                                 confidence: answer.confidence)
        }

        // Disabled by default (threshold 0): the top action runs even at low confidence.
        if answer.confidence < options.decisionConfidenceThreshold {
            Log.jev.info("Top action confidence \(answer.confidence) is below threshold \(self.options.decisionConfidenceThreshold). Asking user.")
            return AgentDecision(
                operation: .askUser,
                reason: "Confidence \(Self.percent(answer.confidence)) is below threshold \(Self.percent(options.decisionConfidenceThreshold))",
                confidence: answer.confidence)
        }

        Log.jev.info("Jev selected action: '\(chosenKey)' (probability: \(Self.percent(answer.confidence), privacy: .public))")
        return Self.parseActionDecision(chosenKey, confidence: answer.confidence, elements: elements)
    }

    public func verifyCompletion(
        goal: String,
        target: AppTarget,
        elements: [AccessibilityElement],
        history: [String]
    ) async throws -> Bool {
        let state: JevJSON = [
            "task": .string(Self.truncate(goal, 4000)),
            "app": .string(Self.truncate(target.processName, 100)),
            "window": .string(Self.truncate(target.windowTitle, 150)),
            "actionAttempts": .array(history.suffix(6).map(JevJSON.string)),
            "visibleControls": .array(elements.prefix(30).map { .string("\($0.displayRole): \"\($0.displayLabel)\"") }),
        ]

        let request = EvaluateRequest(
            model: options.modelId,
            state: state,
            questions: [
                "done": .boolean(
                    "Are ALL requirements of the task \"\(goal)\" completely satisfied based on visible controls and recorded actions?"),
            ],
            providerOptions: providerOptions())

        let response = try await client.evaluate(request)
        guard let done = response.booleanAnswer("done") else { return false }
        return done.isTrue && done.probability >= options.decisionConfidenceThreshold
    }

    public func evaluateActionRisk(
        goal: String,
        target: AppTarget,
        decision: AgentDecision,
        targetElement: AccessibilityElement?
    ) async throws -> ActionRiskScore {
        // Agent control-flow actions are harmless.
        if [AgentOperation.done, .askUser, .wait].contains(decision.operation) {
            return .harmless
        }

        var proposedAction: [String: JevJSON] = [
            "operation": .string(decision.operation.rawValue),
            "targetRole": .string(targetElement?.displayRole ?? "Unknown"),
            "targetLabel": .string(Self.truncate(targetElement?.displayLabel ?? decision.targetLabel ?? "None", 200)),
        ]
        if let targetId = decision.targetId { proposedAction["targetId"] = .string(targetId) }
        if let text = decision.textValue { proposedAction["textValue"] = .string(Self.truncate(text, 100)) }

        let state: JevJSON = [
            "task": .string(Self.truncate(goal, 4000)),
            "app": .string(Self.truncate(target.processName, 100)),
            "window": .string(Self.truncate(target.windowTitle, 150)),
            "proposedAction": .object(proposedAction),
        ]

        let request = EvaluateRequest(
            model: options.modelId,
            state: state,
            questions: [
                "actionRisk": .score(
                    ["harmless", "reversible edit", "irreversible or external effect"],
                    instructions: "Rate the risk of this proposed user-interface action from lowest (harmless UI navigation) to highest (irreversible external effect, submission, payment, deletion, or external data transmission)."),
            ],
            providerOptions: providerOptions())

        let response: EvaluateResponse
        do {
            response = try await client.evaluate(request)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Log.jev.warning("Failed to evaluate action risk via Jev (\(error.localizedDescription, privacy: .public)). Defaulting to ReversibleEdit.")
            return .reversibleEdit
        }

        guard let risk = response.scoreAnswer("actionRisk") else {
            if response.answers["actionRisk"] != nil {
                // The Windows build throws on a malformed answer and falls back to ReversibleEdit.
                Log.jev.warning("Malformed actionRisk answer from Jev. Defaulting to ReversibleEdit.")
                return .reversibleEdit
            }
            return .harmless
        }

        let probabilities = risk.probabilities.map(Self.percent).joined(separator: ", ")
        Log.jev.info("Jev evaluated action risk: Score \(risk.score), probabilities: [\(probabilities, privacy: .public)]")

        if risk.score >= 3 || (risk.score == 2 && risk.probabilities.count == 3 && risk.probabilities[2] >= 0.5) {
            return .irreversibleOrExternalEffect
        }
        if risk.score == 2 || risk.score == 1 {
            return .reversibleEdit
        }
        return .harmless
    }

    // MARK: - Candidate choices

    static func buildCandidateChoices(goal: String, elements: [AccessibilityElement]) -> [String: String] {
        var choices: [String: String] = [:]

        // 0. App launch and URL candidates.
        for app in extractAppLaunchCandidates(goal) {
            choices["open_app:\(app)"] = "Launch or switch to application \"\(app)\""
        }
        for url in UrlLauncherValidator.extractWebURLs(goal) {
            choices["open_url:\(url.absoluteString)"] = "Open web URL \"\(url.absoluteString)\" in browser"
        }

        // Search / literal phrases the user asked to enter.
        let textCandidates = extractCandidatePhrases(goal)

        var clickCount = 0
        for element in elements where element.enabled {
            if isClickable(element) && clickCount < 25 {
                clickCount += 1
                choices["click:\(element.id)"] = "Click \(element.displayRole) \"\(element.displayLabel)\""
            }

            if isTypeable(element.role) {
                for text in textCandidates.prefix(3) {
                    // The field already holds this text; offering it again would loop.
                    if !element.value.isEmpty && element.value.range(of: text, options: .caseInsensitive) != nil {
                        continue
                    }
                    choices["type_and_enter:\(element.id):\(text)"] =
                        "Type \"\(text)\" into \(element.displayRole) \"\(element.displayLabel)\" and press Return"
                    choices["type:\(element.id):\(text)"] =
                        "Type \"\(text)\" into \(element.displayRole) \"\(element.displayLabel)\""
                }
            }
        }

        // Standard actions.
        choices["press:enter"] = "Press Return/Enter key"
        choices["press:space"] = "Press Spacebar to play/pause or select"
        choices["press:media_play"] = "Press Media Play key to toggle playback"
        choices["press:tab"] = "Press Tab key to advance focus"
        choices["press:escape"] = "Press Escape key to dismiss dialog/menu"
        choices["scroll:down"] = "Scroll down to reveal more controls"
        choices["scroll:up"] = "Scroll up"
        choices["wait"] = "Wait 1 second for UI to update"
        choices["done"] = "Task is completely finished"
        choices["ask_user"] = "Need human guidance or clarification"

        return choices
    }

    /// The offered key equal to `choice`, falling back to a case-insensitive match.
    static func offeredKey(matching choice: String, in choices: [String: String]) -> String? {
        if choices[choice] != nil { return choice }
        return choices.keys.first { $0.caseInsensitiveCompare(choice) == .orderedSame }
    }

    static func parseActionDecision(_ key: String, confidence: Double, elements: [AccessibilityElement]) -> AgentDecision {
        func label(for id: String) -> String? {
            elements.first { $0.id == id }?.displayLabel
        }
        func keyHasPrefix(_ prefix: String) -> Bool {
            key.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
        }
        /// `op:elementId:text`, where the text may itself contain colons.
        func idAndText() -> (id: String, text: String) {
            let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return (parts.count > 1 ? parts[1] : "", parts.count > 2 ? parts[2] : "")
        }

        if keyHasPrefix("open_app:") {
            let appName = String(key.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentDecision(operation: .openApp, targetId: appName, targetLabel: appName,
                                 reason: "Launch application '\(appName)'", confidence: confidence)
        }

        if keyHasPrefix("open_url:") {
            let url = String(key.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentDecision(operation: .openUrl, targetId: url, targetLabel: url, textValue: url,
                                 reason: "Open web URL '\(url)'", confidence: confidence)
        }

        if keyHasPrefix("click:") {
            let elementId = String(key.dropFirst(6))
            return AgentDecision(operation: .click, targetId: elementId, targetLabel: label(for: elementId),
                                 reason: "Click element \(elementId)", confidence: confidence)
        }

        if keyHasPrefix("type_and_enter:") {
            let (elementId, text) = idAndText()
            return AgentDecision(operation: .typeAndEnter, targetId: elementId, targetLabel: label(for: elementId),
                                 textValue: text, reason: "Type '\(text)' into \(elementId) and press Return",
                                 confidence: confidence)
        }

        if keyHasPrefix("type:") {
            let (elementId, text) = idAndText()
            return AgentDecision(operation: .typeText, targetId: elementId, targetLabel: label(for: elementId),
                                 textValue: text, reason: "Type '\(text)' into \(elementId)", confidence: confidence)
        }

        let operation: AgentOperation
        switch key.lowercased() {
        case "press:enter": operation = .pressReturn
        case "press:space": operation = .pressSpace
        case "press:media_play": operation = .pressMediaPlay
        case "press:tab": operation = .pressTab
        case "press:escape": operation = .pressEscape
        case "scroll:down": operation = .scrollDown
        case "scroll:up": operation = .scrollUp
        case "wait": operation = .wait
        case "done": operation = .done
        default: operation = .askUser
        }
        return AgentDecision(operation: operation, confidence: confidence)
    }

    // MARK: - Roles

    /// Windows UIA control types plus macOS AX roles, compared without the `AX` prefix.
    private static let clickableRoles: Set<String> = [
        "button", "menuitem", "menubaritem", "tabitem", "hyperlink", "link", "checkbox", "radiobutton",
        "combobox", "popupbutton", "menubutton", "listitem", "row", "cell", "disclosuretriangle", "splitbutton",
    ]
    private static let typeableRoles: Set<String> = [
        "edit", "document", "combobox", "textfield", "textarea", "searchfield",
    ]
    /// AX actions that make any element (e.g. a clickable web `AXGroup`) a click target.
    private static let pressActions: Set<String> = ["AXPress", "AXOpen", "AXPick"]

    private static func normalizedRole(_ role: String) -> String {
        let lowered = role.lowercased()
        return lowered.hasPrefix("ax") ? String(lowered.dropFirst(2)) : lowered
    }

    static func isClickable(_ element: AccessibilityElement) -> Bool {
        clickableRoles.contains(normalizedRole(element.role)) || element.actions.contains(where: pressActions.contains)
    }

    static func isTypeable(_ role: String) -> Bool {
        typeableRoles.contains(normalizedRole(role))
    }

    // MARK: - Goal parsing

    private static let quotedRegex = NSRegularExpression(literal: #"["']([^"']+)["']"#)
    private static let writeRegex = NSRegularExpression(
        literal: #"(?:write|type|enter|insert|put)\s+(?:the\s+text\s+)?(?:["']?)(.+?)(?:["']?)(?:\s+(?:in|into|there|here|on|to)\b|$|\.)"#,
        options: .caseInsensitive)
    private static let writeDestinationRegex = NSRegularExpression(
        literal: #"\s+(?:in|into|to|on)\s+(?:notepad|textedit|notes|document|file|editor|app|browser|search|bar|box).*$"#,
        options: .caseInsensitive)
    private static let searchRegex = NSRegularExpression(
        literal: #"(?:search|look\s+up|find|google|query)(?:\s+(?:for|about|on|regarding|the\s+web\s+for))?\s+(?:["']?)(.+?)(?:["']?)(?:\s+(?:on|in|using|with)\s+[a-zA-Z0-9_\-]+|\.|$|\band\b)"#,
        options: .caseInsensitive)
    private static let searchPrefixRegex = NSRegularExpression(literal: #"^(?:for|about|on)\s+"#, options: .caseInsensitive)
    private static let playRegex = NSRegularExpression(
        literal: #"(?:play|listen\s+to|stream)(?:\s+(?:any\s+song\s+(?:of|by)|songs?\s+(?:of|by)|music\s+(?:of|by)|tracks?\s+(?:of|by)))?\s+(?:["']?)(.+?)(?:["']?)(?:\s+(?:on|in|using|with)\s+[a-zA-Z0-9_\-]+|\.|$|\band\b)"#,
        options: .caseInsensitive)
    private static let playPrefixRegex = NSRegularExpression(
        literal: #"^(?:any\s+song\s+(?:of|by)|songs?\s+(?:of|by)|music\s+(?:of|by)|track\s+(?:of|by))\s+"#,
        options: .caseInsensitive)
    private static let calculateRegex = NSRegularExpression(literal: #"(?:calculate|calc|compute)\s+(.+)$"#, options: .caseInsensitive)
    private static let politePrefixRegex = NSRegularExpression(
        literal: #"^(?:please\s+|can\s+you\s+|i\s+want\s+to\s+)"#, options: .caseInsensitive)
    private static let appLaunchRegex = NSRegularExpression(
        literal: #"(?:open|launch|start|run|switch\s+to|go\s+to|focus)\s+(?:the\s+app\s+)?([a-zA-Z0-9\-_ ]+?)(?:\s+(?:and|to|then|in|with)\b|$|\.)"#,
        options: .caseInsensitive)
    private static let appStopWords: Set<String> = [
        "menu", "tab", "link", "window", "dialog", "document", "file", "page", "browser", "app", "application",
    ]

    /// Text the user wants typed or searched: quoted text, write/type targets, search and play
    /// queries, calculations, or the whole goal when it is a short phrase. Case-insensitively unique,
    /// in discovery order.
    public static func extractCandidatePhrases(_ goal: String) -> [String] {
        var candidates = OrderedCaseInsensitiveSet()

        // 1. Quoted text: "Adele", 'Hello World'.
        for match in quotedRegex.matches(in: goal) {
            candidates.insert(match.group(1, in: goal)?.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 2. "write/type/enter/insert/put <text> in/into/there/..."
        if let match = writeRegex.firstMatch(in: goal), var value = match.group(1, in: goal) {
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            value = writeDestinationRegex.replacingMatches(in: value, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.caseInsensitiveCompare("there") != .orderedSame { candidates.insert(value) }
        }

        // 3. "search/look up/find/google/query [for/about/on] <text>"
        for match in searchRegex.matches(in: goal) {
            guard let raw = match.group(1, in: goal) else { continue }
            let value = searchPrefixRegex.replacingMatches(in: raw.trimmingCharacters(in: .whitespacesAndNewlines), with: "")
            candidates.insert(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 4. "play/listen to/stream [any song of/by, music by, ...] <text>"
        for match in playRegex.matches(in: goal) {
            guard let raw = match.group(1, in: goal) else { continue }
            let value = playPrefixRegex.replacingMatches(in: raw.trimmingCharacters(in: .whitespacesAndNewlines), with: "")
            candidates.insert(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 5. "calculate/compute <expression>"
        if let match = calculateRegex.firstMatch(in: goal) {
            candidates.insert(match.group(1, in: goal)?.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 6. Fallback: a short direct phrase.
        let lowered = goal.lowercased()
        if candidates.isEmpty && !lowered.hasPrefix("click") && !lowered.hasPrefix("scroll") {
            let cleaned = politePrefixRegex.replacingMatches(in: goal, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty && cleaned.count <= 40 { candidates.insert(cleaned) }
        }

        return candidates.values
    }

    /// App named by "open/launch/start/run/switch to/go to/focus <app>", unless it is a generic noun.
    public static func extractAppLaunchCandidates(_ goal: String) -> [String] {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let match = appLaunchRegex.firstMatch(in: goal),
              let app = match.group(1, in: goal)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !app.isEmpty, !appStopWords.contains(app.lowercased())
        else { return [] }
        return [app]
    }

    // MARK: - Helpers

    private func providerOptions(only: [String]? = nil) -> GatewayProviderOptions {
        GatewayProviderOptions(gateway: GatewayOptions(zeroDataRetention: options.zeroDataRetention ? true : nil, only: only))
    }

    static func truncate(_ text: String, _ maxChars: Int) -> String {
        text.count <= maxChars ? text : String(text.prefix(maxChars))
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

/// Insertion-ordered strings, unique under case-insensitive comparison (first spelling wins).
private struct OrderedCaseInsensitiveSet {
    private(set) var values: [String] = []
    private var seen: Set<String> = []

    var isEmpty: Bool { values.isEmpty }

    mutating func insert(_ value: String?) {
        guard let value, !value.isEmpty, seen.insert(value.lowercased()).inserted else { return }
        values.append(value)
    }
}
