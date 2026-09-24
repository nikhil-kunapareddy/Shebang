import AppKit
import GhostHandCore
import GhostHandPlatform

/// Menu bar state that SwiftUI observes.
@MainActor
final class MenuState: ObservableObject {
    @Published var isRunActive = false
    @Published var hotkeyReady = false
}

/// Composition root (port of App.xaml.cs): hotkey → prompt → agent run, kill switch, first-run setup, and the
/// status and API key windows.
@MainActor
final class AppCoordinator {
    static let stopTimeoutSeconds: TimeInterval = 5

    let menuState = MenuState()
    let launchAtLogin = LaunchAtLoginModel(service: MainAppLoginItem())

    private let tracker = FrontmostWindowTracker()
    private let hotkey = GlobalHotkeyMonitor()
    private let keyMonitor = PanelKeyMonitor()
    private var session = RunSession()
    private var started = false

    private var runTask: Task<Void, Never>?
    private var stopWatchdog: Task<Void, Never>?
    private var statusTimer: Timer?
    private var showStatusObserver: NSObjectProtocol?

    // Created on first use, after `start()` ran `EnvLoader.load()`: the credential store snapshots the environment.
    private lazy var credentials = CredentialCache(store: KeychainCredentialStore())

    private lazy var hotkeyStarter: HotkeyStarter = {
        let hotkey = self.hotkey
        let starter = HotkeyStarter(start: { try hotkey.start() }, isTrusted: { Permissions.isAccessibilityTrusted })
        starter.onListeningChanged = { [weak self] listening in self?.menuState.hotkeyReady = listening }
        return starter
    }()

    private lazy var prompt: PromptPanelController = {
        let model = PromptViewModel(speech: AppleSpeechService())
        model.onSubmit = { [weak self] goal in self?.submit(goal: goal) }
        model.onCancel = { [weak self] in self?.cancelPrompt() }
        return PromptPanelController(model: model, keyMonitor: keyMonitor)
    }()

    private lazy var confirmation = ConfirmationPanelController(keyMonitor: keyMonitor)

    private lazy var statusModel: PermissionsViewModel = {
        let model = PermissionsViewModel(actions: SystemPermissionActions()) { [weak self] in
            self?.permissionStatus() ?? PermissionStatus()
        }
        model.onSetAPIKey = { [weak self] in self?.showAPIKeyWindow(reason: .manual) }
        return model
    }()

    private lazy var statusWindow: HostedWindowController = {
        let controller = HostedWindowController(title: "GhostHand Status & Permissions", rootView: StatusView(model: statusModel))
        controller.onClose = { [weak self] in self?.stopStatusPolling() }
        return controller
    }()

    private lazy var apiKeyModel: APIKeyViewModel = {
        let model = APIKeyViewModel(credentials: credentials, tester: { try await AppCoordinator.testConnection(apiKey: $0) })
        model.onSaved = { [weak self] in
            Log.app.info("API key saved from the setup window")
            self?.apiKeyWindow.close()
        }
        model.onCancel = { [weak self] in self?.apiKeyWindow.close() }
        return model
    }()

    private lazy var apiKeyWindow: HostedWindowController = {
        let controller = HostedWindowController(title: "GhostHand — AI Gateway API Key", rootView: APIKeyView(model: apiKeyModel))
        controller.onClose = { [weak self] in self?.apiKeyModel.cancelTest() }
        keyMonitor.registerEditingShortcuts(for: controller.window)
        return controller
    }()

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        EnvLoader.load()
        // Read the Keychain once now: a Keychain prompt while handling the hotkey would steal focus from the target.
        credentials.reload()

        hotkey.onHotkeyPressed = { [weak self] in self?.handleHotkey() }
        hotkey.onKillSwitch = { [weak self] in self?.stopRun(reason: "kill switch") }
        hotkeyStarter.begin()

        showStatusObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.showStatusNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showStatusWindow() }
        }

        if !Permissions.isAccessibilityTrusted {
            Log.app.notice("Accessibility not granted; showing Status & Permissions")
            showStatusWindow()
        }
        if !credentials.hasKey {
            Log.app.info("No API key found in environment or Keychain. Showing setup window.")
            showAPIKeyWindow(reason: .firstRun)
        }
        Log.app.info("GhostHand started. Press Control+Command to activate.")
    }

    func shutdown() {
        runTask?.cancel()
        if session.isRunActive { confirmation.cancelPending() }
        hotkeyStarter.stopPolling()
        hotkey.stop()
        stopStatusPolling()
    }

    // MARK: - Hotkey and menu

    func handleHotkey() {
        switch session.hotkeyAction {
        case .showPrompt: showPrompt()
        case .dismissPrompt: cancelPrompt()
        case .stopRun: stopRun(reason: "hotkey")
        case .ignore: break
        }
    }

    /// "Run on Current App" / "Stop Run" menu item.
    func runOrStopFromMenu() {
        if session.isRunActive {
            stopRun(reason: "menu")
        } else if !session.isPrompting {
            showPrompt()
        }
    }

    private func showPrompt() {
        guard Permissions.isAccessibilityTrusted else {
            Log.app.notice("Accessibility not granted; cannot target an app")
            showStatusWindow()
            return
        }
        // Capture before showing anything so GhostHand never becomes the target.
        let target = tracker.captureFrontmost()
        Log.app.info("""
            Trigger received. Foreground target: \(target?.processName ?? "None", privacy: .public) \
            (\(target?.windowTitle ?? "None", privacy: .private))
            """)
        guard session.beginPrompt(target: target) else { return }
        prompt.showPrompt(for: target, isDryRun: RunSettings.fromEnvironment().isDryRun)
    }

    private func cancelPrompt() {
        let target = session.promptTarget
        guard session.cancelPrompt() else { return }
        Log.app.info("Goal input cancelled.")
        prompt.hidePrompt()
        restoreFocus(to: target)
    }

    // MARK: - Runs

    private func submit(goal: String) {
        guard session.isPrompting else { return }
        let captured = session.promptTarget

        guard let jevOptions = credentials.optionsWithKey(JevOptions.fromEnvironment()) else {
            Log.app.warning("No API key available for agent loop.")
            _ = session.cancelPrompt()
            prompt.hidePrompt()
            showAPIKeyWindow(reason: .missingForRun)
            return
        }
        guard let target = captured ?? fallbackTarget() else {
            prompt.model.showError("No app to control. Click the app you want GhostHand to use, then press ⌃⌘.")
            return
        }
        guard let runID = session.startRun(target: target) else { return }

        let settings = RunSettings.fromEnvironment()
        Log.app.info("""
            Goal submitted: '\(goal, privacy: .private)' for app '\(target.processName, privacy: .public)' \
            (window \(target.windowNumber), dryRun: \(settings.isDryRun))
            """)

        prompt.showRun(target: target, isDryRun: settings.isDryRun)
        menuState.isRunActive = true
        hotkey.isRunActive = true
        // The executor refuses to act while another app is frontmost, so hand focus back to the target first.
        if !tracker.activate(target) {
            Log.app.warning("Could not activate \(target.processName, privacy: .public) before the run")
        }

        let request = RunRequest(goal: goal, target: target, jevOptions: jevOptions, loopOptions: settings.loopOptions)
        let hooks = RunHooks(
            onStatus: { [weak self] status in
                Task { @MainActor in self?.runStatusChanged(status, runID: runID) }
            },
            onTargetChanged: { [weak self] newTarget in
                Task { @MainActor in self?.runTargetChanged(newTarget, runID: runID) }
            })
        let tracker = self.tracker
        let confirmationPrompt = confirmation.prompt
        runTask = Task { [weak self] in
            let result = await AgentRunner.run(request, windowTracker: tracker, confirmation: confirmationPrompt, hooks: hooks)
            self?.runFinished(result, runID: runID)
        }
    }

    /// Kill switch (hotkey chord or Esc during a run, menu item). Cancels the run and rejects any open confirmation.
    func stopRun(reason: String) {
        guard let runID = session.requestStop() else {
            if session.isPrompting { cancelPrompt() }
            return
        }
        Log.app.info("Kill switch triggered (\(reason, privacy: .public)). Cancelling active tasks.")
        runTask?.cancel()
        confirmation.cancelPending()
        prompt.showStopping()

        let timeout = Self.stopTimeoutSeconds
        stopWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.detachStuckRun(runID: runID)
        }
    }

    private func runStatusChanged(_ status: String, runID: Int) {
        guard session.acceptsStatus(runID: runID) else { return }
        prompt.updateStatus(status)
    }

    private func runTargetChanged(_ target: AppTarget, runID: Int) {
        guard session.updateTarget(target, runID: runID) else { return }
        prompt.updateTarget(target)
    }

    private func runFinished(_ result: AgentRunResult, runID: Int) {
        let outcome = RunOutcome(result: result)
        guard session.finish(runID: runID, outcome: outcome) else { return }
        Log.app.info("""
            Agent loop finished with status \(result.status.rawValue, privacy: .public) after \(result.stepsCompleted) \
            step(s): \(result.message ?? "", privacy: .private)
            """)
        endRun(showing: outcome, runID: runID)
    }

    /// A cancelled loop only stops at its next suspension point; don't leave the app stuck if that takes too long.
    /// The loop checks cancellation before every action, so a detached run cannot act again.
    private func detachStuckRun(runID: Int) {
        let outcome = RunOutcome(result: .cancelled(steps: 0, history: []))
        guard session.finish(runID: runID, outcome: outcome) else { return }
        Log.app.warning("Run did not stop within \(Self.stopTimeoutSeconds, privacy: .public) s; detached it")
        endRun(showing: outcome, runID: runID)
    }

    private func endRun(showing outcome: RunOutcome, runID: Int) {
        runTask = nil
        stopWatchdog?.cancel()
        stopWatchdog = nil
        hotkey.isRunActive = false
        menuState.isRunActive = false
        confirmation.cancelPending()
        prompt.showResult(outcome) { [weak self] in
            _ = self?.session.dismissResult(runID: runID)
        }
    }

    /// Windows fell back to the desktop (explorer); the macOS equivalent is Finder.
    private func fallbackTarget() -> AppTarget? {
        if let frontmost = tracker.captureFrontmost() { return frontmost }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { return nil }
        let target = tracker.target(forProcessID: finder.processIdentifier)
        Log.app.info("Using fallback target: Finder")
        return target
    }

    /// The prompt never activates GhostHand, but a window it opened might have; give focus back to the target.
    private func restoreFocus(to target: AppTarget?) {
        guard let target, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else { return }
        tracker.activate(target)
    }

    // MARK: - Windows

    func showStatusWindow() {
        statusModel.refresh()
        startStatusPolling()
        statusWindow.show()
    }

    func showAPIKeyWindow(reason: APIKeyViewModel.Reason = .manual) {
        if !apiKeyWindow.isVisible { apiKeyModel.prepare(reason: reason) }
        apiKeyWindow.show()
    }

    func openAuditLogFolder() {
        let directory = JSONLAuditLog().directory
        if !NSWorkspace.shared.open(directory) {
            Log.app.error("Could not open audit log folder \(directory.path, privacy: .public)")
        }
    }

    private func startStatusPolling() {
        guard statusTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusModel.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func permissionStatus() -> PermissionStatus {
        PermissionStatus(
            accessibility: Permissions.isAccessibilityTrusted,
            screenRecording: Permissions.hasScreenRecording,
            microphone: Permissions.isMicrophoneAuthorized,
            speechRecognition: Permissions.isSpeechRecognitionAuthorized,
            apiKey: credentials.source,
            hotkeyListening: hotkeyStarter.isListening)
    }

    /// Sends Jev's diagnostic request with `apiKey` (one retry, so a bad key fails fast).
    nonisolated static func testConnection(apiKey: String) async throws -> String {
        var options = JevOptions.fromEnvironment()
        options.apiKey = apiKey
        options.maxRetries = 1
        return try await JevClient(options: options).checkConnection()
    }

    func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
