import ShebangCore
import Testing
@testable import ShebangApp

// `#expect` can't wrap mutating calls, so each transition's result is bound first.
@Suite struct RunSessionTests {
    private func runningSession(target: AppTarget = Samples.safari) -> (RunSession, Int) {
        var session = RunSession()
        _ = session.beginPrompt(target: target)
        let id = session.startRun(target: target)!
        return (session, id)
    }

    @Test func fullLifecycle() {
        var session = RunSession()
        #expect(session.phase == .idle)
        let prompted = session.beginPrompt(target: Samples.safari)
        #expect(prompted)
        #expect(session.phase == .prompting(target: Samples.safari))
        #expect(session.promptTarget == Samples.safari)

        let id = session.startRun(target: Samples.safari)
        #expect(id == 1)
        #expect(session.isRunActive)
        #expect(session.activeRunID == 1)

        let outcome = Samples.outcome()
        let finished = session.finish(runID: 1, outcome: outcome)
        #expect(finished)
        #expect(session.phase == .finished(id: 1, outcome: outcome))
        #expect(!session.isRunActive)

        let dismissed = session.dismissResult(runID: 1)
        #expect(dismissed)
        #expect(session.phase == .idle)
    }

    @Test func hotkeyActionFollowsThePhase() {
        var session = RunSession()
        #expect(session.hotkeyAction == .showPrompt)
        _ = session.beginPrompt(target: nil)
        #expect(session.hotkeyAction == .dismissPrompt)
        let id = session.startRun(target: Samples.safari)!
        #expect(session.hotkeyAction == .stopRun)
        _ = session.requestStop()
        #expect(session.hotkeyAction == .ignore)
        _ = session.finish(runID: id, outcome: Samples.outcome(.cancelled))
        #expect(session.hotkeyAction == .showPrompt)
    }

    @Test func runStartsOnlyFromThePrompt() {
        var session = RunSession()
        let early = session.startRun(target: Samples.safari)
        #expect(early == nil)
        _ = session.beginPrompt(target: nil)
        let started = session.startRun(target: Samples.safari)
        #expect(started != nil)
        let again = session.startRun(target: Samples.safari)
        #expect(again == nil)
    }

    @Test func promptIsRefusedWhileARunIsActive() {
        var (session, _) = runningSession()
        let whileRunning = session.beginPrompt(target: Samples.notes)
        #expect(!whileRunning)
        _ = session.requestStop()
        let whileStopping = session.beginPrompt(target: Samples.notes)
        #expect(!whileStopping)
    }

    @Test func promptCanReplaceAFinishedResult() {
        var (session, id) = runningSession()
        _ = session.finish(runID: id, outcome: Samples.outcome())
        let prompted = session.beginPrompt(target: Samples.notes)
        #expect(prompted)
        // The old result's auto-hide must not reset the new prompt.
        let dismissed = session.dismissResult(runID: id)
        #expect(!dismissed)
        #expect(session.isPrompting)
    }

    @Test func cancelPromptReturnsToIdle() {
        var session = RunSession()
        let cancelledIdle = session.cancelPrompt()
        #expect(!cancelledIdle)
        _ = session.beginPrompt(target: Samples.safari)
        let cancelled = session.cancelPrompt()
        #expect(cancelled)
        #expect(session.phase == .idle)
    }

    @Test func stopOnlyAppliesToARunningRun() {
        var idle = RunSession()
        let idleStop = idle.requestStop()
        #expect(idleStop == nil)

        var (session, id) = runningSession()
        let stopped = session.requestStop()
        #expect(stopped == id)
        #expect(session.phase == .stopping(id: id, target: Samples.safari))
        #expect(session.isRunActive)
        let stoppedAgain = session.requestStop()
        #expect(stoppedAgain == nil)
    }

    @Test func statusIsAcceptedOnlyFromTheLiveRun() {
        var (session, id) = runningSession()
        #expect(session.acceptsStatus(runID: id))
        #expect(!session.acceptsStatus(runID: id + 1))
        _ = session.requestStop()
        #expect(!session.acceptsStatus(runID: id))
    }

    @Test func staleResultsAreIgnored() {
        var (session, first) = runningSession()
        _ = session.requestStop()
        let finishedFirst = session.finish(runID: first, outcome: Samples.outcome(.cancelled))
        #expect(finishedFirst)
        _ = session.beginPrompt(target: Samples.notes)
        let second = session.startRun(target: Samples.notes)!
        #expect(second == first + 1)

        // The detached first run reports late.
        let late = session.finish(runID: first, outcome: Samples.outcome(.failed))
        #expect(!late)
        #expect(session.activeRunID == second)
    }

    @Test func targetUpdatesApplyToTheActiveRunOnly() {
        var (session, id) = runningSession()
        let updated = session.updateTarget(Samples.notes, runID: id)
        #expect(updated)
        #expect(session.phase == .running(id: id, target: Samples.notes))
        let stale = session.updateTarget(Samples.safari, runID: id + 1)
        #expect(!stale)
        _ = session.requestStop()
        let whileStopping = session.updateTarget(Samples.safari, runID: id)
        #expect(whileStopping)
        #expect(session.phase == .stopping(id: id, target: Samples.safari))
    }
}

@Suite struct RunOutcomeTests {
    @Test func completedIsTheOnlySuccess() {
        for status in [AgentRunStatus.completed, .needsHumanInput, .stalled, .maxStepsReached, .cancelled, .failed] {
            #expect(RunOutcome(result: AgentRunResult(status: status)).isSuccess == (status == .completed))
        }
    }

    @Test func usesTheLoopMessage() {
        let outcome = RunOutcome(result: .failed(steps: 2, history: [], error: "Action execution failed."))
        #expect(outcome.title == "Failed")
        #expect(outcome.message == "Action execution failed.")
    }

    @Test func fillsInMissingMessages() {
        #expect(RunOutcome(result: AgentRunResult(status: .completed)).message == "Goal successfully achieved.")
        #expect(RunOutcome(result: AgentRunResult(status: .failed, message: "  ")).message == "The run failed.")
        #expect(RunOutcome(result: AgentRunResult(status: .needsHumanInput)).message == "Human input required.")
    }

    @Test func cancelledReadsAsStopped() {
        let outcome = RunOutcome(result: .cancelled(steps: 3, history: []))
        #expect(outcome.title == "Stopped")
        #expect(outcome.message == "Run was cancelled.")
    }

    @Test func failuresStayLongerThanSuccess() {
        let success = RunOutcome(result: .completed(steps: 1, history: []))
        let failure = RunOutcome(result: .stalled(steps: 1, history: [], reason: nil))
        #expect(success.displaySeconds > 0)
        #expect(failure.displaySeconds > success.displaySeconds)
    }
}
