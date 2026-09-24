import Testing
@testable import GhostHandApp

@Suite struct AppSmokeTests {
    @Test func appModuleLinks() {
        #expect(GhostHandApp.self is Any.Type)
    }
}
