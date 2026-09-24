import GhostHandPlatform
import Testing
@testable import GhostHandApp

@MainActor
private final class FakePermissionActions: PermissionActions {
    var calls: [String] = []
    var openedPanes: [Permissions.Pane] = []
    var microphoneResult = false
    var speechResult = false

    func promptAccessibility() { calls.append("promptAccessibility") }
    func requestScreenRecording() { calls.append("requestScreenRecording") }
    func requestMicrophone() async -> Bool {
        calls.append("requestMicrophone")
        return microphoneResult
    }
    func requestSpeechRecognition() async -> Bool {
        calls.append("requestSpeechRecognition")
        return speechResult
    }
    func openSettings(_ pane: Permissions.Pane) { openedPanes.append(pane) }
}

@Suite @MainActor struct PermissionsViewModelTests {
    private final class StatusBox {
        var status = PermissionStatus()
    }

    private func makeModel(_ status: PermissionStatus = PermissionStatus()) -> (PermissionsViewModel, FakePermissionActions, StatusBox) {
        let actions = FakePermissionActions()
        let box = StatusBox()
        box.status = status
        let model = PermissionsViewModel(actions: actions) { box.status }
        return (model, actions, box)
    }

    @Test func rowsCoverEveryPermission() {
        let (model, _, _) = makeModel()
        #expect(model.rows.map(\.kind) == PermissionKind.allCases)
        #expect(model.rows.filter(\.isRequired).map(\.kind) == [.accessibility, .apiKey])
        #expect(model.rows.allSatisfy { !$0.isGranted })
        #expect(model.rows.first { $0.kind == .accessibility }?.actionTitle == "Grant Access…")
        #expect(model.rows.first { $0.kind == .apiKey }?.stateText == "Not set")
    }

    @Test func grantedRowsOfferSettings() {
        var status = PermissionStatus()
        status.accessibility = true
        status.microphone = true
        status.apiKey = .environment
        let (model, _, _) = makeModel(status)
        let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.kind, $0) })
        #expect(rows[.accessibility]?.isGranted == true)
        #expect(rows[.accessibility]?.actionTitle == "Open Settings…")
        #expect(rows[.microphone]?.stateText == "Granted")
        #expect(rows[.speechRecognition]?.actionTitle == "Allow…")
        #expect(rows[.apiKey]?.stateText == "From environment")
        #expect(rows[.apiKey]?.actionTitle == "Change…")
    }

    @Test func summaryNamesWhatIsMissing() {
        var status = PermissionStatus()
        let (model, _, box) = makeModel(status)
        #expect(model.summary == "Accessibility access is required.")
        #expect(!model.isReady)

        status.accessibility = true
        box.status = status
        model.refresh()
        #expect(model.summary == "Add your AI Gateway API key to start.")

        status.apiKey = .keychain
        box.status = status
        model.refresh()
        #expect(model.isReady)
        #expect(model.summary.hasPrefix("Ready"))
    }

    @Test func hotkeyTextFollowsTheMonitor() {
        var status = PermissionStatus()
        let (model, _, box) = makeModel(status)
        #expect(model.hotkeyText.contains("once Accessibility is granted"))
        status.hotkeyListening = true
        box.status = status
        model.refresh()
        #expect(model.hotkeyText == "⌃⌘ hotkey is listening.")
    }

    @Test func accessibilityPromptsOnceThenOpensSettings() {
        let (model, actions, _) = makeModel()
        model.perform(.accessibility)
        #expect(actions.calls == ["promptAccessibility"])
        #expect(actions.openedPanes.isEmpty)
        model.perform(.accessibility)
        #expect(actions.calls == ["promptAccessibility"])
        #expect(actions.openedPanes == [.accessibility])
    }

    @Test func screenRecordingPromptsOnceThenOpensSettings() {
        let (model, actions, _) = makeModel()
        model.perform(.screenRecording)
        model.perform(.screenRecording)
        #expect(actions.calls == ["requestScreenRecording"])
        #expect(actions.openedPanes == [.screenRecording])
    }

    @Test func grantedPermissionOpensSettingsDirectly() {
        var status = PermissionStatus()
        status.accessibility = true
        status.speechRecognition = true
        let (model, actions, _) = makeModel(status)
        model.perform(.accessibility)
        model.perform(.speechRecognition)
        #expect(actions.calls.isEmpty)
        #expect(actions.openedPanes == [.accessibility, .speechRecognition])
    }

    @Test func deniedMicrophoneFallsThroughToSettings() async {
        let (model, actions, _) = makeModel()
        model.perform(.microphone)
        #expect(await waitUntil { actions.openedPanes == [.microphone] })
        #expect(actions.calls == ["requestMicrophone"])
    }

    @Test func grantedSpeechRequestRefreshesWithoutSettings() async {
        let (model, actions, box) = makeModel()
        actions.speechResult = true
        box.status.speechRecognition = true
        model.perform(.speechRecognition)
        #expect(await waitUntil { model.status.speechRecognition })
        #expect(actions.calls == ["requestSpeechRecognition"])
        #expect(actions.openedPanes.isEmpty)
    }

    @Test func apiKeyRowOpensTheKeyWindow() {
        let (model, actions, _) = makeModel()
        var opened = 0
        model.onSetAPIKey = { opened += 1 }
        model.perform(.apiKey)
        #expect(opened == 1)
        #expect(actions.calls.isEmpty)
    }

    @Test func panesMapToSystemSettings() {
        #expect(PermissionKind.accessibility.pane == .accessibility)
        #expect(PermissionKind.screenRecording.pane == .screenRecording)
        #expect(PermissionKind.microphone.pane == .microphone)
        #expect(PermissionKind.speechRecognition.pane == .speechRecognition)
        #expect(PermissionKind.apiKey.pane == nil)
    }
}
