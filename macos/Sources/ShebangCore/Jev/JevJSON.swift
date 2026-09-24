import Foundation

/// Untyped JSON used for the free-form `state` of a request and for raw answers.
///
/// Object members whose value is `.null` are omitted when encoding.
public enum JevJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JevJSON])
    case object([String: JevJSON])

    public subscript(key: String) -> JevJSON? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public subscript(index: Int) -> JevJSON? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Numeric value of `.int` or `.double`.
    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var arrayValue: [JevJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectValue: [String: JevJSON]? {
        if case .object(let members) = self { return members }
        return nil
    }
}

extension JevJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JevJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JevJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let items): try container.encode(items)
        case .object(let members): try container.encode(members.filter { $0.value != .null })
        }
    }
}

extension JevJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JevJSON...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }

    public init(dictionaryLiteral elements: (String, JevJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
