import AppKit
import ServiceManagement
import Testing
@testable import ShebangApp

@Suite @MainActor struct HotkeyStarterTests {
    private final class Monitor {
        var trusted = false
        var failures = 0
        var starts = 0

        func start() throws {
            starts += 1
            if failures > 0 {
                failures -= 1
                throw TestError(message: "event tap failed")
            }
        }
    }

    private func makeStarter(_ monitor: Monitor) -> HotkeyStarter {
        HotkeyStarter(start: { try monitor.start() }, isTrusted: { monitor.trusted })
    }

    @Test func waitsForAccessibilityWithoutTryingToStart() {
        let monitor = Monitor()
        let starter = makeStarter(monitor)
        starter.begin()
        #expect(monitor.starts == 0)
        #expect(!starter.isListening)
        #expect(starter.isPolling)
        starter.stopPolling()
        #expect(!starter.isPolling)
    }

    @Test func startsOnceAccessibilityIsGranted() {
        let monitor = Monitor()
        let starter = makeStarter(monitor)
        var changes: [Bool] = []
        starter.onListeningChanged = { changes.append($0) }
        starter.begin()
        #expect(!starter.attempt())

        monitor.trusted = true
        #expect(starter.attempt())
        #expect(starter.isListening)
        #expect(!starter.isPolling)
        #expect(changes == [true])

        #expect(starter.attempt())
        #expect(monitor.starts == 1)
    }

    @Test func startsImmediatelyWhenAlreadyTrusted() {
        let monitor = Monitor()
        monitor.trusted = true
        let starter = makeStarter(monitor)
        starter.begin()
        #expect(starter.isListening)
        #expect(!starter.isPolling)
    }

    @Test func retriesAfterAFailedStart() {
        let monitor = Monitor()
        monitor.trusted = true
        monitor.failures = 1
        let starter = makeStarter(monitor)
        starter.begin()
        #expect(!starter.isListening)
        #expect(starter.isPolling)
        #expect(starter.attempt())
        #expect(monitor.starts == 2)
        #expect(!starter.isPolling)
    }
}

@Suite struct SingleInstanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func runsAloneWhenNoOtherInstanceExists() {
        let me = SingleInstance.Instance(pid: 100, launchDate: now)
        #expect(SingleInstance.instanceToDeferTo(current: me, others: []) == nil)
        #expect(SingleInstance.instanceToDeferTo(current: me, others: [me]) == nil)
    }

    @Test func defersToAnOlderInstance() {
        let me = SingleInstance.Instance(pid: 100, launchDate: now)
        let older = SingleInstance.Instance(pid: 200, launchDate: now.addingTimeInterval(-60))
        #expect(SingleInstance.instanceToDeferTo(current: me, others: [me, older]) == older)
    }

    @Test func keepsRunningWhenTheOtherIsNewer() {
        let me = SingleInstance.Instance(pid: 100, launchDate: now)
        let newer = SingleInstance.Instance(pid: 50, launchDate: now.addingTimeInterval(5))
        #expect(SingleInstance.instanceToDeferTo(current: me, others: [newer]) == nil)
    }

    @Test func simultaneousLaunchesAgreeOnTheLowerPID() {
        let low = SingleInstance.Instance(pid: 100, launchDate: now)
        let high = SingleInstance.Instance(pid: 101, launchDate: now)
        #expect(SingleInstance.instanceToDeferTo(current: high, others: [low, high]) == low)
        #expect(SingleInstance.instanceToDeferTo(current: low, others: [low, high]) == nil)

        let unknownLow = SingleInstance.Instance(pid: 100, launchDate: nil)
        let unknownHigh = SingleInstance.Instance(pid: 101, launchDate: now)
        #expect(SingleInstance.instanceToDeferTo(current: unknownHigh, others: [unknownLow]) == unknownLow)
    }

    @Test func defersToTheOldestOfSeveral() {
        let me = SingleInstance.Instance(pid: 100, launchDate: now)
        let old = SingleInstance.Instance(pid: 300, launchDate: now.addingTimeInterval(-10))
        let oldest = SingleInstance.Instance(pid: 400, launchDate: now.addingTimeInterval(-100))
        #expect(SingleInstance.instanceToDeferTo(current: me, others: [old, oldest]) == oldest)
    }
}

@Suite struct PanelKeyCommandTests {
    private func command(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String? = nil)
        -> PanelKeyCommand? {
        PanelKeyCommand.from(keyCode: keyCode, modifiers: modifiers, characters: characters)
    }

    @Test func escapeCancels() {
        #expect(command(PanelKeyCommand.escapeKeyCode) == .cancel)
        #expect(command(PanelKeyCommand.escapeKeyCode, [.capsLock, .function]) == .cancel)
        #expect(command(PanelKeyCommand.escapeKeyCode, .shift) == nil)
    }

    @Test func returnAndEnterConfirm() {
        #expect(command(PanelKeyCommand.returnKeyCode, [], "\r") == .confirm)
        #expect(command(PanelKeyCommand.keypadEnterKeyCode, .numericPad, "\u{3}") == .confirm)
        #expect(command(PanelKeyCommand.returnKeyCode, .shift, "\r") == nil)
        #expect(command(PanelKeyCommand.returnKeyCode, .command, "\r") == nil)
    }

    @Test func editingShortcuts() {
        #expect(command(9, .command, "v") == .edit(.paste))
        #expect(command(8, .command, "c") == .edit(.copy))
        #expect(command(7, .command, "x") == .edit(.cut))
        #expect(command(0, .command, "a") == .edit(.selectAll))
        #expect(command(6, .command, "z") == .edit(.undo))
        #expect(command(6, [.command, .shift], "Z") == .edit(.redo))
    }

    @Test func otherKeysPassThrough() {
        #expect(command(9, [], "v") == nil)
        #expect(command(9, [.command, .option], "v") == nil)
        #expect(command(8, .control, "c") == nil)
        #expect(command(9, [.command, .shift], "v") == nil)
        #expect(command(12, .command, "q") == nil)
    }

    @Test func editActionsMapToResponderSelectors() {
        #expect(PanelKeyCommand.EditAction.paste.selector == #selector(NSText.paste(_:)))
        #expect(PanelKeyCommand.EditAction.selectAll.selector == #selector(NSText.selectAll(_:)))
        #expect(PanelKeyCommand.EditAction.undo.selector == Selector(("undo:")))
    }
}

@Suite @MainActor struct LaunchAtLoginModelTests {
    private final class FakeLoginItem: LoginItemService {
        var status: SMAppService.Status
        var statusAfterRegister: SMAppService.Status = .enabled
        var registerError: Error?
        var calls: [String] = []

        init(status: SMAppService.Status) {
            self.status = status
        }

        func register() throws {
            calls.append("register")
            if let registerError { throw registerError }
            status = statusAfterRegister
        }

        func unregister() throws {
            calls.append("unregister")
            status = .notRegistered
        }

        func openSystemSettings() { calls.append("openSystemSettings") }
    }

    @Test func reflectsTheCurrentStatus() {
        #expect(LaunchAtLoginModel(service: FakeLoginItem(status: .enabled)).isEnabled)
        #expect(LaunchAtLoginModel(service: FakeLoginItem(status: .requiresApproval)).isEnabled)
        #expect(!LaunchAtLoginModel(service: FakeLoginItem(status: .notRegistered)).isEnabled)
        #expect(!LaunchAtLoginModel(service: FakeLoginItem(status: .notFound)).isEnabled)
    }

    @Test func togglesRegistration() {
        let item = FakeLoginItem(status: .notRegistered)
        let model = LaunchAtLoginModel(service: item)
        model.setEnabled(true)
        #expect(model.isEnabled)
        model.setEnabled(false)
        #expect(!model.isEnabled)
        #expect(item.calls == ["register", "unregister"])
    }

    @Test func opensSettingsWhenApprovalIsNeeded() {
        let item = FakeLoginItem(status: .notRegistered)
        item.statusAfterRegister = .requiresApproval
        let model = LaunchAtLoginModel(service: item)
        model.setEnabled(true)
        #expect(model.isEnabled)
        #expect(item.calls == ["register", "openSystemSettings"])
    }

    @Test func reportsFailures() {
        let item = FakeLoginItem(status: .notRegistered)
        item.registerError = TestError(message: "Operation not permitted")
        let model = LaunchAtLoginModel(service: item)
        var errors: [String] = []
        model.onError = { errors.append($0) }
        model.setEnabled(true)
        #expect(!model.isEnabled)
        #expect(errors == ["Operation not permitted"])
    }
}
