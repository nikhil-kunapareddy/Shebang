import Foundation

struct DeadlineExceededError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Races `operation` against a timer. Unlike a task group this does not wait for an uncooperative child,
/// so a non-cancellable system call (e.g. ScreenCaptureKit enumeration) cannot hang the caller.
func withDeadline<T>(
    seconds: TimeInterval,
    message: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try Task.checkCancellation()
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            race.track(Task {
                do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
            })
            race.track(Task {
                do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) } catch { return }
                race.finish(.failure(DeadlineExceededError(message: message)))
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

private final class DeadlineRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var done = false
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let result: Result<T, Error>? = lock.withLock {
            if let early { return early }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func track(_ task: Task<Void, Never>) {
        let cancelNow = lock.withLock {
            if done { return true }
            tasks.append(task)
            return false
        }
        if cancelNow { task.cancel() }
    }

    func finish(_ result: Result<T, Error>) {
        let (continuation, tasks): (CheckedContinuation<T, Error>?, [Task<Void, Never>]) = lock.withLock {
            guard !done else { return (nil, []) }
            done = true
            let pending = self.continuation
            self.continuation = nil
            if pending == nil { early = result }
            let running = self.tasks
            self.tasks = []
            return (pending, running)
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
