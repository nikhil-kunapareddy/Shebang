import AppKit
import ShebangCore
import SwiftUI

/// Owns the prompt panel and the status HUD it collapses into during a run.
///
/// The prompt can become key without activating Shebang, so typing works while the target stays the active app.
/// On submit it is hidden and replaced by a click-through HUD that never takes focus, so it cannot intercept clicks or
/// keystrokes meant for the target (the Windows build hid its popup during actions for the same reason).
@MainActor
final class PromptPanelController {
    let model: PromptViewModel

    private let panel = FloatingPanel(acceptsKey: true, level: .floating)
    private let promptHost: NSHostingView<PromptView>
    private let hud = FloatingPanel(acceptsKey: false, level: .floating)
    private let hudHost: NSHostingView<RunHUDView>
    private var hudState = RunHUDState()
    private var hudIcon: NSImage?
    private var hudTarget: AppTarget?
    private var autoHideTask: Task<Void, Never>?

    init(model: PromptViewModel, keyMonitor: PanelKeyMonitor) {
        self.model = model

        promptHost = NSHostingView(rootView: PromptView(model: model))
        panel.contentView = promptHost
        panel.onCancel = { [weak model] in model?.cancel() }

        hudHost = NSHostingView(rootView: RunHUDView(state: hudState, icon: nil))
        hud.contentView = hudHost

        keyMonitor.register(panel) { [weak self] command, _ in
            self?.handleKey(command) ?? false
        }
    }

    var isPromptVisible: Bool { panel.isVisible }

    func showPrompt(for target: AppTarget?, isDryRun: Bool) {
        cancelAutoHide()
        hud.orderOut(nil)
        model.present(target: target, icon: ScreenGeometry.icon(for: target), isDryRun: isDryRun)

        let window = ScreenGeometry.windowFrame(of: target)
        let frame = PanelLayout.promptFrame(
            size: promptHost.fittingSize, window: window, visible: ScreenGeometry.visibleFrame(for: window))
        panel.setFrame(frame, display: false)
        panel.present(makeKey: true)
        focusTextField()
    }

    func hidePrompt() {
        model.dismiss()
        panel.orderOut(nil)
    }

    /// Collapses the prompt into the status HUD for a run on `target`.
    func showRun(target: AppTarget, isDryRun: Bool) {
        cancelAutoHide()
        model.dismiss()
        panel.orderOut(nil)
        hudTarget = target
        hudIcon = ScreenGeometry.icon(for: target)
        hudState = RunHUDState(mode: .running, status: "Starting…", targetName: target.processName, isDryRun: isDryRun)
        renderHUD(reposition: true)
        hud.present(makeKey: false)
    }

    func updateStatus(_ status: String) {
        guard hudState.mode == .running else { return }
        hudState.status = status
        renderHUD(reposition: false)
    }

    func updateTarget(_ target: AppTarget) {
        hudTarget = target
        hudIcon = ScreenGeometry.icon(for: target)
        hudState.targetName = target.processName
        renderHUD(reposition: true)
    }

    func showStopping() {
        hudState.mode = .stopping
        renderHUD(reposition: false)
    }

    /// Shows the result in the HUD, then hides it after `outcome.displaySeconds` and calls `onHidden`.
    func showResult(_ outcome: RunOutcome, onHidden: @escaping () -> Void) {
        cancelAutoHide()
        hudState.mode = .result(outcome)
        renderHUD(reposition: !hud.isVisible)
        hud.present(makeKey: false)

        let seconds = outcome.displaySeconds
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.hud.orderOut(nil)
            onHidden()
        }
    }

    func hideAll() {
        cancelAutoHide()
        hidePrompt()
        hud.orderOut(nil)
    }

    // MARK: - Private

    private func handleKey(_ command: PanelKeyCommand) -> Bool {
        // While an input method is composing, Esc and Return belong to it.
        let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
        switch command {
        case .cancel:
            guard !composing else { return false }
            model.cancel()
            return true
        case .confirm:
            guard !composing else { return false }
            model.submit()
            return true
        case .edit(let action):
            return PanelKeyMonitor.perform(action, in: panel)
        }
    }

    private func renderHUD(reposition: Bool) {
        hudHost.rootView = RunHUDView(state: hudState, icon: hudIcon)
        let size = hudHost.fittingSize
        if reposition || !hud.isVisible {
            let window = ScreenGeometry.windowFrame(of: hudTarget)
            let frame = PanelLayout.hudFrame(size: size, window: window, visible: ScreenGeometry.visibleFrame(for: window))
            hud.setFrame(frame, display: true)
        } else {
            // Keep the bottom edge fixed so longer status text grows the HUD upward.
            var frame = hud.frame
            frame.origin.x += (frame.width - size.width) / 2
            frame.size = size
            hud.setFrame(frame, display: true)
        }
        hud.invalidateShadow()
    }

    /// SwiftUI focus can lag behind a panel that just became key; fall back to focusing the text field directly.
    private func focusTextField() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.panel.isKeyWindow, !(self.panel.firstResponder is NSTextView),
                  let field = Self.firstTextField(in: self.panel.contentView) else { return }
            self.panel.makeFirstResponder(field)
        }
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }
}
