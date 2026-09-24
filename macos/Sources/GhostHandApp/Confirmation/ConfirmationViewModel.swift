import Foundation

/// State of the confirmation panel. Approval is armed only after a short delay so a Return typed into the target
/// app just as the panel appears cannot approve a sensitive action by accident; rejecting works immediately.
@MainActor
final class ConfirmationViewModel: ObservableObject {
    @Published private(set) var details: ConfirmationDetails?
    @Published private(set) var isArmed = false

    var armDelay: TimeInterval = 0.4
    /// Receives the user's decision exactly once per presented request.
    var onDecision: ((Bool) -> Void)?

    private var armTask: Task<Void, Never>?

    func present(_ details: ConfirmationDetails) {
        armTask?.cancel()
        self.details = details
        isArmed = armDelay <= 0
        guard !isArmed else { return }
        let delay = armDelay
        armTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.details == details else { return }
            self.isArmed = true
        }
    }

    func approve() {
        guard details != nil, isArmed else { return }
        decide(true)
    }

    func reject() {
        guard details != nil else { return }
        decide(false)
    }

    func dismiss() {
        armTask?.cancel()
        armTask = nil
        details = nil
        isArmed = false
    }

    private func decide(_ approved: Bool) {
        dismiss()
        onDecision?(approved)
    }
}
