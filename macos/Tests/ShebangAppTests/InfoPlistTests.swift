import Foundation
import Testing
@testable import ShebangApp

@Suite struct InfoPlistTests {
    private var infoPlist: [String: Any] {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Info.plist")
            let data = try Data(contentsOf: url)
            return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
    }

    @Test func singleInstanceUsesTheBundleIdentifier() throws {
        #expect(try infoPlist["CFBundleIdentifier"] as? String == SingleInstance.bundleIdentifier)
    }

    @Test func bundleIsAMenuBarAppWithUsageStrings() throws {
        let plist = try infoPlist
        #expect(plist["LSUIElement"] as? Bool == true)
        for key in ["NSAccessibilityUsageDescription", "NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            #expect((plist[key] as? String)?.isEmpty == false, "\(key) missing")
        }
    }
}
