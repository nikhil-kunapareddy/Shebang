import Foundation

// Contracts between Core, Platform, and App. Cancellation uses Swift task cancellation
// (`Task.checkCancellation()`).

public protocol ScreenReader: AnyObject {
    func readElements(target: AppTarget) async throws -> [AccessibilityElement]
}

public protocol OCRService: AnyObject {
    /// Recognizes text inside the target window and returns it as `source == "ocr"` elements.
    func recognizeText(in target: AppTarget) async throws -> [AccessibilityElement]
}

public protocol DecisionModel: AnyObject {
    func decideNextAction(
        goal: String,
        target: AppTarget,
        elements: [AccessibilityElement],
        history: [String]
    ) async throws -> AgentDecision

    func verifyCompletion(
        goal: String,
        target: AppTarget,
        elements: [AccessibilityElement],
        history: [String]
    ) async throws -> Bool

    func evaluateActionRisk(
        goal: String,
        target: AppTarget,
        decision: AgentDecision,
        targetElement: AccessibilityElement?
    ) async throws -> ActionRiskScore
}

public protocol ActionExecutor: AnyObject {
    func execute(_ decision: AgentDecision, targetElement: AccessibilityElement?) async throws -> ActionResult
    /// Points subsequent actions at a new app/window (after OpenApp/OpenUrl or a focus switch).
    func retarget(_ target: AppTarget)
}

public protocol HotkeyService: AnyObject {
    /// Called on the main thread when the activation chord fires.
    var onHotkeyPressed: (() -> Void)? { get set }
    /// Called on the main thread when the kill switch fires (chord while running, or Esc).
    var onKillSwitch: (() -> Void)? { get set }
    func start() throws
    func stop()
}

/// Each check returns a human-readable reason when it trips, or `nil` when the action is allowed.
public protocol RiskPolicy {
    func denialReason(for app: AppTarget) -> String?
    func confirmationReason(for decision: AgentDecision, target: AccessibilityElement?, app: AppTarget) -> String?
    func goalProhibitionReason(_ goal: String) -> String?
    func actionProhibitionReason(for decision: AgentDecision, target: AccessibilityElement?, goal: String) -> String?
}

public protocol ConfirmationPrompt: AnyObject {
    /// Must return `false` promptly when the calling task is cancelled, so the kill switch is never blocked by a dialog.
    func requestConfirmation(
        decision: AgentDecision,
        target: AccessibilityElement?,
        app: AppTarget,
        reason: String
    ) async -> Bool
}

public protocol AuditLog: AnyObject {
    /// Never throws; write failures are logged and swallowed so auditing cannot break a run.
    func log(_ entry: AuditLogEntry) async
}

public protocol CredentialStore: AnyObject {
    func apiKey() -> String?
    var hasKey: Bool { get }
    func setAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}

public protocol SpeechInput: AnyObject {
    /// Records until silence, `stopRecording()`, or task cancellation, then returns the final transcript.
    /// `onPartial` receives live hypotheses while recording.
    func transcribe(onPartial: @escaping @Sendable (String) -> Void) async throws -> String
    func stopRecording()
}

public protocol Clock: Sendable {
    var now: Date { get }
    func sleep(seconds: TimeInterval) async throws
}

public protocol AppLauncher: AnyObject {
    func launchApp(named appName: String, launchCommand: String?) async throws -> AppTarget?
    func launchURL(_ url: URL) async throws -> AppTarget?
}

public protocol WindowTracker: AnyObject {
    /// Returns the currently active target if focus moved away from `current`, else `current` or nil.
    func activeTarget(current: AppTarget) -> AppTarget?
}
