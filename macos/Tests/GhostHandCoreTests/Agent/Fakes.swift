import Foundation
@testable import GhostHandCore

// In-memory fakes of the Core protocols, shared by the agent-loop and safety suites.
// The loop calls them sequentially, so they only guard state that tests read from another task.

final class FakeScreenReader: ScreenReader {
    /// Receives the 1-based call number and the target being read.
    var handler: (Int, AppTarget) async throws -> [AccessibilityElement]
    private(set) var readTargets: [AppTarget] = []
    var readCount: Int { readTargets.count }

    init(elements: [AccessibilityElement] = []) {
        handler = { _, _ in elements }
    }

    init(handler: @escaping (Int, AppTarget) async throws -> [AccessibilityElement]) {
        self.handler = handler
    }

    /// Returns a different single-element screen on every read so the loop guard never trips.
    static func changing() -> FakeScreenReader {
        FakeScreenReader { call, _ in [AccessibilityElement(id: "e_\(call)", role: "AXButton", label: "Item \(call)")] }
    }

    func readElements(target: AppTarget) async throws -> [AccessibilityElement] {
        readTargets.append(target)
        return try await handler(readTargets.count, target)
    }
}

final class FakeDecisionModel: DecisionModel {
    /// Receives the 1-based call number, the elements, and the history so far.
    var decide: (Int, [AccessibilityElement], [String]) throws -> AgentDecision
    var verify: (Int) throws -> Bool = { _ in true }
    var risk: (AgentDecision) throws -> ActionRiskScore = { _ in .harmless }

    private(set) var decideCount = 0
    private(set) var verifyCount = 0
    private(set) var riskRequests: [AgentDecision] = []
    private(set) var targetsSeen: [AppTarget] = []

    init(decide: @escaping (Int, [AccessibilityElement], [String]) throws -> AgentDecision) {
        self.decide = decide
    }

    /// Returns `script` in order, then `fallback` forever.
    convenience init(script: [AgentDecision], fallback: AgentDecision = AgentDecision(operation: .done)) {
        self.init { call, _, _ in call <= script.count ? script[call - 1] : fallback }
    }

    func decideNextAction(
        goal: String, target: AppTarget, elements: [AccessibilityElement], history: [String]
    ) async throws -> AgentDecision {
        decideCount += 1
        targetsSeen.append(target)
        return try decide(decideCount, elements, history)
    }

    func verifyCompletion(
        goal: String, target: AppTarget, elements: [AccessibilityElement], history: [String]
    ) async throws -> Bool {
        verifyCount += 1
        return try verify(verifyCount)
    }

    func evaluateActionRisk(
        goal: String, target: AppTarget, decision: AgentDecision, targetElement: AccessibilityElement?
    ) async throws -> ActionRiskScore {
        riskRequests.append(decision)
        return try risk(decision)
    }
}

final class FakeActionExecutor: ActionExecutor {
    var handler: (AgentDecision, AccessibilityElement?) throws -> ActionResult = { _, _ in .succeeded(message: "Executed") }
    private(set) var executed: [(decision: AgentDecision, element: AccessibilityElement?)] = []
    private(set) var retargets: [AppTarget] = []

    init() {}

    init(handler: @escaping (AgentDecision, AccessibilityElement?) throws -> ActionResult) {
        self.handler = handler
    }

    func execute(_ decision: AgentDecision, targetElement: AccessibilityElement?) async throws -> ActionResult {
        executed.append((decision, targetElement))
        return try handler(decision, targetElement)
    }

    func retarget(_ target: AppTarget) {
        retargets.append(target)
    }
}

final class FakeAuditLog: AuditLog {
    private let lock = NSLock()
    private var storage: [AuditLogEntry] = []

    var entries: [AuditLogEntry] { lock.withLock { storage } }

    func log(_ entry: AuditLogEntry) async {
        lock.withLock { storage.append(entry) }
    }
}

final class FakeConfirmationPrompt: ConfirmationPrompt {
    struct Request {
        var decision: AgentDecision
        var target: AccessibilityElement?
        var app: AppTarget
        var reason: String
    }

    var approve: Bool
    private(set) var requests: [Request] = []

    init(approve: Bool = true) {
        self.approve = approve
    }

    func requestConfirmation(decision: AgentDecision, target: AccessibilityElement?, app: AppTarget, reason: String) async -> Bool {
        requests.append(Request(decision: decision, target: target, app: app, reason: reason))
        return approve
    }
}

/// Sleeps return immediately and advance `now`.
final class FakeClock: GhostHandCore.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var recordedSleeps: [TimeInterval] = []

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }
    var sleeps: [TimeInterval] { lock.withLock { recordedSleeps } }

    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock {
            recordedSleeps.append(seconds)
            current += seconds
        }
    }
}

final class FakeWindowTracker: WindowTracker {
    /// Receives the 1-based call number and the loop's current target.
    var handler: (Int, AppTarget) -> AppTarget?
    private(set) var callCount = 0

    init(handler: @escaping (Int, AppTarget) -> AppTarget? = { _, current in current }) {
        self.handler = handler
    }

    func activeTarget(current: AppTarget) -> AppTarget? {
        callCount += 1
        return handler(callCount, current)
    }
}

/// Default Jarvis policy with an overridable confirmation verdict, to exercise the confirmation gate.
struct StubRiskPolicy: RiskPolicy {
    var base = DefaultRiskPolicy()
    var confirmation: (AgentDecision, AccessibilityElement?, AppTarget) -> String? = { _, _, _ in nil }

    func denialReason(for app: AppTarget) -> String? { base.denialReason(for: app) }

    func confirmationReason(for decision: AgentDecision, target: AccessibilityElement?, app: AppTarget) -> String? {
        confirmation(decision, target, app)
    }

    func goalProhibitionReason(_ goal: String) -> String? { base.goalProhibitionReason(goal) }

    func actionProhibitionReason(for decision: AgentDecision, target: AccessibilityElement?, goal: String) -> String? {
        base.actionProhibitionReason(for: decision, target: target, goal: goal)
    }
}

struct TestError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

extension AppTarget {
    static func fake(
        pid: Int32 = 1234,
        name: String = "TestApp",
        bundleId: String = "",
        title: String = "Test App Window",
        window: Int = 0x1234
    ) -> AppTarget {
        AppTarget(processId: pid, processName: name, bundleIdentifier: bundleId, windowTitle: title,
                  windowNumber: window, windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600))
    }
}
