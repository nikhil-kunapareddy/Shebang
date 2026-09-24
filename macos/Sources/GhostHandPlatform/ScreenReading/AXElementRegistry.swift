import ApplicationServices
import Foundation

/// Thread-safe id → AXUIElement cache shared by `AXScreenReader` (writer) and `MacActionExecutor` (reader).
/// The reader rebuilds it on every snapshot so ids always match the latest ranked element list.
public final class AXElementRegistry: @unchecked Sendable {
    public static let shared = AXElementRegistry()

    private let lock = NSLock()
    private var elementsByID: [String: AXUIElement] = [:]
    private var idsByElement: [AXUIElement: String] = [:]
    private var nextIndex = 1

    public init() {}

    public var count: Int {
        lock.withLock { elementsByID.count }
    }

    public func reset() {
        lock.withLock {
            elementsByID.removeAll()
            idsByElement.removeAll()
            nextIndex = 1
        }
    }

    /// Returns the existing id when the same element (CFEqual) is already registered, otherwise the next free `eN`.
    @discardableResult
    public func register(_ element: AXUIElement) -> String {
        lock.withLock {
            if let existing = idsByElement[element] { return existing }
            var id: String
            repeat {
                id = "e\(nextIndex)"
                nextIndex += 1
            } while elementsByID[id] != nil
            elementsByID[id] = element
            idsByElement[element] = id
            return id
        }
    }

    public func element(for id: String) -> AXUIElement? {
        lock.withLock { elementsByID[id] }
    }

    /// Atomically replaces the whole mapping with ids chosen by `ElementRanker` (OCR ids simply have no entry).
    func replaceAll(_ mapping: [String: AXUIElement]) {
        lock.withLock {
            elementsByID = mapping
            idsByElement = Dictionary(mapping.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            let highest = mapping.keys.compactMap { key -> Int? in
                key.hasPrefix("e") ? Int(key.dropFirst()) : nil
            }.max() ?? 0
            nextIndex = highest + 1
        }
    }
}
