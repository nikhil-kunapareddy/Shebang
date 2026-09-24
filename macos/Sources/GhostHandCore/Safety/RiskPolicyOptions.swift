/// Settings for `DefaultRiskPolicy`. All string sets are matched case-insensitively.
public struct RiskPolicyOptions: Sendable, Equatable {
    /// Intentionally empty: Jarvis mode asks for no confirmation on any safe action.
    public static let defaultSensitiveVerbs: Set<String> = []

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

    /// Carried over from Windows; unused while the policy runs in Jarvis mode.
    public var sensitiveVerbs: Set<String>
    public var prohibitedTerms: Set<String>
    public var denyListedApps: Set<String>
    /// Carried over from Windows; model risk escalation is configured on `AgentLoopOptions`.
    public var escalateOnRiskScore: ActionRiskScore
    /// Disabled: no confirmation prompts for any safe action.
    public var requireConfirmationOnSensitiveText: Bool

    public init(
        sensitiveVerbs: Set<String> = RiskPolicyOptions.defaultSensitiveVerbs,
        prohibitedTerms: Set<String> = RiskPolicyOptions.defaultProhibitedTerms,
        denyListedApps: Set<String> = RiskPolicyOptions.defaultDenyListedApps,
        escalateOnRiskScore: ActionRiskScore = .irreversibleOrExternalEffect,
        requireConfirmationOnSensitiveText: Bool = false
    ) {
        self.sensitiveVerbs = sensitiveVerbs
        self.prohibitedTerms = prohibitedTerms
        self.denyListedApps = denyListedApps
        self.escalateOnRiskScore = escalateOnRiskScore
        self.requireConfirmationOnSensitiveText = requireConfirmationOnSensitiveText
    }
}
