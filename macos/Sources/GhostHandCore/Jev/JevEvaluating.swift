import Foundation

/// Sends one evaluate request to Jev. Throws `JevError`, or `CancellationError` when the task is cancelled.
public protocol JevEvaluating: AnyObject {
    func evaluate(_ request: EvaluateRequest) async throws -> EvaluateResponse
}
