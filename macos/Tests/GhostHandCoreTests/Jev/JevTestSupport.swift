import Foundation
@testable import GhostHandCore

// Shared fakes for the Jev tests. Names are Jev-prefixed to stay unique within the test target.

let jevTestAPIKey = "vck_test_secret_key_12345678"

/// Records backoff sleeps and returns immediately.
final class JevTestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    let now = Date(timeIntervalSince1970: 1_790_000_000)

    var sleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { recorded.append(seconds) }
    }
}

/// `URLProtocol` stub routed by host, so parallel tests using distinct hosts never interfere.
final class JevStubURLProtocol: URLProtocol {
    enum Reply {
        case respond(status: Int, body: String)
        case fail(URLError.Code)
        /// Never answers; used for timeout and cancellation tests.
        case hang
    }

    struct Captured {
        let request: URLRequest
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    /// Per-host handler and log of received requests. The handler gets the 1-based attempt number.
    final class Route: @unchecked Sendable {
        private let lock = NSLock()
        private let handler: (Int, URLRequest) -> Reply
        private var log: [Captured] = []

        init(handler: @escaping (Int, URLRequest) -> Reply) {
            self.handler = handler
        }

        var captured: [Captured] {
            lock.lock()
            defer { lock.unlock() }
            return log
        }

        var callCount: Int { captured.count }

        fileprivate func receive(_ request: URLRequest, body: Data) -> Reply {
            lock.lock()
            log.append(Captured(request: request, body: body))
            let attempt = log.count
            lock.unlock()
            return handler(attempt, request)
        }
    }

    private static let lock = NSLock()
    private static var routes: [String: Route] = [:]

    static func register(host: String, handler: @escaping (Int, URLRequest) -> Reply) -> Route {
        let route = Route(handler: handler)
        lock.lock()
        routes[host] = route
        lock.unlock()
        return route
    }

    static func unregister(host: String) {
        lock.lock()
        routes[host] = nil
        lock.unlock()
    }

    private static func route(for host: String) -> Route? {
        lock.lock()
        defer { lock.unlock() }
        return routes[host]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let route = Self.route(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch route.receive(request, body: Self.body(of: request)) {
        case .respond(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    /// URLSession moves `httpBody` into a stream before it reaches the protocol.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

/// A `JevClient` wired to the stub on a unique host with a recording clock.
struct JevStubbedClient {
    let client: JevClient
    let route: JevStubURLProtocol.Route
    let clock: JevTestClock
    let host: String

    init(
        host: String = "\(UUID().uuidString.lowercased()).jev.test",
        apiKey: String? = jevTestAPIKey,
        maxRetries: Int = 2,
        timeoutSeconds: TimeInterval = 5,
        configure: (inout JevOptions) -> Void = { _ in },
        handler: @escaping (Int, URLRequest) -> JevStubURLProtocol.Reply
    ) {
        var options = JevOptions(baseURL: "https://\(host)", apiKey: apiKey,
                                 timeoutSeconds: timeoutSeconds, maxRetries: maxRetries)
        configure(&options)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JevStubURLProtocol.self]
        self.host = host
        self.route = JevStubURLProtocol.register(host: host, handler: handler)
        self.clock = JevTestClock()
        self.client = JevClient(options: options, session: URLSession(configuration: configuration), clock: clock)
    }
}

/// Scripted `JevEvaluating` for decision-model tests.
final class FakeJevClient: JevEvaluating, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<EvaluateResponse, Error>]
    private var received: [EvaluateRequest] = []

    init(_ results: [Result<EvaluateResponse, Error>]) {
        queue = results
    }

    convenience init(_ response: EvaluateResponse) {
        self.init([.success(response)])
    }

    convenience init(answers: [String: JevJSON]) {
        self.init(EvaluateResponse(answers: answers))
    }

    var requests: [EvaluateRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func evaluate(_ request: EvaluateRequest) async throws -> EvaluateResponse {
        // The last scripted result repeats once the queue is drained.
        let result = lock.withLock {
            received.append(request)
            return queue.count > 1 ? queue.removeFirst() : queue.first
        }
        guard let result else { return EvaluateResponse() }
        return try result.get()
    }
}

let jevTestRequest = EvaluateRequest(model: "typesafe-ai/jev", state: [:], questions: [:])

func decodeJevResponse(_ json: String) throws -> EvaluateResponse {
    try JSONDecoder().decode(EvaluateResponse.self, from: Data(json.utf8))
}
