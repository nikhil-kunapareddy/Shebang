import Foundation

/// `readLine()` on a helper thread so waiting for an answer never blocks the cooperative pool, and task
/// cancellation (Ctrl-C) resolves the wait with nil instead of hanging on stdin.
enum StandardInput {
    static func readLine() async -> String? {
        let gate = ResumeOnce()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                Thread.detachNewThread { gate.resume(Swift.readLine(strippingNewline: true)) }
            }
        } onCancel: {
            gate.resume(nil)
        }
    }

    /// Resumes the continuation exactly once, whichever of input, cancellation, or installation comes first.
    private final class ResumeOnce: @unchecked Sendable {
        private enum State {
            case idle
            case waiting(CheckedContinuation<String?, Never>)
            case resolved(String?)
            case finished
        }

        private let lock = NSLock()
        private var state = State.idle

        func install(_ continuation: CheckedContinuation<String?, Never>) {
            lock.withLock {
                switch state {
                case .idle:
                    state = .waiting(continuation)
                case .resolved(let value):
                    state = .finished
                    continuation.resume(returning: value)
                case .waiting, .finished:
                    break
                }
            }
        }

        func resume(_ value: String?) {
            lock.withLock {
                switch state {
                case .idle:
                    state = .resolved(value)
                case .waiting(let continuation):
                    state = .finished
                    continuation.resume(returning: value)
                case .resolved, .finished:
                    break
                }
            }
        }
    }
}
