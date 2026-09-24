import Foundation
import Testing
@testable import GhostHandPlatform

@Suite struct PlatformInfoTests {
    @Test func applicationSupportDirectoryIsNamespaced() {
        #expect(PlatformInfo.applicationSupportDirectory.lastPathComponent == "GhostHand")
    }
}
