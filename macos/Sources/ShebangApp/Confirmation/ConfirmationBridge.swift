import Foundation
import ShebangCore

/// What the confirmation panel shows for a paused action (port of `ConfirmationDialog.SetDetails`).
struct ConfirmationDetails: Equatable, Sendable {
    static let maxTextLength = 200

    var action: String
    var target: String
    /// Text to be typed or opened, for operations that carry one.
    var text: String?
    var app: String
    var reason: String

    init(action: String, target: String, text: String? = nil, app: String, reason: String) {
        self.action = action
        self.target = target
        self.text = text
        self.app = app
        self.reason = reason
    }

    init(decision: AgentDecision, target: AccessibilityElement?, app: AppTarget, reason: String) {
        action = decision.operation.rawValue
        let label = [target?.displayLabel, decision.targetLabel, decision.targetId]
            .lazy.compactMap { $0?.nonBlank }.first ?? "(no control)"
        let role = target?.displayRole.nonBlank ?? "Control"
        self.target = "\(label) (\(role))"

        let carriesText: Set<AgentOperation> = [.typeText, .typeAndEnter, .openApp, .openUrl, .clickText]
        if carriesText.contains(decision.operation), let value = decision.textValue?.nonBlank {
            text = value.count > Self.maxTextLength ? String(value.prefix(Self.maxTextLength)) + "…" : value
        } else {
            text = nil
        }
        self.app = TargetFormatting.appDescription(app)
        self.reason = reason
    }
}

struct ConfirmationRequest: Equatable, Sendable {
    var details: ConfirmationDetails
    var app: AppTarget
}

/// Bridges the async `ConfirmationPrompt` call to the panel. Every request's continuation is resumed exactly once:
/// by approve/reject, by `cancelPending()` (kill switch), by cancellation of the requesting task, or by a newer
/// request superseding it. The last three count as rejection.
@MainActor
final class ConfirmationBridge {
    private struct Pending {
        var id: UInt64
        var request: ConfirmationRequest
        var continuation: CheckedContinuation<Bool, Never>
    }

    private var pending: Pending?
    private var nextID: UInt64 = 0

    var onPresent: ((ConfirmationRequest) -> Void)?
    var onDismiss: (() -> Void)?

    var isPending: Bool { pending != nil }
    var currentRequest: ConfirmationRequest? { pending?.request }

    func request(_ request: ConfirmationRequest) async -> Bool {
        nextID += 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if let previous = pending {
                    pending = nil
                    previous.continuation.resume(returning: false)
                }
                if Task.isCancelled {
                    onDismiss?()
                    continuation.resume(returning: false)
                    return
                }
                pending = Pending(id: id, request: request, continuation: continuation)
                onPresent?(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id: id, approved: false) }
        }
    }

    func resolve(approved: Bool) {
        guard let id = pending?.id else { return }
        resolve(id: id, approved: approved)
    }

    /// Rejects whatever is pending (kill switch, end of run).
    func cancelPending() {
        resolve(approved: false)
    }

    private func resolve(id: UInt64, approved: Bool) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        onDismiss?()
        current.continuation.resume(returning: approved)
    }
}

/// `ConfirmationPrompt` for the agent loop, which calls it from its own task; hops to the bridge on the main actor.
/// Cancelling the run task cancels the wait and rejects the action.
final class ConfirmationPromptAdapter: ConfirmationPrompt, Sendable {
    private let bridge: ConfirmationBridge

    init(bridge: ConfirmationBridge) {
        self.bridge = bridge
    }

    func requestConfirmation(
        decision: AgentDecision,
        target: AccessibilityElement?,
        app: AppTarget,
        reason: String
    ) async -> Bool {
        let request = ConfirmationRequest(
            details: ConfirmationDetails(decision: decision, target: target, app: app, reason: reason), app: app)
        let approved = await bridge.request(request)
        Log.safety.info("Confirmation \(approved ? "approved" : "rejected", privacy: .public) for \(decision.operation.rawValue, privacy: .public)")
        return approved
    }
}
