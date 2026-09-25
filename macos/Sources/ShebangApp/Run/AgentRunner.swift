import Foundation
import ShebangCore
import ShebangPlatform

/// Everything one run needs, captured on the main actor when the goal is submitted.
struct RunRequest: Sendable {
    var goal: String
    var target: AppTarget
    var jevOptions: JevOptions
    var loopOptions: AgentLoopOptions
}

/// AgentLoop callbacks. They are invoked on the loop's task, never the main thread.
struct RunHooks: Sendable {
    var onStatus: @Sendable (String) -> Void
    var onTargetChanged: @Sendable (AppTarget) -> Void
}

/// Builds the perception/decision/execution stack for a run and drives the loop.
/// Nonisolated, so the loop and the objects it owns live off the main actor; cancel the calling task to stop the run.
enum AgentRunner {
    static func run(
        _ request: RunRequest,
        windowTracker: WindowTracker & Sendable,
        confirmation: ConfirmationPrompt & Sendable,
        hooks: RunHooks
    ) async -> AgentRunResult {
        let launcher = WorkspaceAppLauncher()
        // Resolving the browser can hit LaunchServices/Spotlight, so it happens here rather than on the main thread.
        launcher.preferredBrowserName = launcher.browserName(in: request.goal)

        let client = JevClient(options: request.jevOptions)
        let loop = AgentLoop(
            screenReader: AXScreenReader(ocr: VisionOCRService()),
            decisionModel: JevDecisionModel(client: client, options: request.jevOptions),
            actionExecutor: MacActionExecutor(
                target: request.target, dryRun: request.loopOptions.dryRun, appLauncher: launcher),
            options: request.loopOptions,
            riskPolicy: DefaultRiskPolicy(),
            confirmationPrompt: confirmation,
            auditLog: JSONLAuditLog(),
            windowTracker: windowTracker)
        loop.onStatus = hooks.onStatus
        loop.onTargetChanged = hooks.onTargetChanged
        return await loop.run(goal: request.goal, target: request.target)
    }
}
