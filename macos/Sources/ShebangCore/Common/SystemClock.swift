import Foundation

public struct SystemClock: Clock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
