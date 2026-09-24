import Foundation

/// HTTP client for `POST {baseURL}/v1/evaluate` on Vercel AI Gateway.
///
/// Timeouts, network failures, 429 and 5xx are retried up to `maxRetries` times with exponential
/// backoff (500 ms, 1 s, 2 s, ... plus up to 250 ms jitter) slept on the injected `Clock`.
/// 401/403 and other 4xx responses fail immediately.
public final class JevClient: JevEvaluating, Sendable {
    private let options: JevOptions
    private let session: URLSession
    private let clock: any Clock

    public init(options: JevOptions, session: URLSession = .shared, clock: Clock = SystemClock()) {
        self.options = options
        self.session = session
        self.clock = clock
    }

    /// `baseURL` without trailing slashes, plus `/v1/evaluate`.
    var endpoint: URL? {
        var base = options.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/v1/evaluate")
    }

    public func evaluate(_ request: EvaluateRequest) async throws -> EvaluateResponse {
        guard let apiKey = options.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw JevError.auth(
                statusCode: 401,
                message: "API key is not configured. Set AI_GATEWAY_API_KEY in .env, the environment, or the Keychain.")
        }
        guard let url = endpoint, url.scheme != nil, url.host != nil else {
            throw JevError.protocolError(message: "Invalid AI Gateway base URL: \(options.baseURL)")
        }

        let body = try Self.encodeBody(request)

        var attempts = 0
        var attemptStart = clock.now

        while true {
            try Task.checkCancellation()
            attempts += 1

            var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                        timeoutInterval: options.timeoutSeconds)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = body
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await send(urlRequest)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    Log.jev.info("Jev request was cancelled by kill switch / task cancellation.")
                    throw CancellationError()
                }
                if error is AttemptTimedOut || (error as? URLError)?.code == .timedOut {
                    Log.jev.warning("Jev request timed out after \(self.options.timeoutSeconds) seconds.")
                    if attempts <= options.maxRetries {
                        try await backoff(after: attempts)
                        continue
                    }
                    throw JevError.transient(statusCode: 408, message: "Request timed out after max retries.")
                }
                let reason = Self.redact(error.localizedDescription, apiKey: apiKey)
                Log.jev.warning("HTTP network transport failure on attempt \(attempts): \(reason, privacy: .public)")
                if attempts <= options.maxRetries {
                    try await backoff(after: attempts)
                    continue
                }
                throw JevError.transient(statusCode: 0, message: "Network failure: \(reason)")
            }

            let latencyMs = Int(clock.now.timeIntervalSince(attemptStart) * 1000)
            guard let http = response as? HTTPURLResponse else {
                throw JevError.protocolError(message: "Gateway returned a non-HTTP response.")
            }
            let status = http.statusCode

            if (200..<300).contains(status) {
                return try decodeResponse(data, latencyMs: latencyMs, apiKey: apiKey)
            }

            let detail = Self.redact(String(decoding: data, as: UTF8.self), apiKey: apiKey)

            // 401 / 403: authentication errors are never retried.
            if status == 401 || status == 403 {
                Log.jev.error("Authentication rejected by Gateway (HTTP \(status))")
                throw JevError.auth(statusCode: status, message: detail)
            }

            // Other 4xx (bad request, not found, ...) are not retried.
            if (400..<500).contains(status) && status != 429 {
                Log.jev.error("Client error from Gateway (HTTP \(status)): \(detail, privacy: .private)")
                throw JevError.protocolError(message: "Client request rejected (HTTP \(status)): \(detail)")
            }

            // 429 (rate limit) or 5xx: retry with exponential backoff and jitter.
            if attempts <= options.maxRetries {
                Log.jev.warning(
                    "Transient gateway error (HTTP \(status)). Retrying attempt \(attempts + 1)/\(self.options.maxRetries)...")
                try await backoff(after: attempts)
                attemptStart = clock.now
                continue
            }

            Log.jev.error("Exhausted retries on transient error (HTTP \(status)): \(detail, privacy: .private)")
            throw JevError.transient(statusCode: status, message: detail)
        }
    }

    /// Sends a one-question diagnostic request and returns a one-line summary (used by `ghosthand check`).
    public func checkConnection() async throws -> String {
        let timestamp = ISO8601DateFormatter.string(
            from: clock.now, timeZone: TimeZone(identifier: "UTC")!,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        let request = EvaluateRequest(
            model: options.modelId,
            state: [
                "system": "GhostHand macOS Diagnostic",
                "status": "Testing connectivity to Vercel AI Gateway",
                "timestamp": .string(timestamp),
            ],
            questions: ["operational": .boolean("Is this connection active and ready for evaluation?")],
            providerOptions: GatewayProviderOptions(gateway: GatewayOptions(
                zeroDataRetention: options.zeroDataRetention ? true : nil,
                only: ["typesafe-ai"])))

        let start = clock.now
        let response = try await evaluate(request)
        let latencyMs = Int(clock.now.timeIntervalSince(start) * 1000)

        var parts = ["Jev reachable at \(options.baseURL) (model \(options.modelId)) in \(latencyMs) ms"]
        if let answer = response.booleanAnswer("operational") {
            parts.append("operational: \(answer.isTrue) (\(String(format: "%.1f%%", answer.probability * 100)))")
        }
        if let usage = response.usage {
            parts.append("tokens: \(usage.totalTokens) (prompt \(usage.promptTokens), completion \(usage.completionTokens))")
        }
        if let cost = response.providerMetadata?.gateway?.cost {
            parts.append(String(format: "cost: $%.6f", cost))
        }
        return parts.joined(separator: " | ")
    }

    /// The exact request body sent on the wire (sorted keys for deterministic output).
    static func encodeBody(_ request: EvaluateRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(request)
        } catch {
            throw JevError.protocolError(message: "Failed to encode evaluate request: \(describe(error))")
        }
    }

    // MARK: - Private

    private struct AttemptTimedOut: Error {}

    /// Races the request against `timeoutSeconds` so the limit covers the whole exchange,
    /// not just idle time between packets.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let session = self.session
        let nanoseconds = UInt64(min(max(options.timeoutSeconds, 0), 86_400) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: (Data, URLResponse)?.self) { group in
            group.addTask { try await session.data(for: request) }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() ?? nil else { throw AttemptTimedOut() }
            return result
        }
    }

    private func decodeResponse(_ data: Data, latencyMs: Int, apiKey: String) throws -> EvaluateResponse {
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else {
            throw JevError.protocolError(message: "Received null or empty evaluate response from Gateway.")
        }
        do {
            let result = try JSONDecoder().decode(EvaluateResponse.self, from: data)
            let cost = result.providerMetadata?.gateway?.cost.map { String(format: "$%.6f", $0) } ?? "N/A"
            Log.jev.info("Jev evaluation completed in \(latencyMs)ms | Cost: \(cost, privacy: .public)")
            return result
        } catch {
            Log.jev.error("Failed to parse evaluate response JSON: \(Self.redact(text, apiKey: apiKey), privacy: .private)")
            throw JevError.protocolError(message: "Failed to parse Gateway response: \(Self.describe(error))")
        }
    }

    private func backoff(after attempt: Int) async throws {
        let baseMs = Int(pow(2.0, Double(min(max(attempt - 1, 0), 16))) * 500)
        let jitterMs = Int.random(in: 0..<250)
        try await clock.sleep(seconds: Double(baseMs + jitterMs) / 1000)
    }

    private static let maxDetailLength = 1_000

    /// Removes the configured key and token patterns from gateway text and bounds its length.
    static func redact(_ text: String, apiKey: String) -> String {
        var safe = apiKey.isEmpty ? text : text.replacingOccurrences(of: apiKey, with: "[REDACTED]")
        safe = JevError.sanitize(safe)
        return safe.count > maxDetailLength ? String(safe.prefix(maxDetailLength)) + "..." : safe
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context),
             DecodingError.keyNotFound(_, let context),
             DecodingError.typeMismatch(_, let context),
             DecodingError.valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(context.debugDescription) (at \(path))"
        case EncodingError.invalidValue(_, let context):
            return context.debugDescription
        default:
            return error.localizedDescription
        }
    }
}
