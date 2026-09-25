import Testing
@testable import ShebangCore

@Suite struct MacDeletionTermsTests {
    let policy = DefaultRiskPolicy()

    @Test(arguments: [
        #"open terminal and type "rm -rf ~/Documents""#,
        "run diskutil eraseDisk APFS Blank disk2",
        "empty trash to free up disk space",
        "select the files and Move to Trash",
        "shred the old invoices",
    ])
    func macDeletionGoalsAreProhibited(_ goal: String) {
        #expect(policy.goalProhibitionReason(goal) != nil)
    }

    @Test func typingShellRemovalIsProhibited() {
        let decision = AgentDecision(operation: .typeAndEnter, targetId: "e1", textValue: "rm -rf ~/Documents")
        #expect(policy.actionProhibitionReason(for: decision, target: nil, goal: "clean up") != nil)
    }

    @Test func clickingEmptyTrashIsProhibited() {
        let menuItem = AccessibilityElement(id: "e3", role: "AXMenuItem", label: "Empty Trash…")
        let decision = AgentDecision(operation: .click, targetId: "e3", targetLabel: "Empty Trash…")
        #expect(policy.actionProhibitionReason(for: decision, target: menuItem, goal: "free up space") != nil)
    }

    @Test(arguments: ["open the Trash folder in Mail", "search for form templates", "open the terminal"])
    func ordinaryGoalsStayAllowed(_ goal: String) {
        #expect(policy.goalProhibitionReason(goal) == nil)
    }
}
