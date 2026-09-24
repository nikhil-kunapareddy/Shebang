import Foundation

public struct ActionResult: Sendable, Equatable {
    public var success: Bool
    public var errorMessage: String?
    public var message: String?
    public var duration: TimeInterval
    /// Set when the action launched or switched to a different app/window.
    public var newTarget: AppTarget?

    public init(
        success: Bool,
        errorMessage: String? = nil,
        message: String? = nil,
        duration: TimeInterval = 0,
        newTarget: AppTarget? = nil
    ) {
        self.success = success
        self.errorMessage = errorMessage
        self.message = message
        self.duration = duration
        self.newTarget = newTarget
    }

    public var error: String? { errorMessage }

    public static func succeeded(message: String? = nil, duration: TimeInterval = 0) -> ActionResult {
        ActionResult(success: true, message: message, duration: duration)
    }

    public static func failed(_ error: String, duration: TimeInterval = 0) -> ActionResult {
        ActionResult(success: false, errorMessage: error, duration: duration)
    }

    public static func targetChanged(_ target: AppTarget, message: String? = nil) -> ActionResult {
        ActionResult(success: true, message: message, newTarget: target)
    }
}
