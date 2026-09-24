import AppKit
import GhostHandCore
import SwiftUI

/// Presents confirmation requests from the agent loop in a floating panel centred on the target window.
/// The panel takes key status (Return approves, Esc rejects) without activating GhostHand, so the target app is still
/// frontmost when the approved action runs.
@MainActor
final class ConfirmationPanelController {
    let bridge = ConfirmationBridge()
    let model = ConfirmationViewModel()
    /// Hand this to `AgentLoop`.
    let prompt: ConfirmationPromptAdapter

    private let panel = FloatingPanel(acceptsKey: true, level: .modalPanel)
    private let host: NSHostingView<ConfirmationView>

    init(keyMonitor: PanelKeyMonitor) {
        prompt = ConfirmationPromptAdapter(bridge: bridge)
        host = NSHostingView(rootView: ConfirmationView(model: model))
        panel.contentView = host
        panel.onCancel = { [weak model] in model?.reject() }

        bridge.onPresent = { [weak self] request in self?.present(request) }
        bridge.onDismiss = { [weak self] in self?.hide() }
        model.onDecision = { [weak bridge] approved in bridge?.resolve(approved: approved) }

        keyMonitor.register(panel) { [weak model] command, _ in
            switch command {
            case .cancel:
                model?.reject()
                return true
            case .confirm:
                model?.approve()
                return true
            case .edit:
                return false
            }
        }
    }

    /// Rejects and hides any pending request (kill switch).
    func cancelPending() {
        bridge.cancelPending()
    }

    private func present(_ request: ConfirmationRequest) {
        Log.safety.info("Confirmation requested for \(request.details.action, privacy: .public) in \(request.app.processName, privacy: .public)")
        model.present(request.details)
        host.rootView = ConfirmationView(model: model)
        let size = host.fittingSize
        let window = ScreenGeometry.windowFrame(of: request.app)
        let frame = PanelLayout.centeredFrame(size: size, window: window, visible: ScreenGeometry.visibleFrame(for: window))
        panel.setFrame(frame, display: true)
        panel.present(makeKey: true)
    }

    private func hide() {
        model.dismiss()
        panel.orderOut(nil)
    }
}
