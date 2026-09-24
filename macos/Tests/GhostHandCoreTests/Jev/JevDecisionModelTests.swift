import Foundation
import Testing
@testable import GhostHandCore

@Suite struct JevDecisionModelTests {
    let target = AppTarget(processId: 1234, processName: "TextEdit", windowTitle: "Untitled")

    func model(_ client: FakeJevClient, _ configure: (inout JevOptions) -> Void = { _ in }) -> JevDecisionModel {
        var options = JevOptions(apiKey: jevTestAPIKey)
        configure(&options)
        return JevDecisionModel(client: client, options: options)
    }

    func nextAction(_ choice: String, _ probabilities: [String: JevJSON] = [:], goalAchieved: Double = 0.1) -> [String: JevJSON] {
        [
            "nextAction": ["type": "choice", "choice": .string(choice), "probabilities": .object(probabilities)],
            "goalAchieved": ["type": "boolean", "probability": .double(goalAchieved)],
        ]
    }

    // MARK: - Call A

    @Test(arguments: ["Button", "AXButton"])
    func jv08ExecutesTopActionEvenWithLowConfidence(role: String) async throws {
        let response = try decodeJevResponse("""
        {
            "answers": {
                "nextAction": {
                    "type": "choice",
                    "choice": "click:btn1",
                    "probabilities": { "click:btn1": 0.45, "press:enter": 0.35, "done": 0.20 }
                },
                "goalAchieved": { "type": "boolean", "probability": 0.10 }
            }
        }
        """)
        let elements = [AccessibilityElement(id: "btn1", role: role, label: "Search")]

        let decision = try await model(FakeJevClient(response))
            .decideNextAction(goal: "Search for test", target: target, elements: elements, history: [])

        #expect(decision.operation == .click)
        #expect(decision.targetId == "btn1")
        #expect(decision.targetLabel == "Search")
        #expect(decision.confidence == 0.45)
    }

    @Test func goalAchievedReturnsDone() async throws {
        let client = FakeJevClient(answers: nextAction("click:e1", goalAchieved: 0.9))
        let decision = try await model(client).decideNextAction(goal: "Play Skyfall", target: target, elements: [], history: [])

        #expect(decision.operation == .done)
        #expect(decision.confidence == 0.9)
        #expect(decision.reason == "Goal achieved (confidence: 90%)")
    }

    @Test func unparseableChoiceAsksUser() async throws {
        let client = FakeJevClient(answers: ["goalAchieved": ["probability": 0.2], "nextAction": ["choice": ""]])
        let decision = try await model(client).decideNextAction(goal: "Do it", target: target, elements: [], history: [])

        #expect(decision.operation == .askUser)
        #expect(decision.reason == "Could not parse decision")
    }

    @Test func choiceThatWasNotOfferedAsksUser() async throws {
        let client = FakeJevClient(answers: nextAction("open_app:Terminal", ["open_app:Terminal": 0.99]))
        let decision = try await model(client).decideNextAction(goal: "Say hi", target: target, elements: [], history: [])

        #expect(decision.operation == .askUser)
        #expect(decision.confidence == 0.99)
    }

    @Test func choiceKeysMatchCaseInsensitively() async throws {
        let client = FakeJevClient(answers: nextAction("PRESS:ENTER", ["PRESS:ENTER": 0.8]))
        let decision = try await model(client).decideNextAction(goal: "Submit", target: target, elements: [], history: [])

        #expect(decision.operation == .pressReturn)
        #expect(decision.confidence == 0.8)
    }

    @Test func decisionThresholdGatesLowConfidenceWhenConfigured() async throws {
        let low = FakeJevClient(answers: nextAction("press:tab", ["press:tab": 0.45]))
        let gated = try await model(low) { $0.decisionConfidenceThreshold = 0.5 }
            .decideNextAction(goal: "Next field", target: target, elements: [], history: [])
        #expect(gated.operation == .askUser)
        #expect(gated.reason == "Confidence 45% is below threshold 50%")

        let high = FakeJevClient(answers: nextAction("press:tab", ["press:tab": 0.6]))
        let allowed = try await model(high) { $0.decisionConfidenceThreshold = 0.5 }
            .decideNextAction(goal: "Next field", target: target, elements: [], history: [])
        #expect(allowed.operation == .pressTab)

        // A goal-achieved answer below the threshold does not end the run.
        let weakDone = FakeJevClient(answers: nextAction("press:tab", ["press:tab": 0.9], goalAchieved: 0.6))
        let continued = try await model(weakDone) { $0.decisionConfidenceThreshold = 0.7 }
            .decideNextAction(goal: "Next field", target: target, elements: [], history: [])
        #expect(continued.operation == .pressTab)
    }

    @Test func callARequestCarriesCompactStateAndBothQuestions() async throws {
        let client = FakeJevClient(answers: nextAction("wait"))
        let goal = "Search for Adele " + String(repeating: "x", count: 5000)
        let longTarget = AppTarget(processId: 1, processName: String(repeating: "p", count: 200),
                                   windowTitle: String(repeating: "w", count: 300))
        var elements = (1...45).map { AccessibilityElement(id: "e\($0)", role: "AXButton", label: "Button \($0)") }
        elements[0] = AccessibilityElement(id: "e1", role: "AXTextField", label: String(repeating: "L", count: 200),
                                           enabled: false, focused: true, source: "ocr")

        _ = try await model(client).decideNextAction(goal: goal, target: longTarget, elements: elements, history: [])

        let request = try #require(client.requests.first)
        #expect(request.model == "typesafe-ai/jev")
        #expect(request.state.objectValue?.keys.sorted()
            == ["actionAttempts", "app", "elementCount", "elements", "step", "task", "window"])
        #expect(request.state["task"]?.stringValue?.count == 4000)
        #expect(request.state["app"]?.stringValue?.count == 100)
        #expect(request.state["window"]?.stringValue?.count == 150)
        #expect(request.state["step"] == 1)
        #expect(request.state["actionAttempts"] == ["nothing yet"])
        #expect(request.state["elementCount"] == 45)
        #expect(request.state["elements"]?.arrayValue?.count == 40)
        #expect(request.state["elements"]?[0] == [
            "id": "e1", "role": "TextField", "label": .string(String(repeating: "L", count: 160)),
            "enabled": false, "focused": true, "source": "ocr",
        ])

        #expect(request.questions.keys.sorted() == ["goalAchieved", "nextAction"])
        #expect(request.questions["nextAction"]?.type == "choice")
        #expect(request.questions["nextAction"]?.instructions == "Select the single best next action to advance toward: \"\(goal)\"")
        #expect(request.questions["goalAchieved"] == .boolean(
            "Has the user's task \"\(goal)\" already been completely fulfilled by the current screen state?"))
        #expect(request.providerOptions == GatewayProviderOptions(gateway: GatewayOptions(zeroDataRetention: nil, only: ["typesafe-ai"])))
    }

    @Test func callAKeepsLastEightAttemptsAndHonoursZeroDataRetention() async throws {
        let client = FakeJevClient(answers: nextAction("wait"))
        let history = (1...10).map { "step \($0)" }

        _ = try await model(client) { $0.zeroDataRetention = true }
            .decideNextAction(goal: "Go", target: target, elements: [], history: history)

        let request = try #require(client.requests.first)
        #expect(request.state["step"] == 11)
        #expect(request.state["actionAttempts"] == .array((3...10).map { .string("step \($0)") }))
        #expect(request.providerOptions?.gateway?.zeroDataRetention == true)
    }

    @Test func clientErrorsPropagateFromCallA() async {
        let client = FakeJevClient([.failure(JevError.transient(statusCode: 503, message: "down"))])
        await #expect(throws: JevError.transient(statusCode: 503, message: "down")) {
            try await model(client).decideNextAction(goal: "Go", target: target, elements: [], history: [])
        }
    }

    // MARK: - Candidate choices

    @Test func candidateChoicesCoverLaunchClickTypeAndStandardActions() {
        let elements = [
            AccessibilityElement(id: "e1", role: "AXButton", label: "Search"),
            AccessibilityElement(id: "e2", role: "AXButton", label: "Disabled", enabled: false),
            AccessibilityElement(id: "e3", role: "AXTextField", label: "Search field"),
            AccessibilityElement(id: "e4", role: "AXStaticText", label: "Results"),
            AccessibilityElement(id: "e5", role: "AXGroup", label: "Clickable card", actions: ["AXPress"]),
            AccessibilityElement(id: "e6", role: "OCRText", label: "Adele", source: "ocr"),
            AccessibilityElement(id: "e7", role: "Edit", label: "UIA-style edit"),
        ]

        let choices = JevDecisionModel.buildCandidateChoices(goal: "open spotify and search for Adele", elements: elements)

        #expect(choices["open_app:spotify"] == "Launch or switch to application \"spotify\"")
        // The shared URL helper reads "open spotify and search for X" as a Spotify search.
        #expect(choices["open_url:https://open.spotify.com/search/Adele"]
            == "Open web URL \"https://open.spotify.com/search/Adele\" in browser")
        #expect(choices["click:e1"] == "Click Button \"Search\"")
        #expect(choices["click:e2"] == nil)
        #expect(choices["click:e4"] == nil)
        #expect(choices["click:e5"] == "Click Group \"Clickable card\"")
        #expect(choices["click:e6"] == nil)
        #expect(choices["type:e3:Adele"] == "Type \"Adele\" into TextField \"Search field\"")
        #expect(choices["type_and_enter:e3:Adele"] == "Type \"Adele\" into TextField \"Search field\" and press Return")
        #expect(choices["type:e7:Adele"] != nil)
        for key in ["press:enter", "press:space", "press:media_play", "press:tab", "press:escape",
                    "scroll:down", "scroll:up", "wait", "done", "ask_user"] {
            #expect(choices[key] != nil, "missing \(key)")
        }
        #expect(!choices.values.contains { $0.contains("Windows") || $0.contains("Start menu") })
    }

    @Test func clickCandidatesAreCappedAtTwentyFive() {
        let elements = (1...30).map { AccessibilityElement(id: "e\($0)", role: "AXButton", label: "B\($0)") }
        let choices = JevDecisionModel.buildCandidateChoices(goal: "click something", elements: elements)

        #expect(choices.keys.filter { $0.hasPrefix("click:") }.count == 25)
        #expect(choices["click:e25"] != nil)
        #expect(choices["click:e26"] == nil)
    }

    @Test func fieldsAlreadyHoldingTheTextAreNotOfferedAgain() {
        let elements = [
            AccessibilityElement(id: "e1", role: "AXTextField", label: "Search", value: "adele songs"),
            AccessibilityElement(id: "e2", role: "AXTextArea", label: "Notes"),
        ]
        let choices = JevDecisionModel.buildCandidateChoices(goal: "search for Adele", elements: elements)

        #expect(choices["type:e1:Adele"] == nil)
        #expect(choices["type_and_enter:e1:Adele"] == nil)
        #expect(choices["type:e2:Adele"] != nil)
    }

    @Test func atMostThreeTextCandidatesPerField() {
        let goal = #"type "one" then "two" then "three" then "four""#
        let elements = [AccessibilityElement(id: "e1", role: "AXTextArea", label: "Body")]
        let choices = JevDecisionModel.buildCandidateChoices(goal: goal, elements: elements)

        #expect(choices.keys.filter { $0.hasPrefix("type:e1:") }.count == 3)
        #expect(choices.keys.filter { $0.hasPrefix("type_and_enter:e1:") }.count == 3)
    }

    // MARK: - Parsing choices

    @Test func parsesLaunchAndTypingChoices() {
        let elements = [AccessibilityElement(id: "e3", role: "AXTextField", label: "Address")]

        let app = JevDecisionModel.parseActionDecision("open_app: Spotify ", confidence: 0.7, elements: elements)
        #expect(app == AgentDecision(operation: .openApp, targetId: "Spotify", targetLabel: "Spotify",
                                     reason: "Launch application 'Spotify'", confidence: 0.7))

        let url = JevDecisionModel.parseActionDecision("open_url:https://example.com/a?b=c", confidence: 0.6, elements: elements)
        #expect(url == AgentDecision(operation: .openUrl, targetId: "https://example.com/a?b=c",
                                     targetLabel: "https://example.com/a?b=c", textValue: "https://example.com/a?b=c",
                                     reason: "Open web URL 'https://example.com/a?b=c'", confidence: 0.6))

        let enter = JevDecisionModel.parseActionDecision("type_and_enter:e3:http://localhost:8080", confidence: 0.5, elements: elements)
        #expect(enter == AgentDecision(operation: .typeAndEnter, targetId: "e3", targetLabel: "Address",
                                       textValue: "http://localhost:8080",
                                       reason: "Type 'http://localhost:8080' into e3 and press Return", confidence: 0.5))

        let type = JevDecisionModel.parseActionDecision("type:e9:hello", confidence: 0.4, elements: elements)
        #expect(type == AgentDecision(operation: .typeText, targetId: "e9", targetLabel: nil, textValue: "hello",
                                      reason: "Type 'hello' into e9", confidence: 0.4))

        let click = JevDecisionModel.parseActionDecision("click:e3", confidence: 0.3, elements: elements)
        #expect(click == AgentDecision(operation: .click, targetId: "e3", targetLabel: "Address",
                                       reason: "Click element e3", confidence: 0.3))
    }

    @Test(arguments: [
        ("press:enter", AgentOperation.pressReturn),
        ("press:space", .pressSpace),
        ("press:media_play", .pressMediaPlay),
        ("press:tab", .pressTab),
        ("Press:Escape", .pressEscape),
        ("scroll:down", .scrollDown),
        ("scroll:up", .scrollUp),
        ("wait", .wait),
        ("done", .done),
        ("ask_user", .askUser),
        ("something:else", .askUser),
    ])
    func parsesStandardChoices(key: String, operation: AgentOperation) {
        let decision = JevDecisionModel.parseActionDecision(key, confidence: 0.25, elements: [])
        #expect(decision == AgentDecision(operation: operation, confidence: 0.25))
    }

    // MARK: - Completion verification

    @Test(arguments: [(0.8, true), (0.5, true), (0.3, false)])
    func verifyCompletionUsesDoneProbability(probability: Double, expected: Bool) async throws {
        let client = FakeJevClient(answers: ["done": ["type": "boolean", "probability": .double(probability)]])
        let done = try await model(client).verifyCompletion(goal: "Play Skyfall", target: target, elements: [], history: [])
        #expect(done == expected)
    }

    @Test func verifyCompletionIsFalseWithoutAnswer() async throws {
        let done = try await model(FakeJevClient(answers: [:]))
            .verifyCompletion(goal: "Play Skyfall", target: target, elements: [], history: [])
        #expect(!done)
    }

    @Test func verifyCompletionRequestShape() async throws {
        let client = FakeJevClient(answers: ["done": ["probability": 0.9]])
        let elements = (1...35).map { AccessibilityElement(id: "e\($0)", role: "AXButton", label: "Save \($0)") }
        let history = (1...9).map { "attempt \($0)" }

        _ = try await model(client).verifyCompletion(goal: "Save the file", target: target, elements: elements, history: history)

        let request = try #require(client.requests.first)
        #expect(request.state.objectValue?.keys.sorted() == ["actionAttempts", "app", "task", "visibleControls", "window"])
        #expect(request.state["actionAttempts"] == .array((4...9).map { .string("attempt \($0)") }))
        #expect(request.state["visibleControls"]?.arrayValue?.count == 30)
        #expect(request.state["visibleControls"]?[0] == #"Button: "Save 1""#)
        #expect(request.questions == ["done": .boolean(
            "Are ALL requirements of the task \"Save the file\" completely satisfied based on visible controls and recorded actions?")])
        #expect(request.providerOptions == GatewayProviderOptions(gateway: GatewayOptions()))

        let empty = FakeJevClient(answers: [:])
        _ = try await model(empty).verifyCompletion(goal: "Save", target: target, elements: [], history: [])
        #expect(empty.requests.first?.state["actionAttempts"] == [])
    }

    // MARK: - Call B risk

    @Test(arguments: [AgentOperation.done, .askUser, .wait])
    func controlFlowActionsAreHarmlessWithoutCallingJev(operation: AgentOperation) async throws {
        let client = FakeJevClient(answers: ["actionRisk": ["score": 3]])
        let risk = try await model(client).evaluateActionRisk(
            goal: "Go", target: target, decision: AgentDecision(operation: operation), targetElement: nil)
        #expect(risk == .harmless)
        #expect(client.requests.isEmpty)
    }

    static let riskCases: [(JevJSON, ActionRiskScore)] = [
        (["score": 3], .irreversibleOrExternalEffect),
        (["score": 2, "probabilities": [0.1, 0.3, 0.6]], .irreversibleOrExternalEffect),
        (["score": 2, "probabilities": [0.3, 0.3, 0.4]], .reversibleEdit),
        (["score": 2], .reversibleEdit),
        (["score": 1, "probabilities": [0.1, 0.85, 0.05]], .reversibleEdit),
        (["score": 0, "probabilities": [0.9, 0.05, 0.05]], .harmless),
        ([:], .harmless),
        ("malformed", .reversibleEdit),
    ]

    @Test(arguments: riskCases)
    func riskScoreMapping(answer: JevJSON, expected: ActionRiskScore) async throws {
        let client = FakeJevClient(answers: ["actionRisk": answer])
        let risk = try await model(client).evaluateActionRisk(
            goal: "Send the email", target: target, decision: AgentDecision(operation: .click, targetId: "e1"), targetElement: nil)
        #expect(risk == expected)
    }

    @Test func missingRiskAnswerIsHarmless() async throws {
        let risk = try await model(FakeJevClient(answers: [:])).evaluateActionRisk(
            goal: "Go", target: target, decision: AgentDecision(operation: .click), targetElement: nil)
        #expect(risk == .harmless)
    }

    @Test func riskCallFailureDefaultsToReversibleEdit() async throws {
        let client = FakeJevClient([.failure(JevError.transient(statusCode: 500, message: "boom"))])
        let risk = try await model(client).evaluateActionRisk(
            goal: "Go", target: target, decision: AgentDecision(operation: .click), targetElement: nil)
        #expect(risk == .reversibleEdit)
    }

    @Test func riskCallCancellationPropagates() async {
        let client = FakeJevClient([.failure(CancellationError())])
        await #expect(throws: CancellationError.self) {
            try await model(client).evaluateActionRisk(
                goal: "Go", target: target, decision: AgentDecision(operation: .click), targetElement: nil)
        }
    }

    @Test func riskRequestDescribesProposedAction() async throws {
        let client = FakeJevClient(answers: ["actionRisk": ["score": 0]])
        let element = AccessibilityElement(id: "e4", role: "AXButton", label: "Send")
        let decision = AgentDecision(operation: .typeText, targetId: "e4", targetLabel: "ignored",
                                     textValue: String(repeating: "t", count: 150))

        _ = try await model(client) { $0.zeroDataRetention = true }
            .evaluateActionRisk(goal: "Email Bob", target: target, decision: decision, targetElement: element)

        let request = try #require(client.requests.first)
        #expect(request.state["proposedAction"] == [
            "operation": "TypeText", "targetId": "e4", "targetRole": "Button", "targetLabel": "Send",
            "textValue": .string(String(repeating: "t", count: 100)),
        ])
        #expect(request.questions["actionRisk"] == .score(
            ["harmless", "reversible edit", "irreversible or external effect"],
            instructions: "Rate the risk of this proposed user-interface action from lowest (harmless UI navigation) to highest (irreversible external effect, submission, payment, deletion, or external data transmission)."))
        #expect(request.providerOptions == GatewayProviderOptions(gateway: GatewayOptions(zeroDataRetention: true)))

        let bare = FakeJevClient(answers: [:])
        _ = try await model(bare).evaluateActionRisk(
            goal: "Go", target: target, decision: AgentDecision(operation: .pressReturn), targetElement: nil)
        #expect(bare.requests.first?.state["proposedAction"] == [
            "operation": "PressReturn", "targetRole": "Unknown", "targetLabel": "None",
        ])
    }
}
