import ApplicationServices
import Foundation
import Testing
@testable import ShebangPlatform

@Suite struct AXElementRegistryTests {
    private func handle(_ n: Int32) -> AXUIElement { AXUIElementCreateApplication(2_100_000_000 + n) }

    @Test func replaceAllInstallsRankerIds() {
        let registry = AXElementRegistry()
        registry.replaceAll(["e1": handle(1), "e3": handle(3)])  // e2 is an OCR element with no AX handle
        #expect(registry.element(for: "e1") == handle(1))
        #expect(registry.element(for: "e2") == nil)
        #expect(registry.element(for: "e3") == handle(3))
    }

    @Test func replaceAllDropsThePreviousSnapshot() {
        let registry = AXElementRegistry()
        registry.replaceAll(["e1": handle(1), "e2": handle(2)])
        registry.replaceAll(["e1": handle(5)])
        #expect(registry.element(for: "e1") == handle(5))
        #expect(registry.element(for: "e2") == nil)
    }

    @Test func concurrentReadsAndWritesAreThreadSafe() async {
        let registry = AXElementRegistry()
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<200 {
                group.addTask {
                    if n.isMultiple(of: 2) {
                        registry.replaceAll(["e1": AXUIElementCreateApplication(2_100_001_000 + Int32(n))])
                    } else {
                        _ = registry.element(for: "e1")
                    }
                }
            }
        }
        #expect(registry.element(for: "e1") != nil)
    }
}
