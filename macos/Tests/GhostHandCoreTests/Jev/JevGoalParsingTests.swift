import Foundation
import Testing
@testable import GhostHandCore

@Suite struct JevGoalParsingTests {
    @Test(arguments: [
        ("open brave and search lion", "lion"),
        ("search about lion", "lion"),
        ("open chrome and search for weather", "weather"),
        ("write hello into notepad", "hello"),
        ("write hello into textedit", "hello"),
        ("open spotify and play any song of aditya rikhari", "aditya rikhari"),
        ("play aditya rikhari on spotify", "aditya rikhari"),
        ("listen to Bohemian Rhapsody", "Bohemian Rhapsody"),
        (#"type "Hello World" into TextEdit"#, "Hello World"),
        ("calculate 450 * 12 + 85", "450 * 12 + 85"),
        ("please weather today", "weather today"),
    ])
    func extractsSearchWriteAndPlayPhrases(goal: String, expected: String) {
        #expect(JevDecisionModel.extractCandidatePhrases(goal).contains(expected))
    }

    @Test func shortGoalFallsBackToWholePhrase() {
        #expect(JevDecisionModel.extractCandidatePhrases("Adele") == ["Adele"])
        #expect(JevDecisionModel.extractCandidatePhrases("click the blue button").isEmpty)
        #expect(JevDecisionModel.extractCandidatePhrases("Scroll down a bit").isEmpty)
        #expect(JevDecisionModel.extractCandidatePhrases(String(repeating: "word ", count: 20)).isEmpty)
    }

    @Test func phrasesAreUniqueIgnoringCaseInDiscoveryOrder() {
        #expect(JevDecisionModel.extractCandidatePhrases("search for Adele. play ADELE") == ["Adele"])
        #expect(JevDecisionModel.extractCandidatePhrases(#"search for "Adele" and play "Skyfall""#).prefix(2) == ["Adele", "Skyfall"])
    }

    @Test(arguments: [
        ("open obsidian", "obsidian"),
        ("switch to discord", "discord"),
        ("start spotify", "spotify"),
        ("open vlc", "vlc"),
        ("launch blender", "blender"),
        ("open System Settings and turn on Wi-Fi", "System Settings"),
        ("open the app Notes", "Notes"),
    ])
    func extractsAppLaunchCandidates(goal: String, expected: String) {
        #expect(JevDecisionModel.extractAppLaunchCandidates(goal) == [expected])
    }

    @Test(arguments: ["open menu", "open file", "go to page.", "   ", "type hello"])
    func ignoresGenericNounsAndNonLaunchGoals(goal: String) {
        #expect(JevDecisionModel.extractAppLaunchCandidates(goal).isEmpty)
    }

    @Test func urlCandidatesComeFromTheSharedValidator() {
        let choices = JevDecisionModel.buildCandidateChoices(goal: "open https://news.ycombinator.com", elements: [])
        #expect(choices["open_url:https://news.ycombinator.com"] != nil)
    }
}

/// Calls the real gateway. Run with `JEV_LIVE_TESTS=1 AI_GATEWAY_API_KEY=... ./Scripts/test.sh --filter JevLiveTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["JEV_LIVE_TESTS"] == "1", "Set JEV_LIVE_TESTS=1 to call Vercel AI Gateway"))
struct JevLiveTests {
    let options = JevOptions.fromEnvironment()

    @Test func checkConnectionReachesGateway() async throws {
        try #require(options.apiKey != nil, "AI_GATEWAY_API_KEY is required for live tests")
        let summary = try await JevClient(options: options).checkConnection()
        #expect(summary.contains("Jev reachable"))
    }

    @Test func decisionModelChoosesAnOfferedAction() async throws {
        try #require(options.apiKey != nil, "AI_GATEWAY_API_KEY is required for live tests")
        let model = JevDecisionModel(client: JevClient(options: options), options: options)
        let target = AppTarget(processId: 1, processName: "Safari", windowTitle: "Start Page")
        let elements = [
            AccessibilityElement(id: "e1", role: "AXTextField", label: "Address and Search", focused: true),
            AccessibilityElement(id: "e2", role: "AXButton", label: "Reload"),
        ]

        let decision = try await model.decideNextAction(
            goal: "search for Adele", target: target, elements: elements, history: [])

        #expect(decision.operation != .blocked)
    }
}
