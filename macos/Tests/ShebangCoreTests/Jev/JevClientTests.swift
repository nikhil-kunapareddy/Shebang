import Foundation
import Testing
@testable import ShebangCore

@Suite struct JevClientTests {
    // MARK: - Wire format

    @Test func jv01RequestJSONMatchesSchema() throws {
        let request = EvaluateRequest(
            model: "typesafe-ai/jev",
            state: ["goal": "search for Adele", "app": "Spotify"],
            questions: [
                "done": .boolean("Has task finished?"),
                "action": .choice(["click:e1": "Click search", "type:e2": "Type text"]),
            ],
            providerOptions: GatewayProviderOptions(gateway: GatewayOptions(zeroDataRetention: true)))

        let json = String(decoding: try JevClient.encodeBody(request), as: UTF8.self)

        #expect(json.contains(#""model":"typesafe-ai/jev""#))
        #expect(json.contains(#""state":{"#))
        #expect(json.contains(#""questions":{"#))
        #expect(json.contains(#""type":"boolean""#))
        #expect(json.contains(#""type":"choice""#))
        #expect(json.contains(#""zeroDataRetention":true"#))
        #expect(json.contains(#""criteria":{"click:e1":"Click search","type:e2":"Type text"}"#))
    }

    @Test func nilValuesAreOmittedLikeWhenWritingNull() throws {
        let request = EvaluateRequest(
            model: "m",
            state: ["kept": "yes", "dropped": nil],
            questions: [
                "done": .boolean("Finished?"),
                "pick": .choice(["a": "A"]),
                "risk": .score(["low", "high"], instructions: "Rate it"),
            ],
            providerOptions: GatewayProviderOptions(gateway: GatewayOptions()))

        let object = try #require(try JSONSerialization.jsonObject(with: JevClient.encodeBody(request)) as? [String: Any])
        let questions = try #require(object["questions"] as? [String: [String: Any]])

        #expect(!String(decoding: try JevClient.encodeBody(request), as: UTF8.self).contains("null"))
        #expect((object["state"] as? [String: Any])?.keys.sorted() == ["kept"])
        #expect(questions["done"]?.keys.sorted() == ["instructions", "type"])
        #expect(questions["pick"]?.keys.sorted() == ["criteria", "type"])
        #expect(questions["risk"]?["criteria"] as? [String] == ["low", "high"])
        // An empty gateway object is still sent, as in the Windows build.
        #expect((object["providerOptions"] as? [String: Any])?["gateway"] as? [String: Any] != nil)
        #expect(((object["providerOptions"] as? [String: Any])?["gateway"] as? [String: Any])?.isEmpty == true)

        let bare = try JevClient.encodeBody(EvaluateRequest(model: "m", state: [:], questions: [:]))
        #expect(String(decoding: bare, as: UTF8.self) == #"{"model":"m","questions":{},"state":{}}"#)
    }

    @Test func requestRoundTripsThroughCodable() throws {
        let request = EvaluateRequest(
            model: "typesafe-ai/jev",
            state: ["step": 2, "elements": [["id": "e1", "enabled": true]], "ratio": 0.5],
            questions: ["risk": .score(["a", "b", "c"]), "pick": .choice(["x": "X"], instructions: "Pick")],
            providerOptions: GatewayProviderOptions(gateway: GatewayOptions(zeroDataRetention: true, only: ["typesafe-ai"])))
        let decoded = try JSONDecoder().decode(EvaluateRequest.self, from: JevClient.encodeBody(request))
        #expect(decoded == request)
    }

    // MARK: - Response parsing

    @Test func jv02BooleanChoiceScoreAnswersParseCorrectly() throws {
        let response = try decodeJevResponse("""
        {
            "answers": {
                "goalDone": { "type": "boolean", "probability": 0.88 },
                "nextOp": {
                    "type": "choice",
                    "choice": "click:btn_search",
                    "probabilities": { "click:btn_search": 0.91, "press:enter": 0.09 }
                },
                "riskLevel": { "type": "score", "score": 1, "probabilities": [0.10, 0.85, 0.05] }
            },
            "usage": { "promptTokens": 100, "completionTokens": 20, "totalTokens": 120 },
            "providerMetadata": { "gateway": { "cost": 0.000045, "provider": "typesafe-ai" } }
        }
        """)

        let boolean = try #require(response.booleanAnswer("goalDone"))
        #expect(boolean.probability == 0.88)
        #expect(boolean.isTrue)

        let choice = try #require(response.choiceAnswer("nextOp"))
        #expect(choice.choice == "click:btn_search")
        #expect(choice.confidence == 0.91)
        #expect(choice.probabilities["press:enter"] == 0.09)

        let score = try #require(response.scoreAnswer("riskLevel"))
        #expect(score.score == 1)
        #expect(score.probabilities.count == 3)
        #expect(score.probabilities[1] == 0.85)

        #expect(response.usage?.totalTokens == 120)
        #expect(response.providerMetadata?.gateway?.cost == 0.000045)
        #expect(response.providerMetadata?.gateway?.provider == "typesafe-ai")
    }

    @Test func responseParsingIsLenientLikeTheWindowsDeserializer() throws {
        let response = try decodeJevResponse("""
        {
            "Answers": {
                "b": { "probability": 1 },
                "low": { "probability": 0.2 },
                "c": { "choice": "x" },
                "empty": { "choice": "", "probabilities": { "x": 1 } },
                "half": { "score": 2.5 },
                "text": { "score": "3", "probabilities": [0.1, "bad", 0.9] },
                "noScore": {},
                "flat": 0.9
            },
            "providerMetadata": { "gateway": { "cost": "0.0012", "generationId": "gen_1", "extra": true } },
            "id": "resp_1"
        }
        """)

        #expect(response.booleanAnswer("b") == .init(probability: 1, isTrue: true))
        #expect(response.booleanAnswer("low")?.isTrue == false)
        #expect(response.booleanAnswer("flat") == nil)
        #expect(response.booleanAnswer("missing") == nil)
        #expect(response.choiceAnswer("c") == .init(choice: "x", confidence: 0, probabilities: [:]))
        #expect(response.choiceAnswer("empty") == nil)
        #expect(response.scoreAnswer("half")?.score == 2)  // banker's rounding, like Math.Round
        #expect(response.scoreAnswer("text") == .init(score: 3, probabilities: [0.1, 0.9]))
        #expect(response.scoreAnswer("noScore") == .init(score: 0, probabilities: []))
        #expect(response.scoreAnswer("flat") == nil)
        #expect(response.providerMetadata?.gateway?.cost == 0.0012)
        #expect(response.providerMetadata?.gateway?.generationId == "gen_1")
        #expect(response.providerMetadata?.gateway?.additionalData?["extra"] == .bool(true))
        #expect(response.additionalData == ["id": "resp_1"])
        #expect(response.usage == nil)
    }

    // MARK: - HTTP behaviour

    @Test func sendsBearerAuthJSONBodyToEvaluateEndpoint() async throws {
        let stub = JevStubbedClient(host: "ai-gateway.vercel.sh", configure: { $0.baseURL = "https://ai-gateway.vercel.sh//" }) { _, _ in
            .respond(status: 200, body: #"{"answers":{"done":{"probability":0.9}}}"#)
        }
        defer { JevStubURLProtocol.unregister(host: stub.host) }
        let request = EvaluateRequest(
            model: "typesafe-ai/jev",
            state: ["task": "Play Skyfall"],
            questions: ["done": .boolean("Done?")],
            providerOptions: GatewayProviderOptions(gateway: GatewayOptions(only: ["typesafe-ai"])))

        let response = try await stub.client.evaluate(request)

        #expect(response.booleanAnswer("done")?.isTrue == true)
        let sent = try #require(stub.route.captured.first)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/evaluate")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(jevTestAPIKey)")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
        #expect(sent.body == (try JevClient.encodeBody(request)))
        #expect(try JSONDecoder().decode(EvaluateRequest.self, from: sent.body) == request)
    }

    @Test(arguments: [401, 403])
    func jv03AuthFailuresThrowWithoutRetrying(status: Int) async throws {
        let stub = JevStubbedClient { _, _ in .respond(status: status, body: "Invalid API key") }
        defer { JevStubURLProtocol.unregister(host: stub.host) }

        await #expect(throws: JevError.auth(statusCode: status, message: "Invalid API key")) {
            try await stub.client.evaluate(jevTestRequest)
        }
        #expect(stub.route.callCount == 1)
        #expect(stub.clock.sleeps.isEmpty)
    }

    @Test func jv04ServerErrorRetriesWithBackoffThenThrowsTransient() async throws {
        let stub = JevStubbedClient(maxRetries: 2) { _, _ in .respond(status: 500, body: "Internal server error") }
        defer { JevStubURLProtocol.unregister(host: stub.host) }

        await #expect(throws: JevError.transient(statusCode: 500, message: "Internal server error")) {
            try await stub.client.evaluate(jevTestRequest)
        }
        // Initial attempt + 2 retries.
        #expect(stub.route.callCount == 3)
        let sleeps = stub.clock.sleeps
        #expect(sleeps.count == 2)
        #expect(sleeps.count == 2 && (0.5..<0.75).contains(sleeps[0]))
        #expect(sleeps.count == 2 && (1.0..<1.25).contains(sleeps[1]))
    }

    @Test func rateLimitIsRetriedUntilSuccess() async throws {
        let stub = JevStubbedClient(maxRetries: 4) { attempt, _ in
            attempt <= 2
                ? .respond(status: 429, body: "Too many requests")
                : .respond(status: 200, body: #"{"answers":{"ok":{"probability":0.7}}}"#)
        }
        defer { JevStubURLProtocol.unregister(host: stub.host) }

        let response = try await stub.client.evaluate(jevTestRequest)

        #expect(response.booleanAnswer("ok")?.probability == 0.7)
        #expect(stub.route.callCount == 3)
        #expect(stub.clock.sleeps.count == 2)
    }

    @Test(arguments: [400, 404, 422])
    func clientErrorsAreNotRetried(status: Int) async throws {
        let stub = JevStubbedClient { _, _ in .respond(status: status, body: #"{"error":"bad"}"#) }
        defer { JevStubURLProtocol.unregister(host: stub.host) }

        await #expect(throws: JevError.protocolError(message: #"Client request rejected (HTTP \#(status)): {"error":"bad"}"#)) {
            try await stub.client.evaluate(jevTestRequest)
        }
        #expect(stub.route.callCount == 1)
    }

    @Test func jv05CancellationIsHonouredPromptly() async throws {
        let stub = JevStubbedClient { _, _ in .hang }
        defer { JevStubURLProtocol.unregister(host: stub.host) }

        let task = Task { try await stub.client.evaluate(jevTestRequest) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let cancelledAt = Date()
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(cancelledAt) < 2)
        #expect(stub.clock.sleeps.isEmpty)
    }

    @Test func timeoutsAreRetriedThenReportedAs408() async throws {
        let stub = JevStubbedClient(maxRetries: 1, timeoutSeconds: 0.2) { _, _ in .hang }
        defer { JevStubURLProtocol.unregister(host: stub.host) }

        await #expect(throws: JevError.transient(statusCode: 408, message: "Request timed out after max retries.")) {
            try await stub.client.evaluate(jevTestRequest)
        }
        #expect(stub.route.callCount == 2)
        #expect(stub.clock.sleeps.count == 1)
    }

    @Test func networkFailuresAreRetriedThenReportedAsStatusZero() async throws {
        let stub = JevStubbedClient(maxRetries: 2) { _, _ in .fail(.notConnectedToInternet) }
        defer { JevStubURLProtocol.unregister(host: stub.host) }

        do {
            _ = try await stub.client.evaluate(jevTestRequest)
            Issue.record("Expected a transient error")
        } catch let error as JevError {
            #expect(error.statusCode == 0)
            #expect(error.errorDescription?.contains("Network failure") == true)
        }
        #expect(stub.route.callCount == 3)
        #expect(stub.clock.sleeps.count == 2)
    }

    @Test func jv06ApiKeyNeverAppearsInErrorMessages() {
        let secret = "vck_live_secret_key_abcdef123456"
        let raw = "Bearer \(secret) resulted in failure with key \(secret)"

        let auth = JevError.auth(statusCode: 401, message: raw).errorDescription ?? ""
        #expect(!auth.contains(secret))
        #expect(auth.contains("[REDACTED]"))

        let transient = JevError.transient(statusCode: 500, message: raw).errorDescription ?? ""
        #expect(!transient.contains(secret))
        #expect(transient.contains("[REDACTED]"))

        let bearerOnly = JevError.protocolError(message: "header was bearer abcdefgh.ijk").errorDescription ?? ""
        #expect(bearerOnly == "Protocol / serialization error: header was bearer [REDACTED]")
    }

    @Test func echoedCustomKeyIsRedactedFromGatewayErrors() async throws {
        let key = "sk-custom-gateway-key"
        let stub = JevStubbedClient(apiKey: key) { _, _ in .respond(status: 401, body: "Key \(key) is revoked") }
        defer { JevStubURLProtocol.unregister(host: stub.host) }

        do {
            _ = try await stub.client.evaluate(jevTestRequest)
            Issue.record("Expected an auth error")
        } catch let error as JevError {
            #expect(error == .auth(statusCode: 401, message: "Key [REDACTED] is revoked"))
            #expect(error.errorDescription?.contains(key) == false)
        }
    }

    @Test(arguments: ["This is not valid JSON at all", "null", "", "[1, 2]", #"{"answers": []}"#])
    func jv07MalformedJSONThrowsProtocolError(body: String) async throws {
        let stub = JevStubbedClient { _, _ in .respond(status: 200, body: body) }
        defer { JevStubURLProtocol.unregister(host: stub.host) }

        do {
            _ = try await stub.client.evaluate(jevTestRequest)
            Issue.record("Expected a protocol error")
        } catch let error as JevError {
            guard case .protocolError = error else {
                Issue.record("Unexpected \(error)")
                return
            }
        }
        #expect(stub.route.callCount == 1)
    }

    @Test(arguments: [nil, "", "   "] as [String?])
    func missingAPIKeyFailsBeforeAnyRequest(apiKey: String?) async throws {
        let stub = JevStubbedClient(apiKey: apiKey) { _, _ in .respond(status: 200, body: "{}") }
        defer { JevStubURLProtocol.unregister(host: stub.host) }

        do {
            _ = try await stub.client.evaluate(jevTestRequest)
            Issue.record("Expected an auth error")
        } catch let error as JevError {
            #expect(error.statusCode == 401)
            #expect(error.errorDescription?.contains("AI_GATEWAY_API_KEY") == true)
        }
        #expect(stub.route.callCount == 0)
    }

    @Test func checkConnectionSendsDiagnosticAndSummarizes() async throws {
        let stub = JevStubbedClient { _, _ in
            .respond(status: 200, body: """
            {"answers":{"operational":{"probability":0.97}},
             "usage":{"promptTokens":100,"completionTokens":20,"totalTokens":120},
             "providerMetadata":{"gateway":{"cost":"0.000045"}}}
            """)
        }
        defer { JevStubURLProtocol.unregister(host: stub.host) }

        let summary = try await stub.client.checkConnection()

        #expect(summary.contains("model typesafe-ai/jev"))
        #expect(summary.contains("operational: true (97.0%)"))
        #expect(summary.contains("tokens: 120 (prompt 100, completion 20)"))
        #expect(summary.contains("cost: $0.000045"))
        #expect(!summary.contains(jevTestAPIKey))

        let sent = try #require(try stub.route.captured.first.map { try JSONDecoder().decode(EvaluateRequest.self, from: $0.body) })
        #expect(sent.questions["operational"]?.type == "boolean")
        #expect(sent.providerOptions?.gateway?.only == ["typesafe-ai"])
        #expect(sent.providerOptions?.gateway?.zeroDataRetention == nil)
        #expect(sent.state["system"] == "Shebang macOS Diagnostic")
        #expect(sent.state["timestamp"]?.stringValue?.hasSuffix("Z") == true)
    }

    // MARK: - Options

    @Test func optionsDefaultsMatchWindowsBuild() {
        let options = JevOptions()
        #expect(options.baseURL == "https://ai-gateway.vercel.sh")
        #expect(options.modelId == "typesafe-ai/jev")
        #expect(options.apiKey == nil)
        #expect(options.zeroDataRetention == false)
        #expect(options.timeoutSeconds == 30)
        #expect(options.maxRetries == 4)
        #expect(options.decisionConfidenceThreshold == 0.0)
        #expect(options.riskConfidenceThreshold == 0.70)
        #expect(JevOptions.fromEnvironment([:]) == options)
    }

    @Test func optionsFromEnvironmentReadsAllVariables() {
        let options = JevOptions.fromEnvironment([
            "AI_GATEWAY_BASE_URL": "https://gateway.example.com",
            "JEV_MODEL": "typesafe-ai/jev-next",
            "AI_GATEWAY_API_KEY": "  vck_env_key_123456789\n",
            "ZERO_DATA_RETENTION": "TRUE",
            "DECISION_CONFIDENCE_THRESHOLD": "0.55",
            "RISK_CONFIDENCE_THRESHOLD": "0.8",
        ])
        #expect(options.baseURL == "https://gateway.example.com")
        #expect(options.modelId == "typesafe-ai/jev-next")
        #expect(options.apiKey == "vck_env_key_123456789")
        #expect(options.zeroDataRetention)
        #expect(options.decisionConfidenceThreshold == 0.55)
        #expect(options.riskConfidenceThreshold == 0.8)
    }

    @Test func optionsFromEnvironmentIgnoresBlankAndInvalidValues() {
        let options = JevOptions.fromEnvironment([
            "AI_GATEWAY_BASE_URL": "   ",
            "JEV_MODEL": "",
            "AI_GATEWAY_API_KEY": " ",
            "ZERO_DATA_RETENTION": "yes",
            "DECISION_CONFIDENCE_THRESHOLD": "high",
            "RISK_CONFIDENCE_THRESHOLD": "",
        ])
        #expect(options == JevOptions())
    }

    @Test func zeroDataRetentionAcceptsReadmeAliasButPrefersPrimaryName() {
        #expect(JevOptions.fromEnvironment(["AI_GATEWAY_ZERO_DATA_RETENTION": "true"]).zeroDataRetention)
        #expect(!JevOptions.fromEnvironment([
            "ZERO_DATA_RETENTION": "false", "AI_GATEWAY_ZERO_DATA_RETENTION": "true",
        ]).zeroDataRetention)
    }
}
