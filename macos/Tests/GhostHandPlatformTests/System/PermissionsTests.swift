import Foundation
import Testing
@testable import GhostHandPlatform

@Suite struct PermissionsTests {
    @Test(arguments: [
        (Permissions.Pane.accessibility, "Privacy_Accessibility"),
        (.screenRecording, "Privacy_ScreenCapture"),
        (.microphone, "Privacy_Microphone"),
        (.speechRecognition, "Privacy_SpeechRecognition"),
    ])
    func paneURLsOpenPrivacySettings(pane: Permissions.Pane, anchor: String) {
        #expect(pane.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    @Test func missingUsageDescriptionBlocksThePrompt() {
        #expect(!Permissions.hasUsageDescription("GHNonexistentUsageDescription"))
    }
}
