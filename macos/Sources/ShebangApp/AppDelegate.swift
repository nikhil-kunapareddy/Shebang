import AppKit
import ShebangCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationWillFinishLaunching(_ notification: Notification) {
        if SingleInstance.handOffToRunningInstance() {
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.launchAtLogin.onError = { [weak coordinator] message in
            coordinator?.presentError(title: "Couldn't change Launch at Login", message: message)
        }
        coordinator.start()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the status window, since there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.showStatusWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
}
