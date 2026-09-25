/// Settings for `DefaultRiskPolicy`. All string sets are matched case-insensitively.
public struct RiskPolicyOptions: Sendable, Equatable {
    /// Only real deletion operations; matched on word boundaries in goals, labels, and typed text.
    public static let defaultProhibitedTerms: Set<String> = [
        "delete",
        "deletion",
        "erase",
        "wipe",
        "destroy",
        "truncate",
        "format",
        "del", // command-line deletion shorthand
        // Shell removal, Finder's Trash, and diskutil erase verbs.
        "rm",
        "rmdir",
        "unlink",
        "shred",
        "srm",
        "move to trash",
        "empty trash",
        "move to bin",
        "empty bin",
        "erasedisk",
        "erasevolume",
    ]

    /// Password managers that are never automated, matched against the app name or bundle identifier.
    public static let defaultDenyListedApps: Set<String> = [
        "1password", "1password 7", "com.1password.1password", "com.agilebits.onepassword7",
        "bitwarden", "com.bitwarden.desktop",
        "keepass", "keepassxc", "org.keepassxc.keepassxc",
        "lastpass", "com.lastpass.lastpass",
        "dashlane", "com.dashlane.dashlane",
        "enpass", "in.sinew.enpass-desktop",
        "authenticator",
        "keychain access", "com.apple.keychainaccess",
        "passwords", "com.apple.passwords",
    ]

    public var prohibitedTerms: Set<String>
    public var denyListedApps: Set<String>

    public init(
        prohibitedTerms: Set<String> = RiskPolicyOptions.defaultProhibitedTerms,
        denyListedApps: Set<String> = RiskPolicyOptions.defaultDenyListedApps
    ) {
        self.prohibitedTerms = prohibitedTerms
        self.denyListedApps = denyListedApps
    }
}
