import Foundation
import GhostHandCore

public enum PlatformInfo {
    /// Where local state (audit log, .env) lives.
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GhostHand", isDirectory: true)
    }
}
