import CoreGraphics
import Foundation

/// Information about the frontmost / target application and its active window.
public struct AppTarget: Sendable, Equatable, Codable {
    public var processId: Int32
    /// Localized application name, e.g. `Safari`, `Notes`.
    public var processName: String
    public var bundleIdentifier: String
    public var executablePath: String
    public var windowTitle: String
    /// `CGWindowID` of the target window; 0 when unknown. The macOS analogue of a Windows HWND.
    public var windowNumber: Int
    /// Window frame in global screen coordinates (top-left origin).
    public var windowBounds: CGRect

    public init(
        processId: Int32,
        processName: String,
        bundleIdentifier: String = "",
        executablePath: String = "",
        windowTitle: String = "",
        windowNumber: Int = 0,
        windowBounds: CGRect = .zero
    ) {
        self.processId = processId
        self.processName = processName
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.windowTitle = windowTitle
        self.windowNumber = windowNumber
        self.windowBounds = windowBounds
    }

    public var bounds: CGRect { windowBounds }
}
