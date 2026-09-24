import SwiftUI

/// Menu bar app (no Dock icon: `LSUIElement` in Info.plist). Press ⌃⌘ in any app to open the prompt.
@main
struct GhostHandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("GhostHand", systemImage: "hand.raised") {
            MenuBarContent(
                coordinator: appDelegate.coordinator,
                state: appDelegate.coordinator.menuState,
                launchAtLogin: appDelegate.coordinator.launchAtLogin)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarContent: View {
    let coordinator: AppCoordinator
    @ObservedObject var state: MenuState
    @ObservedObject var launchAtLogin: LaunchAtLoginModel

    var body: some View {
        Button(state.isRunActive ? "Stop Run (⌃⌘ or Esc)" : "Run on Current App (⌃⌘)") {
            coordinator.runOrStopFromMenu()
        }
        if !state.hotkeyReady {
            Text("Hotkey needs Accessibility access")
        }
        Divider()
        Button("Status & Permissions…") { coordinator.showStatusWindow() }
        Button("Set API Key…") { coordinator.showAPIKeyWindow() }
        Button("Open Audit Log Folder") { coordinator.openAuditLogFolder() }
        Divider()
        Toggle("Launch at Login", isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }))
        Divider()
        Button("Quit GhostHand") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
