import Foundation

public enum SecretSanitizer {
    // Credit card numbers: 13-16 digits with optional spaces or dashes.
    private static let cardRegex = NSRegularExpression(
        literal: #"\b(?:\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{1,4}|\d{13,16})\b"#)

    // API keys and tokens: vck_*, sk-*, ghp_*, eyJ* (JWT).
    private static let apiKeyRegex = NSRegularExpression(
        literal: #"\b(?:vck_[a-zA-Z0-9_-]{10,}|sk-[a-zA-Z0-9_-]{20,}|ghp_[a-zA-Z0-9]{25,}|eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{10,})\b"#)

    // Bearer authorization headers.
    private static let bearerRegex = NSRegularExpression(
        literal: #"(Bearer\s+)[a-zA-Z0-9_\-\.]{15,}"#, options: .caseInsensitive)

    public static func sanitize(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }

        var sanitized = cardRegex.replacingMatches(in: text, with: "[REDACTED_CARD]")
        sanitized = apiKeyRegex.replacingMatches(in: sanitized, with: "[REDACTED_KEY]")
        sanitized = bearerRegex.replacingMatches(in: sanitized, with: "$1[REDACTED]")
        return sanitized
    }
}
