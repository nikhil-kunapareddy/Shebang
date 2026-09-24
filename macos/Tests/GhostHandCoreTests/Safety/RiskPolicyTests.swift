import Foundation
import Testing
@testable import GhostHandCore

/// Jarvis-mode risk policy: everything runs automatically except deletions, which are strictly prohibited.
@Suite struct RiskPolicyTests {
    let policy = DefaultRiskPolicy()
    let sampleApp = AppTarget.fake(pid: 1234, name: "Google Chrome", bundleId: "com.google.Chrome",
                                   title: "Mock Application Form", window: 0x1234)

    // RS01
    @Test(arguments: [
        "Submit", "Submit Application", "Apply Now", "Send Email", "Pay $50", "Buy License", "Purchase Ticket",
        "Order Food", "Post Update", "Publish Article", "Confirm Transaction", "Sign in to Account",
        "Install Package", "Run Executable", "Transfer Funds", "Spotify pinned", "Search", "Next", "Previous",
        "View Profile", "Read More", "Refresh Feed", "Filter By Name",
    ])
    func rs01_allSafeActions_neverRequireConfirmation(_ label: String) {
        let decision = AgentDecision(operation: .click, targetId: "e1", targetLabel: label)
        let element = AccessibilityElement(id: "e1", role: "AXButton", label: label)

        #expect(policy.confirmationReason(for: decision, target: element, app: sampleApp) == nil)
        #expect(policy.actionProhibitionReason(for: decision, target: element, goal: "do it") == nil)
    }

    // RS02: even when the model rates a click irreversible, Jarvis mode neither asks the model nor the user.
    @Test func rs02_modelRisk_doesNotBlockExecution_inJarvisMode() async {
        let element = AccessibilityElement(id: "e2", role: "AXButton", label: "Export and Sync External Service")
        let decision = AgentDecision(operation: .click, targetId: "e2", targetLabel: element.label)
        #expect(policy.confirmationReason(for: decision, target: element, app: sampleApp) == nil)

        let model = FakeDecisionModel(script: [decision])
        model.risk = { _ in .irreversibleOrExternalEffect }
        let executor = FakeActionExecutor()
        let prompt = FakeConfirmationPrompt(approve: false)
        let loop = AgentLoop(screenReader: FakeScreenReader(elements: [element]), decisionModel: model,
                             actionExecutor: executor, options: AgentLoopOptions(maxSteps: 3), riskPolicy: policy,
                             confirmationPrompt: prompt, clock: FakeClock())

        let result = await loop.run(goal: "Sync external service", target: sampleApp)

        #expect(result.status == .completed)
        #expect(prompt.requests.isEmpty)
        #expect(model.riskRequests.isEmpty)
        #expect(executor.executed.count == 1)
    }

    // RS04
    @Test func rs04_safeAction_executedDirectly_noPrompt() async {
        let element = AccessibilityElement(id: "e1", role: "AXButton", label: "Submit Application")
        let decision = AgentDecision(operation: .click, targetId: "e1", targetLabel: "Submit Application")
        let executor = FakeActionExecutor()
        let prompt = FakeConfirmationPrompt()
        let audit = FakeAuditLog()
        let loop = AgentLoop(screenReader: FakeScreenReader(elements: [element]),
                             decisionModel: FakeDecisionModel(script: [decision]), actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 5), riskPolicy: policy, confirmationPrompt: prompt,
                             auditLog: audit, clock: FakeClock())

        _ = await loop.run(goal: "Fill and submit form", target: sampleApp)

        #expect(prompt.requests.isEmpty)
        #expect(executor.executed.count == 1)
        #expect(executor.executed.first?.decision == decision)
        #expect(executor.executed.first?.element == element)
        #expect(audit.entries.map(\.decisionType) == ["auto"])
    }

    // RS05
    @Test func rs05_passwordField_noConfirmationRequired() {
        let decision = AgentDecision(operation: .click, targetId: "pw1", targetLabel: "Password")
        let element = AccessibilityElement(id: "pw1", role: "AXSecureTextField", label: "Password", value: "[PASSWORD]")
        #expect(policy.confirmationReason(for: decision, target: element, app: sampleApp) == nil)
    }

    // RS06
    @Test func rs06_sensitiveTypedText_noConfirmation() {
        let decision = AgentDecision(operation: .typeText, targetId: "e1", targetLabel: "Search Box",
                                     textValue: "submit login transfer")
        #expect(policy.confirmationReason(for: decision, target: nil, app: sampleApp) == nil)
        #expect(policy.actionProhibitionReason(for: decision, target: nil, goal: "search") == nil)
    }

    // RS08
    @Test(arguments: [
        ("Google Chrome", "com.google.Chrome", "Submit Application Form"),
        ("Brave Browser", "com.brave.Browser", "Google Search"),
        ("Spotify", "com.spotify.client", "Spotify"),
        ("Finder", "com.apple.finder", "Desktop"),
        ("Safari", "com.apple.Safari", "Favorites"),
        ("chrome", "", "Windows-style process name"),
    ])
    func rs08_allApps_areAllowed_exceptPasswordManagers(_ name: String, _ bundleId: String, _ title: String) {
        let app = AppTarget.fake(pid: 1111, name: name, bundleId: bundleId, title: title, window: 0x1111)
        #expect(policy.denialReason(for: app) == nil)
    }

    // RS09
    @Test(arguments: [
        ("1Password", "com.1password.1password"),
        ("1Password 7", "com.agilebits.onepassword7"),
        ("Bitwarden", "com.bitwarden.desktop"),
        ("keepass", ""),
        ("KeePassXC", "org.keepassxc.keepassxc"),
        ("LastPass", ""),
        ("Dashlane", ""),
        ("Enpass", ""),
        ("Authenticator", ""),
        ("Keychain Access", "com.apple.keychainaccess"),
        ("Passwords", "com.apple.Passwords"),
        // Localized names are caught by bundle identifier.
        ("Schlüsselbundverwaltung", "com.apple.keychainaccess"),
        ("Passwörter", "com.apple.Passwords"),
    ])
    func rs09_denyListedApps_areRefusedImmediately(_ name: String, _ bundleId: String) async {
        let deniedApp = AppTarget.fake(pid: 9999, name: name, bundleId: bundleId, title: name, window: 0x9999)
        let reader = FakeScreenReader.changing()
        let executor = FakeActionExecutor()
        let audit = FakeAuditLog()
        let loop = AgentLoop(screenReader: reader, decisionModel: FakeDecisionModel(script: []),
                             actionExecutor: executor, options: AgentLoopOptions(maxSteps: 5), riskPolicy: policy,
                             auditLog: audit, clock: FakeClock())

        let result = await loop.run(goal: "Copy password", target: deniedApp)

        #expect(result.status == .failed)
        #expect(result.stepsCompleted == 0)
        #expect(result.message?.contains("deny-list") == true)
        #expect(reader.readCount == 0)
        #expect(executor.executed.isEmpty)
        #expect(audit.entries.count == 1)
        #expect(audit.entries.first?.decisionType == "denied")
        #expect(audit.entries.first?.appProcess == name)
    }

    @Test func denyList_isCaseInsensitiveAndConfigurable() {
        let custom = DefaultRiskPolicy(options: RiskPolicyOptions(denyListedApps: ["Com.Example.Vault", "MyVault"]))
        #expect(custom.denialReason(for: .fake(name: "myvault")) != nil)
        #expect(custom.denialReason(for: .fake(name: "Other", bundleId: "com.example.vault")) != nil)
        #expect(custom.denialReason(for: .fake(name: "1Password")) == nil)
        #expect(custom.denialReason(for: .fake(name: "", bundleId: "")) == nil)
    }

    // RS10
    @Test(arguments: [
        "delete all temp files", "erase all user data", "wipe hard disk", "destroy current session",
        "del secret.txt", "format c:", "truncate the logs table", "Complete the DELETION of my account",
    ])
    func rs10_deletionGoals_areStrictlyProhibited(_ goal: String) {
        let reason = policy.goalProhibitionReason(goal)
        #expect(reason?.localizedCaseInsensitiveContains("prohibited") == true)
    }

    @Test(arguments: [
        "open spotify", "search for Adele on youtube", "write hello world in notes", "launch calculator",
        "open google chrome", "submit the application form", "send an email to john", "install the app",
        "transfer funds to savings", "delegate the meeting to Sam", "use the model picker", "reformatted text",
        "", "   ",
    ])
    func rs10_benignGoals_areNotProhibited(_ goal: String) {
        #expect(policy.goalProhibitionReason(goal) == nil)
    }

    @Test func goalReason_namesTheMatchedTerm() {
        #expect(policy.goalProhibitionReason("please DELETE everything")
            == "Prohibited by safety policy: Deletion tasks (matching 'DELETE') are strictly prohibited.")
    }

    // RS11
    @Test(arguments: ["Delete", "Erase All", "Wipe Disk"])
    func rs11_deletionActionLabels_areStrictlyProhibited(_ label: String) {
        let decision = AgentDecision(operation: .click, targetId: "e_del", targetLabel: label)
        let element = AccessibilityElement(id: "e_del", role: "AXButton", label: label)

        let reason = policy.actionProhibitionReason(for: decision, target: element, goal: "clean up")
        #expect(reason?.localizedCaseInsensitiveContains("prohibited") == true)
    }

    @Test func actionProhibition_inspectsElementValueAndTypedText() {
        let field = AccessibilityElement(id: "e1", role: "AXTextField", label: "Command", value: "wipe everything")
        #expect(policy.actionProhibitionReason(for: AgentDecision(operation: .click, targetId: "e1"),
                                               target: field, goal: "run") != nil)

        let typed = AgentDecision(operation: .typeText, targetId: "e2", targetLabel: "Terminal", textValue: "del secret.txt")
        #expect(policy.actionProhibitionReason(for: typed, target: nil, goal: "run")
            == "Prohibited by safety policy: Action 'TypeText' on 'Terminal' matches deletion term 'del'.")

        let typedAndSubmitted = AgentDecision(operation: .typeAndEnter, targetId: "e2", textValue: "format disk0")
        #expect(policy.actionProhibitionReason(for: typedAndSubmitted, target: nil, goal: "run") != nil)

        // Text on non-typing operations is not inspected, as on Windows.
        let url = AgentDecision(operation: .openUrl, targetId: "https://example.com", textValue: "delete")
        #expect(policy.actionProhibitionReason(for: url, target: nil, goal: "browse") == nil)
    }

    @Test func emptyProhibitedTerms_neverProhibit() {
        let permissive = DefaultRiskPolicy(options: RiskPolicyOptions(prohibitedTerms: []))
        #expect(permissive.goalProhibitionReason("delete everything") == nil)
        #expect(permissive.actionProhibitionReason(for: AgentDecision(operation: .click, targetLabel: "Delete"),
                                                   target: nil, goal: "") == nil)
    }

    @Test func customTermsWithRegexCharacters_areEscaped() {
        let custom = DefaultRiskPolicy(options: RiskPolicyOptions(prohibitedTerms: ["rm -rf", "drop.table"]))
        #expect(custom.goalProhibitionReason("then rm -rf the folder") != nil)
        #expect(custom.goalProhibitionReason("drop.table users") != nil)
        #expect(custom.goalProhibitionReason("dropXtable users") == nil)
    }

    @Test func optionDefaults_matchJarvisMode() {
        let options = RiskPolicyOptions()
        #expect(options.sensitiveVerbs.isEmpty)
        // Windows terms plus the macOS deletion vocabulary.
        #expect(options.prohibitedTerms.isSuperset(of: ["delete", "deletion", "erase", "wipe", "destroy", "truncate", "format", "del"]))
        #expect(options.prohibitedTerms.isSuperset(of: ["rm", "rmdir", "empty trash", "move to trash", "erasedisk"]))
        #expect(options.escalateOnRiskScore == .irreversibleOrExternalEffect)
        #expect(!options.requireConfirmationOnSensitiveText)
        #expect(options.denyListedApps.contains("com.apple.keychainaccess"))
        #expect(options.denyListedApps.contains("com.apple.passwords"))
    }

    // RS12
    @Test func rs12_agentLoop_abortsImmediately_onProhibitedGoal() async {
        let reader = FakeScreenReader.changing()
        let executor = FakeActionExecutor()
        let prompt = FakeConfirmationPrompt()
        let audit = FakeAuditLog()
        let loop = AgentLoop(screenReader: reader, decisionModel: FakeDecisionModel(script: []),
                             actionExecutor: executor, options: AgentLoopOptions(maxSteps: 5), riskPolicy: policy,
                             confirmationPrompt: prompt, auditLog: audit, clock: FakeClock())

        let result = await loop.run(goal: "delete my files in notes", target: sampleApp)

        #expect(result.status == .failed)
        #expect(result.stepsCompleted == 0)
        #expect(result.message?.contains("Prohibited") == true)
        #expect(reader.readCount == 0)
        #expect(executor.executed.isEmpty)
        #expect(prompt.requests.isEmpty)
        #expect(audit.entries.count == 1)
        #expect(audit.entries.first?.decisionType == "prohibited")
        #expect(audit.entries.first?.goal.contains("delete") == true)
        #expect(audit.entries.first?.operation == .askUser)
    }

    // RS13
    @Test func rs13_agentLoop_abortsImmediately_onProhibitedAction() async {
        let element = AccessibilityElement(id: "del_btn", role: "AXButton", label: "Delete")
        let decision = AgentDecision(operation: .click, targetId: "del_btn", targetLabel: "Delete")
        let executor = FakeActionExecutor()
        let prompt = FakeConfirmationPrompt()
        let audit = FakeAuditLog()
        let loop = AgentLoop(screenReader: FakeScreenReader(elements: [element]),
                             decisionModel: FakeDecisionModel { _, _, _ in decision }, actionExecutor: executor,
                             options: AgentLoopOptions(maxSteps: 5), riskPolicy: policy, confirmationPrompt: prompt,
                             auditLog: audit, clock: FakeClock())

        let result = await loop.run(goal: "organize documents", target: sampleApp)

        #expect(result.status == .failed)
        #expect(result.stepsCompleted == 1)
        #expect(result.message?.contains("Prohibited") == true)
        #expect(executor.executed.isEmpty)
        #expect(prompt.requests.isEmpty)
        #expect(audit.entries.count == 1)
        #expect(audit.entries.first?.decisionType == "prohibited")
        #expect(audit.entries.first?.operation == .click)
    }
}
