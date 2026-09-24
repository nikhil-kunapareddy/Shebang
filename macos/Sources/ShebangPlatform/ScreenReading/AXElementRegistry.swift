import ApplicationServices
import Foundation

/// Thread-safe id → AXUIElement cache shared by `AXScreenReader` (writer) and `MacActionExecutor` (reader).
/// The reader rebuilds it on every snapshot so ids always match the latest ranked element list.
public final class AXElementRegistry: @unchecked Sendable {
    public static let shared = AXElementRegistry()

    private let lock = NSLock()
    private var elementsByID: [String: AXUIElement] = [:]

    public init() {}

    public func element(for id: String) -> AXUIElement? {
        lock.withLock { elementsByID[id] }
    }

    /// Atomically replaces the whole mapping with ids chosen by `ElementRanker` (OCR ids simply have no entry).
    func replaceAll(_ mapping: [String: AXUIElement]) {
        lock.withLock { elementsByID = mapping }
    }
}
