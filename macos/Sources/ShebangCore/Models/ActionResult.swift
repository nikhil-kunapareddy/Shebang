import Foundation

public struct ActionResult: Sendable, Equatable {
    public var success: Bool
    public var errorMessage: String?
    public var message: String?
    /// Set when the action launched or switched to a different app/window.
    public var newTarget: AppTarget?

    public init(success: Bool, errorMessage: String? = nil, message: String? = nil, newTarget: AppTarget? = nil) {
        self.success = success
        self.errorMessage = errorMessage
        self.message = message
        self.newTarget = newTarget
    }

    public static func succeeded(message: String? = nil) -> ActionResult {
        ActionResult(success: true, message: message)
    }

    public static func failed(_ error: String) -> ActionResult {
        ActionResult(success: false, errorMessage: error)
    }

    public static func targetChanged(_ target: AppTarget, message: String? = nil) -> ActionResult {
        ActionResult(success: true, message: message, newTarget: target)
    }
}
