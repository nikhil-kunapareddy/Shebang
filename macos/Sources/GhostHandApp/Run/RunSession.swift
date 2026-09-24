import Foundation
import GhostHandCore

/// What the user sees when a run ends.
struct RunOutcome: Equatable, Sendable {
    var status: AgentRunStatus
    var title: String
    var message: String
    /// How long the result stays on screen before the HUD hides itself.
    var displaySeconds: TimeInterval

    var isSuccess: Bool { status == .completed }

    init(result: AgentRunResult) {
        status = result.status
        let message = result.message?.nonBlank
        switch result.status {
        case .completed:
            title = "Done"
            self.message = message ?? "Goal successfully achieved."
            displaySeconds = 3
        case .cancelled:
            title = "Stopped"
            self.message = "Run was cancelled."
            displaySeconds = 2
        case .needsHumanInput:
            title = "Needs your input"
            self.message = message ?? "Human input required."
            displaySeconds = 8
        case .stalled:
            title = "Stalled"
            self.message = message ?? "The screen stopped changing."
            displaySeconds = 8
        case .maxStepsReached:
            title = "Step limit reached"
            self.message = message ?? "Reached the maximum number of steps."
            displaySeconds = 6
        case .failed:
            title = "Failed"
            self.message = message ?? "The run failed."
            displaySeconds = 8
        }
    }
}

/// The app's run lifecycle: idle → prompting → running → (stopping →) finished → idle.
/// Run ids let late callbacks from a cancelled or detached run be recognised and ignored.
struct RunSession: Equatable {
    enum Phase: Equatable {
        case idle
        case prompting(target: AppTarget?)
        case running(id: Int, target: AppTarget)
        case stopping(id: Int, target: AppTarget)
        case finished(id: Int, outcome: RunOutcome)
    }

    /// What the activation chord should do in the current phase.
    enum HotkeyAction: Equatable {
        case showPrompt, dismissPrompt, stopRun, ignore
    }

    private(set) var phase: Phase = .idle
    private(set) var lastRunID = 0

    var activeRunID: Int? {
        switch phase {
        case .running(let id, _), .stopping(let id, _): return id
        default: return nil
        }
    }

    var isRunActive: Bool { activeRunID != nil }

    var isPrompting: Bool {
        if case .prompting = phase { return true }
        return false
    }

    var promptTarget: AppTarget? {
        if case .prompting(let target) = phase { return target }
        return nil
    }

    var hotkeyAction: HotkeyAction {
        switch phase {
        case .idle, .finished: return .showPrompt
        case .prompting: return .dismissPrompt
        case .running: return .stopRun
        case .stopping: return .ignore
        }
    }

    /// Opens the prompt for `target` (nil = no app captured). Refused while a run is active.
    mutating func beginPrompt(target: AppTarget?) -> Bool {
        guard !isRunActive else { return false }
        phase = .prompting(target: target)
        return true
    }

    mutating func cancelPrompt() -> Bool {
        guard isPrompting else { return false }
        phase = .idle
        return true
    }

    /// Starts a run from the prompt and returns its id.
    mutating func startRun(target: AppTarget) -> Int? {
        guard isPrompting else { return nil }
        lastRunID += 1
        phase = .running(id: lastRunID, target: target)
        return lastRunID
    }

    /// Status lines are shown only while the run is live (not once a stop was requested).
    func acceptsStatus(runID: Int) -> Bool {
        if case .running(let id, _) = phase { return id == runID }
        return false
    }

    mutating func updateTarget(_ target: AppTarget, runID: Int) -> Bool {
        switch phase {
        case .running(let id, _) where id == runID:
            phase = .running(id: id, target: target)
        case .stopping(let id, _) where id == runID:
            phase = .stopping(id: id, target: target)
        default:
            return false
        }
        return true
    }

    /// Kill switch: marks the running run as stopping and returns its id.
    mutating func requestStop() -> Int? {
        guard case .running(let id, let target) = phase else { return nil }
        phase = .stopping(id: id, target: target)
        return id
    }

    /// Records the result of the active run; results from any other run are ignored.
    mutating func finish(runID: Int, outcome: RunOutcome) -> Bool {
        guard activeRunID == runID else { return false }
        phase = .finished(id: runID, outcome: outcome)
        return true
    }

    /// Returns to idle after the result was shown, unless something newer has started.
    mutating func dismissResult(runID: Int) -> Bool {
        guard case .finished(let id, _) = phase, id == runID else { return false }
        phase = .idle
        return true
    }
}
