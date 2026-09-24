import Foundation

// Wire format of the Vercel AI Gateway `/v1/evaluate` endpoint. Property names are the JSON keys;
// nil optionals are omitted when encoding.

public struct EvaluateRequest: Codable, Sendable, Equatable {
    public var model: String
    /// Free-form, text-only screen state. Never include secrets.
    public var state: JevJSON
    public var questions: [String: QuestionDefinition]
    public var providerOptions: GatewayProviderOptions?

    public init(
        model: String,
        state: JevJSON,
        questions: [String: QuestionDefinition],
        providerOptions: GatewayProviderOptions? = nil
    ) {
        self.model = model
        self.state = state
        self.questions = questions
        self.providerOptions = providerOptions
    }
}

public struct QuestionDefinition: Codable, Sendable, Equatable {
    /// `"boolean"`, `"choice"`, or `"score"`.
    public var type: String
    public var instructions: String?
    public var criteria: Criteria?

    /// Choice criteria map option keys to descriptions; score criteria are ordered lowest to highest.
    public enum Criteria: Codable, Sendable, Equatable {
        case choices([String: String])
        case ordered([String])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let choices = try? container.decode([String: String].self) {
                self = .choices(choices)
            } else {
                self = .ordered(try container.decode([String].self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .choices(let choices): try container.encode(choices)
            case .ordered(let ordered): try container.encode(ordered)
            }
        }
    }

    public init(type: String, instructions: String? = nil, criteria: Criteria? = nil) {
        self.type = type
        self.instructions = instructions
        self.criteria = criteria
    }

    public static func boolean(_ instructions: String) -> QuestionDefinition {
        QuestionDefinition(type: "boolean", instructions: instructions)
    }

    public static func choice(_ criteria: [String: String], instructions: String? = nil) -> QuestionDefinition {
        QuestionDefinition(type: "choice", instructions: instructions, criteria: .choices(criteria))
    }

    public static func score(_ orderedCriteria: [String], instructions: String? = nil) -> QuestionDefinition {
        QuestionDefinition(type: "score", instructions: instructions, criteria: .ordered(orderedCriteria))
    }
}

public struct GatewayProviderOptions: Codable, Sendable, Equatable {
    public var gateway: GatewayOptions?

    public init(gateway: GatewayOptions? = nil) {
        self.gateway = gateway
    }
}

public struct GatewayOptions: Codable, Sendable, Equatable {
    /// Sent only as `true`; leave nil to use the account default.
    public var zeroDataRetention: Bool?
    /// Restricts routing to the listed providers.
    public var only: [String]?

    public init(zeroDataRetention: Bool? = nil, only: [String]? = nil) {
        self.zeroDataRetention = zeroDataRetention
        self.only = only
    }
}

// MARK: - Response

/// Keys are matched case-insensitively; unknown keys are ignored.
public struct EvaluateResponse: Decodable, Sendable, Equatable {
    public var answers: [String: JevJSON]
    public var usage: UsageInfo?
    public var providerMetadata: ProviderMetadataInfo?

    public struct BooleanAnswer: Sendable, Equatable {
        public var probability: Double
        public var isTrue: Bool
    }

    public struct ChoiceAnswer: Sendable, Equatable {
        public var choice: String
        /// Probability of `choice`, or 0 when the gateway did not report it.
        public var confidence: Double
        public var probabilities: [String: Double]
    }

    public struct ScoreAnswer: Sendable, Equatable {
        public var score: Int
        public var probabilities: [Double]
    }

    public init(answers: [String: JevJSON] = [:], usage: UsageInfo? = nil, providerMetadata: ProviderMetadataInfo? = nil) {
        self.answers = answers
        self.usage = usage
        self.providerMetadata = providerMetadata
    }

    public init(from decoder: Decoder) throws {
        let object = try LenientObject(decoder)
        answers = try object.decode([String: JevJSON].self, "answers") ?? [:]
        usage = try object.decode(UsageInfo.self, "usage")
        providerMetadata = try object.decode(ProviderMetadataInfo.self, "providerMetadata")
    }

    /// `{"probability": p}`; true when p >= 0.5. Probabilities outside [0, 1] are treated as unparseable.
    public func booleanAnswer(_ questionName: String) -> BooleanAnswer? {
        guard let probability = answers[questionName]?["probability"]?.doubleValue,
              Self.isProbability(probability)
        else { return nil }
        return BooleanAnswer(probability: probability, isTrue: probability >= 0.5)
    }

    /// `{"choice": key, "probabilities": {key: p}}`; nil when no choice was made.
    public func choiceAnswer(_ questionName: String) -> ChoiceAnswer? {
        guard let answer = answers[questionName]?.objectValue else { return nil }
        let choice = answer["choice"]?.stringValue ?? ""
        let probabilities = (answer["probabilities"]?.objectValue ?? [:])
            .compactMapValues(\.doubleValue)
            .filter { Self.isProbability($0.value) }
        guard !choice.isEmpty else { return nil }
        // Offered keys are matched case-insensitively later, so look the confidence up the same way.
        let confidence = probabilities[choice]
            ?? probabilities.first { $0.key.caseInsensitiveCompare(choice) == .orderedSame }?.value
            ?? 0
        return ChoiceAnswer(choice: choice, confidence: confidence, probabilities: probabilities)
    }

    private static func isProbability(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    /// `{"score": n, "probabilities": [p0, p1, ...]}`. Present whenever the answer object exists
    /// (score 0 when missing); fractional scores round half to even, numeric strings are accepted.
    public func scoreAnswer(_ questionName: String) -> ScoreAnswer? {
        guard let answer = answers[questionName]?.objectValue else { return nil }
        var score = 0
        switch answer["score"] {
        case .int(let value)?:
            score = value
        case .double(let value)?:
            score = Int(exactly: value.rounded(.toNearestOrEven)) ?? 0
        case .string(let text)?:
            score = Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
        default:
            break
        }
        let probabilities = (answer["probabilities"]?.arrayValue ?? []).compactMap(\.doubleValue)
        return ScoreAnswer(score: score, probabilities: probabilities)
    }
}

public struct UsageInfo: Decodable, Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int

    public init(from decoder: Decoder) throws {
        let object = try LenientObject(decoder)
        promptTokens = object.int("promptTokens")
        completionTokens = object.int("completionTokens")
        totalTokens = object.int("totalTokens")
    }
}

public struct ProviderMetadataInfo: Decodable, Sendable, Equatable {
    public var gateway: GatewayMetadata?

    public init(from decoder: Decoder) throws {
        let object = try LenientObject(decoder)
        gateway = try object.decode(GatewayMetadata.self, "gateway")
    }
}

public struct GatewayMetadata: Decodable, Sendable, Equatable {
    /// The gateway reports cost as a number or a numeric string.
    public var rawCost: JevJSON?

    public init(from decoder: Decoder) throws {
        let object = try LenientObject(decoder)
        rawCost = try object.decode(JevJSON.self, "cost")
    }

    /// Cost in USD, or nil when absent or not numeric.
    public var cost: Double? {
        switch rawCost {
        case .int(let value)?: return Double(value)
        case .double(let value)?: return value
        case .string(let text)?: return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

// MARK: - Decoding helpers

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

/// A JSON object whose property names are matched case-insensitively.
private struct LenientObject {
    private let container: KeyedDecodingContainer<AnyCodingKey>

    init(_ decoder: Decoder) throws {
        container = try decoder.container(keyedBy: AnyCodingKey.self)
    }

    private func key(_ name: String) -> AnyCodingKey? {
        let exact = AnyCodingKey(name)
        if container.contains(exact) { return exact }
        return container.allKeys.first { $0.stringValue.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// nil when the member is missing or JSON null; throws when present with the wrong shape.
    func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        guard let key = key(name), try !container.decodeNil(forKey: key) else { return nil }
        return try container.decode(T.self, forKey: key)
    }

    /// Token counts: any number is accepted and rounded; anything else reads as 0.
    func int(_ name: String) -> Int {
        guard let value = ((try? decode(JevJSON.self, name)) ?? nil)?.doubleValue else { return 0 }
        return Int(exactly: value.rounded()) ?? 0
    }
}
