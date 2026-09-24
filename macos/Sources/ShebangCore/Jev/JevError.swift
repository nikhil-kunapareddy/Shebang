import Foundation

/// Failures from the Jev gateway. Messages are scrubbed of bearer tokens and `vck_` keys.
public enum JevError: Error, LocalizedError, Equatable {
    /// Missing API key, or HTTP 401/403. Never retried.
    case auth(statusCode: Int, message: String)
    /// Timeout (408), network failure (0), 429 or 5xx after retries were exhausted.
    case transient(statusCode: Int, message: String)
    /// Rejected request (other 4xx), unreadable response, or unencodable request.
    case protocolError(message: String)

    public var statusCode: Int? {
        switch self {
        case .auth(let code, _), .transient(let code, _): return code
        case .protocolError: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .auth(let code, let message):
            return "Authentication failed (HTTP \(code)): \(Self.sanitize(message))"
        case .transient(let code, let message):
            return "Transient gateway error (HTTP \(code)): \(Self.sanitize(message))"
        case .protocolError(let message):
            return "Protocol / serialization error: \(Self.sanitize(message))"
        }
    }

    private static let bearerRegex = NSRegularExpression(literal: #"(?i)(bearer\s+)([a-zA-Z0-9_\-\.]{8,})"#)
    private static let gatewayKeyRegex = NSRegularExpression(literal: #"(vck_[a-zA-Z0-9_\-]{8,})"#)

    /// Redacts bearer tokens and Vercel gateway keys (`vck_...`).
    static func sanitize(_ message: String) -> String {
        guard !message.isEmpty else { return message }
        let withoutBearer = bearerRegex.replacingMatches(in: message, with: "$1[REDACTED]")
        return gatewayKeyRegex.replacingMatches(in: withoutBearer, with: "[REDACTED]")
    }
}
