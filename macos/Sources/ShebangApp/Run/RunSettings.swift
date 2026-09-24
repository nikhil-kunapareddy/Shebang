import Foundation
import ShebangCore

/// Loop settings for runs started from the app. `AgentLoopOptions.fromEnvironment` defaults to dry-run (like the CLI);
/// the app acts for real unless `DRY_RUN` is explicitly `true`, matching the Windows app.
struct RunSettings: Equatable, Sendable {
    static let maxConsecutiveStalls = 15

    var loopOptions: AgentLoopOptions

    var isDryRun: Bool { loopOptions.dryRun }

    /// `DRY_RUN` must be exactly `true` (case-insensitive) to simulate; `MAX_STEPS_PER_RUN` caps steps (0 or unset = unlimited).
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> RunSettings {
        var options = AgentLoopOptions.fromEnvironment(env)
        options.dryRun = isExplicitlyTrue(env["DRY_RUN"])
        options.maxSteps = max(0, options.maxSteps)
        options.maxConsecutiveStalls = maxConsecutiveStalls
        return RunSettings(loopOptions: options)
    }

    static func isExplicitlyTrue(_ raw: String?) -> Bool {
        raw?.trimmed.lowercased() == "true"
    }
}
