import Foundation

/// Connection and decision settings for the Jev model on Vercel AI Gateway.
public struct JevOptions: Sendable, Equatable {
    public var baseURL: String
    public var modelId: String
    public var apiKey: String?
    public var zeroDataRetention: Bool
    /// Total time allowed for one HTTP attempt, including reading the response body.
    public var timeoutSeconds: TimeInterval
    /// Retries after the first attempt for timeouts, network failures, 429 and 5xx responses.
    public var maxRetries: Int
    /// Minimum probability for Jev's chosen action (and goal-achieved answers); below it the model asks the user.
    /// The default of 0 disables the gate.
    public var decisionConfidenceThreshold: Double

    public init(
        baseURL: String = "https://ai-gateway.vercel.sh",
        modelId: String = "typesafe-ai/jev",
        apiKey: String? = nil,
        zeroDataRetention: Bool = false,
        timeoutSeconds: TimeInterval = 30,
        maxRetries: Int = 4,
        decisionConfidenceThreshold: Double = 0.0
    ) {
        self.baseURL = baseURL
        self.modelId = modelId
        self.apiKey = apiKey
        self.zeroDataRetention = zeroDataRetention
        self.timeoutSeconds = timeoutSeconds
        self.maxRetries = maxRetries
        self.decisionConfidenceThreshold = decisionConfidenceThreshold
    }

    /// Reads `AI_GATEWAY_BASE_URL`, `JEV_MODEL`, `AI_GATEWAY_API_KEY`, `ZERO_DATA_RETENTION` and
    /// `DECISION_CONFIDENCE_THRESHOLD`. Blank or unparseable values keep the defaults.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> JevOptions {
        var options = JevOptions()

        func value(_ name: String) -> String? {
            guard let raw = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }

        if let baseURL = value("AI_GATEWAY_BASE_URL") { options.baseURL = baseURL }
        if let model = value("JEV_MODEL") { options.modelId = model }
        if let key = value("AI_GATEWAY_API_KEY") { options.apiKey = key }

        // Only "true"/"false", case-insensitive.
        if let zdr = parseBool(value("ZERO_DATA_RETENTION")) {
            options.zeroDataRetention = zdr
        }
        if let threshold = value("DECISION_CONFIDENCE_THRESHOLD").flatMap(Double.init) {
            options.decisionConfidenceThreshold = threshold
        }
        return options
    }

    private static func parseBool(_ raw: String?) -> Bool? {
        switch raw?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}
