import GhostHandCore
import Testing
@testable import GhostHandApp

@MainActor
private final class BridgeRecorder {
    var presented: [ConfirmationRequest] = []
    var dismissals = 0

    init(_ bridge: ConfirmationBridge) {
        bridge.onPresent = { [unowned self] in presented.append($0) }
        bridge.onDismiss = { [unowned self] in dismissals += 1 }
    }
}

private func sampleRequest(_ reason: String = "Action matches sensitive verb 'Submit'") -> ConfirmationRequest {
    ConfirmationRequest(
        details: ConfirmationDetails(action: "Click", target: "Submit (Button)", app: "Safari", reason: reason),
        app: Samples.safari)
}

@Suite @MainActor struct ConfirmationBridgeTests {
    @Test func approveResumesTrueAndDismisses() async {
        let bridge = ConfirmationBridge()
        let recorder = BridgeRecorder(bridge)
        let task = Task { await bridge.request(sampleRequest()) }
        #expect(await waitUntil { bridge.isPending })
        #expect(recorder.presented == [sampleRequest()])

        bridge.resolve(approved: true)
        #expect(await task.value == true)
        #expect(recorder.dismissals == 1)
        #expect(!bridge.isPending)
    }

    @Test func rejectResumesFalse() async {
        let bridge = ConfirmationBridge()
        let task = Task { await bridge.request(sampleRequest()) }
        #expect(await waitUntil { bridge.isPending })
        bridge.resolve(approved: false)
        #expect(await task.value == false)
    }

    @Test func killSwitchRejectsThePendingRequest() async {
        let bridge = ConfirmationBridge()
        let recorder = BridgeRecorder(bridge)
        let task = Task { await bridge.request(sampleRequest()) }
        #expect(await waitUntil { bridge.isPending })
        bridge.cancelPending()
        #expect(await task.value == false)
        #expect(recorder.dismissals == 1)
    }

    @Test func cancellingTheRequestingTaskRejects() async {
        let bridge = ConfirmationBridge()
        let recorder = BridgeRecorder(bridge)
        let task = Task { await bridge.request(sampleRequest()) }
        #expect(await waitUntil { bridge.isPending })
        task.cancel()
        #expect(await task.value == false)
        #expect(await waitUntil { !bridge.isPending })
        #expect(recorder.dismissals == 1)
    }

    @Test func alreadyCancelledTaskIsRejectedWithoutPresenting() async {
        let bridge = ConfirmationBridge()
        let recorder = BridgeRecorder(bridge)
        let task = Task { await bridge.request(sampleRequest()) }
        task.cancel() // Before the task body can run: the test holds the main actor.
        #expect(await task.value == false)
        #expect(recorder.presented.isEmpty)
        #expect(!bridge.isPending)
    }

    @Test func extraResolutionsAreIgnored() async {
        let bridge = ConfirmationBridge()
        let recorder = BridgeRecorder(bridge)
        bridge.resolve(approved: true) // nothing pending
        bridge.cancelPending()
        #expect(recorder.dismissals == 0)

        let task = Task { await bridge.request(sampleRequest()) }
        #expect(await waitUntil { bridge.isPending })
        bridge.resolve(approved: true)
        bridge.resolve(approved: false)
        bridge.cancelPending()
        task.cancel()
        #expect(await task.value == true)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorder.dismissals == 1)
    }

    @Test func newerRequestSupersedesAnUnansweredOne() async {
        let bridge = ConfirmationBridge()
        let first = Task { await bridge.request(sampleRequest("first")) }
        #expect(await waitUntil { bridge.currentRequest?.details.reason == "first" })
        let second = Task { await bridge.request(sampleRequest("second")) }
        #expect(await first.value == false)
        #expect(await waitUntil { bridge.currentRequest?.details.reason == "second" })
        bridge.resolve(approved: true)
        #expect(await second.value == true)
    }

    @Test func adapterBridgesTheLoopsCallFromAnotherTask() async {
        let bridge = ConfirmationBridge()
        let adapter = ConfirmationPromptAdapter(bridge: bridge)
        let decision = AgentDecision(operation: .click, targetId: "e3", targetLabel: "Submit")
        let element = AccessibilityElement(id: "e3", role: "AXButton", label: "Submit application")
        let task = Task.detached {
            await adapter.requestConfirmation(decision: decision, target: element, app: Samples.safari, reason: "Submit")
        }
        #expect(await waitUntil { bridge.isPending })
        #expect(bridge.currentRequest?.details.target == "Submit application (Button)")
        #expect(bridge.currentRequest?.app == Samples.safari)
        bridge.resolve(approved: true)
        #expect(await task.value == true)
    }

    @Test func cancellingTheRunWhileConfirmingRejects() async {
        let bridge = ConfirmationBridge()
        let adapter = ConfirmationPromptAdapter(bridge: bridge)
        let task = Task.detached {
            await adapter.requestConfirmation(
                decision: AgentDecision(operation: .click), target: nil, app: Samples.safari, reason: "Submit")
        }
        #expect(await waitUntil { bridge.isPending })
        task.cancel()
        #expect(await task.value == false)
        #expect(await waitUntil { !bridge.isPending })
    }
}

@Suite struct ConfirmationDetailsTests {
    @Test func describesTheElementAndApp() {
        let details = ConfirmationDetails(
            decision: AgentDecision(operation: .click, targetId: "e3", targetLabel: "Submit"),
            target: AccessibilityElement(id: "e3", role: "AXButton", label: "Submit application"),
            app: Samples.safari,
            reason: "Action matches sensitive verb 'Submit'")
        #expect(details.action == "Click")
        #expect(details.target == "Submit application (Button)")
        #expect(details.app == "Safari — “Apply — Example Jobs”")
        #expect(details.reason == "Action matches sensitive verb 'Submit'")
        #expect(details.text == nil)
    }

    @Test func fallsBackToTheDecisionLabelThenId() {
        let blankElement = AccessibilityElement(id: "e1", role: "AXLink", label: "  ")
        let labelled = ConfirmationDetails(
            decision: AgentDecision(operation: .click, targetId: "e1", targetLabel: "Pay now"),
            target: blankElement, app: Samples.safari, reason: "r")
        #expect(labelled.target == "Pay now (Link)")

        let idOnly = ConfirmationDetails(
            decision: AgentDecision(operation: .click, targetId: "e9"), target: nil, app: Samples.safari, reason: "r")
        #expect(idOnly.target == "e9 (Control)")

        let nothing = ConfirmationDetails(
            decision: AgentDecision(operation: .pressReturn), target: nil, app: Samples.notes, reason: "r")
        #expect(nothing.target == "(no control) (Control)")
        #expect(nothing.app == "Notes")
    }

    @Test func showsTextForTypingOperations() {
        let details = ConfirmationDetails(
            decision: AgentDecision(operation: .typeAndEnter, targetId: "e2", textValue: "hello world"),
            target: nil, app: Samples.safari, reason: "r")
        #expect(details.text == "hello world")

        let click = ConfirmationDetails(
            decision: AgentDecision(operation: .click, targetId: "e2", textValue: "ignored"),
            target: nil, app: Samples.safari, reason: "r")
        #expect(click.text == nil)
    }

    @Test func truncatesLongText() {
        let long = String(repeating: "a", count: 500)
        let details = ConfirmationDetails(
            decision: AgentDecision(operation: .typeText, textValue: long), target: nil, app: Samples.safari, reason: "r")
        #expect(details.text?.count == ConfirmationDetails.maxTextLength + 1)
        #expect(details.text?.hasSuffix("…") == true)
    }
}

@Suite @MainActor struct ConfirmationViewModelTests {
    private let details = ConfirmationDetails(action: "Click", target: "Submit (Button)", app: "Safari", reason: "r")

    @Test func approvalWaitsUntilArmed() async {
        let model = ConfirmationViewModel()
        model.armDelay = 0.05
        var decisions: [Bool] = []
        model.onDecision = { decisions.append($0) }
        model.present(details)
        #expect(!model.isArmed)
        model.approve()
        #expect(decisions.isEmpty)

        #expect(await waitUntil { model.isArmed })
        model.approve()
        #expect(decisions == [true])
        #expect(model.details == nil)
    }

    @Test func rejectWorksImmediately() {
        let model = ConfirmationViewModel()
        model.armDelay = 10
        var decisions: [Bool] = []
        model.onDecision = { decisions.append($0) }
        model.present(details)
        model.reject()
        #expect(decisions == [false])
    }

    @Test func decidesOncePerRequest() {
        let model = ConfirmationViewModel()
        model.armDelay = 0
        var decisions: [Bool] = []
        model.onDecision = { decisions.append($0) }
        model.present(details)
        #expect(model.isArmed)
        model.approve()
        model.approve()
        model.reject()
        #expect(decisions == [true])
    }

    @Test func dismissClearsState() {
        let model = ConfirmationViewModel()
        model.armDelay = 0
        model.present(details)
        model.dismiss()
        #expect(model.details == nil)
        #expect(!model.isArmed)
    }
}
