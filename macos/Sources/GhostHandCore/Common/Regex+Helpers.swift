import Foundation

extension NSRegularExpression {
    /// Compiles a pattern known to be valid at build time.
    convenience init(literal pattern: String, options: NSRegularExpression.Options = []) {
        do {
            try self.init(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid regex \(pattern): \(error)")
        }
    }

    func firstMatch(in text: String) -> NSTextCheckingResult? {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    func matches(in text: String) -> [NSTextCheckingResult] {
        matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    func replacingMatches(in text: String, with template: String) -> String {
        stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

extension NSTextCheckingResult {
    /// Text of capture group `index`, or nil when the group did not participate in the match.
    func group(_ index: Int, in text: String) -> String? {
        guard index < numberOfRanges, let range = Range(range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}

extension String {
    /// Percent-encodes everything except RFC 3986 unreserved characters (matches .NET `Uri.EscapeDataString`).
    var escapedDataString: String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
