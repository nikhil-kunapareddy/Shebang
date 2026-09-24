import Foundation
import GhostHandCore
import ServiceManagement

/// Seam over `SMAppService.mainApp` so the toggle logic is testable.
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

final class MainAppLoginItem: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Backs the "Launch at Login" menu toggle.
@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var isEnabled = false
    var onError: ((String) -> Void)?

    private let service: LoginItemService

    init(service: LoginItemService) {
        self.service = service
        refresh()
    }

    /// `.requiresApproval` counts as on: the item is registered and waits for the user in System Settings.
    func refresh() {
        isEnabled = [.enabled, .requiresApproval].contains(service.status)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
                if service.status == .requiresApproval { service.openSystemSettings() }
            } else {
                try service.unregister()
            }
            Log.app.info("Launch at login \(enabled ? "enabled" : "disabled", privacy: .public)")
        } catch {
            Log.app.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
            onError?(error.localizedDescription)
        }
        refresh()
    }
}
