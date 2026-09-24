import ApplicationServices
import Foundation
import Testing
@testable import GhostHandPlatform

@Suite struct AXElementRegistryTests {
    private func handle(_ n: Int32) -> AXUIElement { AXUIElementCreateApplication(2_100_000_000 + n) }

    @Test func registersSequentialIdsAndReusesExistingOnes() {
        let registry = AXElementRegistry()
        let a = handle(1), b = handle(2)
        #expect(registry.register(a) == "e1")
        #expect(registry.register(b) == "e2")
        #expect(registry.register(handle(1)) == "e1")  // CFEqual element keeps its id
        #expect(registry.element(for: "e2") == b)
        #expect(registry.count == 2)
    }

    @Test func resetClearsEverything() {
        let registry = AXElementRegistry()
        registry.register(handle(1))
        registry.reset()
        #expect(registry.count == 0)
        #expect(registry.element(for: "e1") == nil)
        #expect(registry.register(handle(3)) == "e1")
    }

    @Test func replaceAllInstallsRankerIdsAndContinuesNumbering() {
        let registry = AXElementRegistry()
        registry.register(handle(9))
        registry.replaceAll(["e1": handle(1), "e3": handle(3)])  // e2 is an OCR element with no AX handle
        #expect(registry.element(for: "e1") == handle(1))
        #expect(registry.element(for: "e2") == nil)
        #expect(registry.element(for: "e3") == handle(3))
        #expect(registry.register(handle(3)) == "e3")
        #expect(registry.register(handle(4)) == "e4")
    }

    @Test func concurrentRegistrationIsThreadSafe() async {
        let registry = AXElementRegistry()
        let ids = await withTaskGroup(of: String.self) { group in
            for n in 0..<200 {
                group.addTask { registry.register(AXUIElementCreateApplication(2_100_001_000 + Int32(n % 100))) }
            }
            var collected: [String] = []
            for await id in group { collected.append(id) }
            return collected
        }
        #expect(ids.count == 200)
        #expect(Set(ids).count == 100)
        #expect(registry.count == 100)
    }
}
