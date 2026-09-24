import Foundation
import Testing
@testable import ShebangPlatform

@Suite struct PlatformInfoTests {
    @Test func applicationSupportDirectoryIsNamespaced() {
        #expect(PlatformInfo.applicationSupportDirectory.lastPathComponent == "Shebang")
    }
}
