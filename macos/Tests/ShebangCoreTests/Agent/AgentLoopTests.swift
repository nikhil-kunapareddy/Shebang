import Foundation
import Testing
@testable import ShebangCore

@Suite struct AgentLoopTests {
    let target = AppTarget.fake()

    private func click(_ id: String, _ label: String? = nil) -> AgentDecision {
        AgentDecision(operation: .click, targetId: id, targetLabel: label)
    }

    // MARK: - Ported from Windows AgentLoopTests

    @Test func ex05_noChangeAfterAction_loopGuardStopsRun() async {
        let reader = FakeScreenReader(elements: [AccessibilityElement(id: "e1", role: "AXButton", label: "Search Button")])
        let model = FakeDecisionModel { _, _, _ in AgentDecision(operation: .click, targetId: "e1", targetLabel: "Search Button") }
        let executor = FakeActionExecutor(handler: { _, _ in .succeeded(message: "Clicked e1") })
        let clock = FakeClock()
        let loop = AgentLoop(screenReader: reader, decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 10, dryRun: true, maxConsecutiveStalls: 3), clock: clock)

        let result = await loop.run(goal: "test goal", target: target)

        #expect(result.status == .stalled)
        #expect(result.message?.contains("Loop guard tripped") == true)
        // Must trip on the 3rd unchanged state (after one wait-and-re-read).
        #expect(result.stepsCompleted == 3)
        #expect(executor.executed.count == 2)
        #expect(reader.readCount == 4)
        #expect(clock.sleeps == [AgentLoop.stallRetryDelay])
    }

    @Test func ex06_maxStepCap_stopsRun() async {
        let model = FakeDecisionModel { call, _, _ in AgentDecision(operation: .click, targetId: "e_\(call)", targetLabel: "Next") }
        let executor = FakeActionExecutor(handler: { _, _ in .succeeded(message: "Clicked") })
        let loop = AgentLoop(screenReader: FakeScreenReader.changing(), decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 5, dryRun: true, maxConsecutiveStalls: 10), clock: FakeClock())

        let result = await loop.run(goal: "keep going", target: target)

        #expect(result.status == .maxStepsReached)
        #expect(result.stepsCompleted == 5)
        #expect(result.message?.contains("Reached maximum step limit (5)") == true)
        #expect(executor.executed.count == 5)
    }

    @Test func ex04_processMismatch_abortsMidAction() async {
        let reader = FakeScreenReader(elements: [AccessibilityElement(id: "e1", role: "AXButton", label: "Btn")])
        let model = FakeDecisionModel { _, _, _ in AgentDecision(operation: .click, targetId: "e1", targetLabel: "Btn") }
        let executor = FakeActionExecutor(handler: { _, _ in
            .failed("Foreground process changed mid-action (expected PID 1234, found 9999). Execution aborted.")
        })
        let loop = AgentLoop(screenReader: reader, decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 5, dryRun: true), clock: FakeClock())

        let result = await loop.run(goal: "type text", target: target)

        #expect(result.status == .failed)
        #expect(result.message?.contains("Foreground process changed mid-action") == true)
        #expect(result.stepsCompleted == 1)
        #expect(result.actionHistory == [
            "Click:e1 (Btn) -> Foreground process changed mid-action (expected PID 1234, found 9999). Execution aborted.",
        ])
    }

    // MARK: - Loop mechanics

    @Test func unlimitedSteps_runUntilVerifiedDone() async {
        let model = FakeDecisionModel { call, _, _ in
            call <= 30 ? AgentDecision(operation: .scrollDown) : AgentDecision(operation: .done)
        }
        let executor = FakeActionExecutor()
        let loop = AgentLoop(screenReader: FakeScreenReader.changing(), decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 0), clock: FakeClock())

        let result = await loop.run(goal: "scroll a lot", target: target)

        #expect(result.status == .completed)
        #expect(result.stepsCompleted == 31)
        #expect(result.message == "Goal successfully achieved.")
        #expect(executor.executed.count == 30)
    }

    @Test func unverifiedDone_isExecutedAndLoopContinues() async {
        let model = FakeDecisionModel(script: [AgentDecision(operation: .done)])
        model.verify = { call in call >= 2 }
        let executor = FakeActionExecutor()
        let loop = AgentLoop(screenReader: FakeScreenReader.changing(), decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 5), clock: FakeClock())

        let result = await loop.run(goal: "finish", target: target)

        #expect(result.status == .completed)
        #expect(result.stepsCompleted == 2)
        #expect(model.verifyCount == 2)
        // Like Windows, an inconclusive Done falls through to the executor.
        #expect(executor.executed.map(\.decision.operation) == [.done])
    }

    @Test func askUser_returnsNeedsHumanInputWithReason() async {
        let model = FakeDecisionModel(script: [AgentDecision(operation: .askUser, reason: "Which account should I use?")])
        let executor = FakeActionExecutor()
        let loop = AgentLoop(screenReader: FakeScreenReader.changing(), decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 5), clock: FakeClock())
        var statuses: [String] = []
        loop.onStatus = { statuses.append($0) }

        let result = await loop.run(goal: "log in", target: target)

        #expect(result.status == .needsHumanInput)
        #expect(result.message == "Which account should I use?")
        #expect(result.stepsCompleted == 1)
        #expect(executor.executed.isEmpty)
        #expect(statuses.last == "Guidance needed: Which account should I use?")
    }

    @Test func historyAndStepCallbacks_recordEachAction() async {
        let elements = [
            AccessibilityElement(id: "e1", role: "AXTextField", label: "Search"),
            AccessibilityElement(id: "e2", role: "AXButton", label: "Go"),
        ]
        let reader = FakeScreenReader { call, _ in
            elements + [AccessibilityElement(id: "tick", role: "AXStaticText", value: "\(call)")]
        }
        let model = FakeDecisionModel(script: [
            AgentDecision(operation: .typeText, targetId: "e1", targetLabel: "Search", textValue: "swift"),
            click("e2", "Go"),
        ])
        let executor = FakeActionExecutor()
        let loop = AgentLoop(screenReader: reader, decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 5), clock: FakeClock())
        var steps: [(Int, AgentOperation, Bool)] = []
        loop.onStepCompleted = { step, decision, result in steps.append((step, decision.operation, result.success)) }

        let result = await loop.run(goal: "search swift", target: target)

        #expect(result.status == .completed)
        #expect(result.actionHistory == ["TypeText:e1 (Search) -> ok", "Click:e2 (Go) -> ok"])
        #expect(steps.map(\.0) == [1, 2])
        #expect(steps.map(\.1) == [.typeText, .click])
        #expect(steps.allSatisfy { $0.2 })
        // The executor receives the element resolved from the decision's target id.
        #expect(executor.executed.map(\.element?.id) == ["e1", "e2"])
        // Later decisions see the history of earlier steps.
        #expect(model.decideCount == 3)
    }

    @Test func unknownTargetId_passesNilElement() async {
        let model = FakeDecisionModel(script: [click("missing", "Ghost")])
        let executor = FakeActionExecutor()
        let loop = AgentLoop(screenReader: FakeScreenReader.changing(), decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 3), clock: FakeClock())
        var statuses: [String] = []
        loop.onStatus = { statuses.append($0) }

        _ = await loop.run(goal: "click it", target: target)

        #expect(executor.executed.count == 1)
        #expect(executor.executed.first?.element == nil)
        #expect(statuses.contains("Step 1/3: Click on missing"))
    }

    @Test func statusMessages_followWindowsWording() async {
        let reader = FakeScreenReader(elements: [AccessibilityElement(id: "e1", role: "AXButton", label: "OK")])
        let model = FakeDecisionModel(script: [click("e1", "OK")])
        let loop = AgentLoop(screenReader: reader, decisionModel: model, actionExecutor: FakeActionExecutor(),
                             options: AgentLoopOptions(maxSteps: 0), clock: FakeClock())
        var statuses: [String] = []
        loop.onStatus = { statuses.append($0) }

        _ = await loop.run(goal: "press ok", target: target)

        #expect(Array(statuses.prefix(3)) == ["Step 1: Reading screen...", "Step 1: Choosing next action...", "Step 1: Click on 'OK'"])
        #expect(statuses.suffix(2) == ["Verifying goal completion...", "Goal successfully completed!"])
    }

    @Test func stallRecovers_whenScreenChangesAfterWait() async {
        let reader = FakeScreenReader { call, _ in
            call <= 2
                ? [AccessibilityElement(id: "spinner", role: "AXProgressIndicator")]
                : [AccessibilityElement(id: "e\(call)", role: "AXButton", label: "Loaded \(call)")]
        }
        var elementsSeen: [[String]] = []
        let model = FakeDecisionModel { call, elements, _ in
            elementsSeen.append(elements.map(\.id))
            return call <= 2 ? AgentDecision(operation: .wait) : AgentDecision(operation: .done)
        }
        let clock = FakeClock()
        let loop = AgentLoop(screenReader: reader, decisionModel: model, actionExecutor: FakeActionExecutor(),
                             options: AgentLoopOptions(maxSteps: 10, maxConsecutiveStalls: 2), clock: clock)
        var statuses: [String] = []
        loop.onStatus = { statuses.append($0) }

        let result = await loop.run(goal: "wait for load", target: target)

        #expect(result.status == .completed)
        #expect(result.stepsCompleted == 3)
        #expect(statuses.contains("Waiting for screen to update... (stall 2/2)"))
        #expect(clock.sleeps == [AgentLoop.stallRetryDelay])
        // Step 2 decides on the re-read screen, not the stale one.
        #expect(elementsSeen == [["spinner"], ["e3"], ["e4"]])
    }

    @Test func thrownError_returnsFailedWithMessage() async {
        let reader = FakeScreenReader { _, _ in throw TestError(message: "Accessibility tree unavailable") }
        let loop = AgentLoop(screenReader: reader, decisionModel: FakeDecisionModel(script: []),
                             actionExecutor: FakeActionExecutor(), options: AgentLoopOptions(maxSteps: 3), clock: FakeClock())
        var statuses: [String] = []
        loop.onStatus = { statuses.append($0) }

        let result = await loop.run(goal: "anything", target: target)

        #expect(result.status == .failed)
        #expect(result.message == "Accessibility tree unavailable")
        #expect(result.stepsCompleted == 1)
        #expect(statuses.last == "Error: Accessibility tree unavailable")
    }

    @Test func cancellationMidStep_returnsCancelledWithoutExecutingFurther() async {
        // The kill switch fires while the model is deciding step 2; that action must not run.
        let model = FakeDecisionModel { call, _, _ in
            if call == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            return AgentDecision(operation: .click, targetId: "e_\(call)", targetLabel: "Item \(call)")
        }
        let executor = FakeActionExecutor()
        let loop = AgentLoop(screenReader: FakeScreenReader.changing(), decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 0), clock: FakeClock())
        var statuses: [String] = []
        loop.onStatus = { statuses.append($0) }

        let result = await Task { await loop.run(goal: "click forever", target: target) }.value

        #expect(result.status == .cancelled)
        #expect(result.message == "Run was cancelled.")
        #expect(result.stepsCompleted == 2)
        #expect(result.actionHistory.count == 1)
        #expect(executor.executed.count == 1)
        #expect(statuses.last == "Run cancelled by user.")
    }

    @Test func alreadyCancelledTask_neverReadsTheScreen() async {
        let reader = FakeScreenReader.changing()
        let loop = AgentLoop(screenReader: reader, decisionModel: FakeDecisionModel(script: []),
                             actionExecutor: FakeActionExecutor(), options: AgentLoopOptions(maxSteps: 0), clock: FakeClock())

        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await loop.run(goal: "anything", target: target)
        }.value

        #expect(result.status == .cancelled)
        #expect(result.stepsCompleted == 0)
        #expect(reader.readCount == 0)
    }

    @Test func modelCancellationError_mapsToCancelled() async {
        let model = FakeDecisionModel { _, _, _ in throw CancellationError() }
        let loop = AgentLoop(screenReader: FakeScreenReader.changing(), decisionModel: model, actionExecutor: FakeActionExecutor(),
                             options: AgentLoopOptions(maxSteps: 3), clock: FakeClock())

        let result = await loop.run(goal: "anything", target: target)

        #expect(result.status == .cancelled)
    }

    // MARK: - Target switching

    @Test func actionNewTarget_switchesTargetRetargetsExecutorAndResetsGuard() async {
        let safari = AppTarget.fake(pid: 42, name: "Safari", bundleId: "com.apple.Safari", title: "Start Page", window: 77)
        let staticScreen = [AccessibilityElement(id: "e1", role: "AXButton", label: "Same")]
        let reader = FakeScreenReader(elements: staticScreen)
        let model = FakeDecisionModel(script: [
            AgentDecision(operation: .openUrl, targetId: "https://example.com", textValue: "https://example.com"),
            click("e1", "Same"),
        ])
        let executor = FakeActionExecutor(handler: { decision, _ in
            decision.operation == .openUrl ? .targetChanged(safari, message: "Opened") : .succeeded()
        })
        let loop = AgentLoop(screenReader: reader, decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 5, maxConsecutiveStalls: 2), clock: FakeClock())
        var changed: [AppTarget] = []
        var statuses: [String] = []
        loop.onTargetChanged = { changed.append($0) }
        loop.onStatus = { statuses.append($0) }

        let result = await loop.run(goal: "open example.com", target: target)

        #expect(result.status == .stalled)
        #expect(changed == [safari])
        #expect(executor.retargets == [safari])
        #expect(reader.readTargets.first == target)
        #expect(reader.readTargets.dropFirst().allSatisfy { $0 == safari })
        #expect(model.targetsSeen.last == safari)
        #expect(statuses.contains("Switched target to Safari (\"Start Page\")"))
        // The reset guard lets the identical screen in Safari count as a fresh first observation.
        #expect(result.stepsCompleted == 3)
    }

    @Test func windowTracker_autoSwitchesToForegroundWindow() async {
        let notes = AppTarget.fake(pid: 55, name: "Notes", bundleId: "com.apple.Notes", title: "Groceries", window: 99)
        let tracker = FakeWindowTracker { call, current in call >= 2 ? notes : current }
        let model = FakeDecisionModel(script: [AgentDecision(operation: .pressTab), AgentDecision(operation: .pressTab)])
        let executor = FakeActionExecutor()
        let loop = AgentLoop(screenReader: FakeScreenReader.changing(), decisionModel: model, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 5), windowTracker: tracker, clock: FakeClock())
        var changed: [AppTarget] = []
        var statuses: [String] = []
        loop.onTargetChanged = { changed.append($0) }
        loop.onStatus = { statuses.append($0) }

        let result = await loop.run(goal: "tab around", target: target)

        #expect(result.status == .completed)
        #expect(changed == [notes])
        #expect(executor.retargets == [notes])
        #expect(statuses.contains("Target active: Notes (\"Groceries\")"))
        #expect(model.targetsSeen == [target, notes, notes])
    }

    @Test func windowTracker_sameWindowOrNil_doesNotSwitch() async {
        let sameWindowNewTitle = AppTarget.fake(title: "Renamed")
        let tracker = FakeWindowTracker { call, _ in call == 1 ? sameWindowNewTitle : nil }
        let executor = FakeActionExecutor()
        let loop = AgentLoop(screenReader: FakeScreenReader.changing(), decisionModel: FakeDecisionModel(script: [AgentDecision(operation: .wait)]),
                             actionExecutor: executor, options: AgentLoopOptions(maxSteps: 5), windowTracker: tracker,
                             clock: FakeClock())
        var changed: [AppTarget] = []
        loop.onTargetChanged = { changed.append($0) }

        _ = await loop.run(goal: "wait", target: target)

        #expect(changed.isEmpty)
        #expect(executor.retargets.isEmpty)
        #expect(tracker.callCount == 2)
    }

    @Test func switchToDenyListedApp_stopsRunAndAuditsDenial() async {
        let keychain = AppTarget.fake(pid: 77, name: "Keychain Access", bundleId: "com.apple.keychainaccess", window: 5)
        let tracker = FakeWindowTracker { call, current in call >= 2 ? keychain : current }
        let reader = FakeScreenReader.changing()
        let audit = FakeAuditLog()
        let executor = FakeActionExecutor()
        let loop = AgentLoop(screenReader: reader, decisionModel: FakeDecisionModel(script: [AgentDecision(operation: .wait)]),
                             actionExecutor: executor, options: AgentLoopOptions(maxSteps: 5), auditLog: audit,
                             windowTracker: tracker, clock: FakeClock())

        let result = await loop.run(goal: "look around", target: target)

        #expect(result.status == .failed)
        #expect(result.message?.contains("deny-list") == true)
        #expect(reader.readTargets.allSatisfy { $0 == target })
        #expect(executor.retargets.isEmpty)
        #expect(audit.entries.last?.decisionType == "denied")
        #expect(audit.entries.last?.appProcess == "Keychain Access")
    }

    @Test func actionOpeningDenyListedApp_stopsRun() async {
        let bitwarden = AppTarget.fake(pid: 88, name: "Bitwarden", bundleId: "com.bitwarden.desktop", window: 6)
        let executor = FakeActionExecutor(handler: { _, _ in .targetChanged(bitwarden) })
        let reader = FakeScreenReader.changing()
        let loop = AgentLoop(screenReader: reader,
                             decisionModel: FakeDecisionModel(script: [AgentDecision(operation: .openApp, targetId: "Bitwarden")]),
                             actionExecutor: executor, options: AgentLoopOptions(maxSteps: 5), clock: FakeClock())

        let result = await loop.run(goal: "open bitwarden", target: target)

        #expect(result.status == .failed)
        #expect(result.stepsCompleted == 1)
        #expect(reader.readCount == 1)
        #expect(executor.retargets.isEmpty)
    }
}

@Suite struct AgentLoopOptionsTests {
    @Test func defaultsMatchWindows() {
        let options = AgentLoopOptions()
        #expect(options.maxSteps == 0)
        #expect(options.dryRun)
        #expect(options.maxConsecutiveStalls == 15)
        #expect(options.actionTimeoutSeconds == 10)
        #expect(options.escalateOnModelRiskScore == nil)
    }

    @Test func fromEnvironment_parsesDryRunAndMaxSteps() {
        let options = AgentLoopOptions.fromEnvironment(["DRY_RUN": "False", "MAX_STEPS_PER_RUN": " 25 "])
        #expect(!options.dryRun)
        #expect(options.maxSteps == 25)
    }

    @Test func fromEnvironment_ignoresUnparseableValues() {
        let options = AgentLoopOptions.fromEnvironment(["DRY_RUN": "yes", "MAX_STEPS_PER_RUN": "ten"])
        #expect(options == AgentLoopOptions())
        #expect(AgentLoopOptions.fromEnvironment([:]) == AgentLoopOptions())
        #expect(AgentLoopOptions.fromEnvironment(["DRY_RUN": "TRUE"]).dryRun)
    }
}
