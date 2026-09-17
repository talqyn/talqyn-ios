import Foundation
import TalqynSDK

/// A stub transport: a queue of canned responses and a record of what the SDK
/// actually sent.
public final class StubTransport: TalqynHTTPTransport, @unchecked Sendable {
    public struct Sent {
        public var request: URLRequest
        // Via URLComponents: `URL.path` strips the trailing slash, which is part
        // of the instant-search endpoint address.
        public var path: String {
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.path } ?? ""
        }
        public var query: String? { request.url?.query }
        public var body: Data? { request.httpBody }
        public var bodyText: String { body.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        public var bodyJSON: [String: Any] {
            guard let body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return [:] }
            return object
        }
        public func header(_ field: String) -> String? { request.value(forHTTPHeaderField: field) }
    }

    public enum StubError: Error { case queueEmpty }

    private let lock = NSLock()
    private var responses: [Result<(Data, TalqynHTTPResponse), Error>] = []
    private var streams: [Result<([String], TalqynHTTPResponse), Error>] = []
    private var recorded: [Sent] = []

    public init() {}

    public var sent: [Sent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Forgets what was sent so far — the mint a fixture performed on the
    /// caller's behalf, so the test's own requests start at index zero.
    public func clearSent() {
        lock.lock()
        defer { lock.unlock() }
        recorded.removeAll()
    }

    public func enqueue(json: String, status: Int = 200, headers: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        responses.append(.success((Data(json.utf8), TalqynHTTPResponse(statusCode: status, headers: headers))))
    }

    public func enqueue(error: Error) {
        lock.lock()
        defer { lock.unlock() }
        responses.append(.failure(error))
    }

    /// Puts a response **ahead** of everything queued so far: for a mint a
    /// fixture performs before the responses a test already lined up.
    public func prepend(json: String, status: Int = 200) {
        lock.lock()
        defer { lock.unlock() }
        responses.insert(.success((Data(json.utf8), TalqynHTTPResponse(statusCode: status))), at: 0)
    }

    public func enqueueStream(lines: [String], status: Int = 200, headers: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        streams.append(.success((lines, TalqynHTTPResponse(statusCode: status, headers: headers))))
    }

    /// A stream that never opens: the request failed before any answer came.
    public func enqueueStream(error: Error) {
        lock.lock()
        defer { lock.unlock() }
        streams.append(.failure(error))
    }

    // The lock is taken in synchronous methods: an NSLock must not be held
    // across a suspension point.
    private func takeResponse(_ request: URLRequest) throws -> Result<(Data, TalqynHTTPResponse), Error> {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Sent(request: request))
        guard !responses.isEmpty else { throw StubError.queueEmpty }
        return responses.removeFirst()
    }

    private func takeStream(_ request: URLRequest) throws -> Result<([String], TalqynHTTPResponse), Error> {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Sent(request: request))
        guard !streams.isEmpty else { throw StubError.queueEmpty }
        return streams.removeFirst()
    }

    public func send(_ request: URLRequest) async throws -> (Data, TalqynHTTPResponse) {
        try takeResponse(request).get()
    }

    public func stream(_ request: URLRequest) async throws -> (TalqynLineStream, TalqynHTTPResponse) {
        let (lines, response) = try takeStream(request).get()
        return (TalqynLineStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }, response)
    }
}

public extension StubTransport {
    func enqueueDeviceToken(
        token: String = "tlqd_test",
        expiresIn: Int = 900,
        userID: String? = nil
    ) {
        let user = userID.map { "\"user_id\":\"\($0)\"," } ?? ""
        enqueue(json: """
        {"token":"\(token)",\(user)"expires_at":"2026-08-26T12:15:00Z","expires_in":\(expiresIn)}
        """)
    }
}

public enum TestFixtures {
    /// The host the tests address. The SDK has no endpoint of its own, so every
    /// fixture names one, and this is it.
    public static let baseURL = URL(string: "https://api.example.com")!

    public static func client(
        credentials: TalqynDeviceTokenCredentials = deviceToken(),
        transport: TalqynHTTPTransport,
        baseURL: URL = TestFixtures.baseURL,
        retryPolicy: TalqynRetryPolicy = .none,
        cityID: String? = nil,
        userIDStore: TalqynUserIDStore = TalqynInMemoryUserIDStore(),
        logHandler: (@Sendable (TalqynLogEvent) -> Void)? = nil
    ) -> Talqyn {
        Talqyn(configuration: TalqynConfiguration(
            baseURL: baseURL,
            credentials: credentials,
            defaultCityID: cityID,
            retryPolicy: retryPolicy,
            userIDStore: userIDStore,
            transport: transport,
            logHandler: logHandler
        ))
    }

    /// A client that already holds a device token, with the mint forgotten by
    /// the transport: for tests about endpoints, not about the token.
    public static func preparedClient(
        transport: StubTransport,
        baseURL: URL = TestFixtures.baseURL,
        retryPolicy: TalqynRetryPolicy = .none,
        cityID: String? = nil
    ) async throws -> Talqyn {
        // Ahead of the queue: tests line their responses up before the client exists.
        transport.prepend(json: #"{"token":"tlqd_test","expires_at":"2026-08-26T12:15:00Z","expires_in":900}"#)
        let talqyn = client(transport: transport, baseURL: baseURL, retryPolicy: retryPolicy, cityID: cityID)
        try await talqyn.prepare()
        transport.clearSent()
        return talqyn
    }

    public static func deviceToken(
        identity: TalqynDeviceIdentity = .guest
    ) -> TalqynDeviceTokenCredentials {
        TalqynDeviceTokenCredentials(
            storefront: "myshop",
            clientKeyID: "ck_3f9a1c2b7d4e",
            clientSecret: "s3cr3t-client-key-value-32-chars-long",
            identity: identity
        )
    }
}

/// A clock that moves only when told to.
public final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()

    public init() {}

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// Collects log events from the SDK.
public final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TalqynLogEvent] = []

    public init() {}

    public var all: [TalqynLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    @Sendable public func append(_ event: TalqynLogEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }
}

/// A transport whose stream delivers lines with a delay, like a network does.
///
/// A ``StubTransport`` yields everything synchronously, which hides every
/// question about what happens **during** a turn — cancellation above all.
public final class SlowStreamTransport: TalqynHTTPTransport, @unchecked Sendable {
    public let responses = StubTransport()
    private let lock = NSLock()
    private var lines: [String] = []
    private var keepsOpen = false
    private var terminated = false

    public init() {}

    /// Whether the stream handed out was cancelled or drained.
    public var wasTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    /// - Parameters:
    ///   - lines: What every stream handed out delivers.
    ///   - keepsOpen: Whether the stream stays open after its last line, the
    ///     way a server or a proxy holds an idle connection: it then ends only
    ///     when the SDK cancels it.
    public func enqueueStream(lines: [String], keepsOpen: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        self.lines = lines
        self.keepsOpen = keepsOpen
    }

    public func send(_ request: URLRequest) async throws -> (Data, TalqynHTTPResponse) {
        try await responses.send(request)
    }

    private func queuedStream() -> (lines: [String], keepsOpen: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (lines, keepsOpen)
    }

    public func stream(_ request: URLRequest) async throws -> (TalqynLineStream, TalqynHTTPResponse) {
        let (lines, keepsOpen) = queuedStream()
        let stream = TalqynLineStream { continuation in
            let task = Task {
                do {
                    for line in lines {
                        try await Task.sleep(nanoseconds: 20_000_000)
                        continuation.yield(line)
                    }
                    // An idle connection is a stream nobody finishes: its
                    // reader waits for a next line until it cancels.
                    guard !keepsOpen else { return }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                guard let self else { return }
                self.lock.lock()
                self.terminated = true
                self.lock.unlock()
            }
        }
        return (stream, TalqynHTTPResponse(statusCode: 200))
    }
}

/// A transport that answers every request through a closure of the test's,
/// so a response can wait, fail, or have something happen on its way — what a
/// queue of canned responses cannot. The mint is answered for it, and a
/// request cancelled while the closure answers it is noted.
public final class ScriptedTransport: TalqynHTTPTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest) async throws -> (Data, TalqynHTTPResponse)

    private let handler: Handler
    private let lock = NSLock()
    private var recorded: [StubTransport.Sent] = []
    private var cancelled: [String] = []

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// The requests handed to the closure, in the order they arrived.
    public var sent: [StubTransport.Sent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The paths of the requests cancelled while the closure answered them.
    public var cancelledPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// A response with a body, for the closure to return.
    public static func json(_ body: String, status: Int = 200) -> (Data, TalqynHTTPResponse) {
        (Data(body.utf8), TalqynHTTPResponse(statusCode: status))
    }

    private func record(_ request: URLRequest, cancelled wasCancelled: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let sent = StubTransport.Sent(request: request)
        if wasCancelled {
            cancelled.append(sent.path)
        } else {
            recorded.append(sent)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, TalqynHTTPResponse) {
        if request.url?.path.hasSuffix("/consultant/token") == true {
            return Self.json(#"{"token":"tlqd_test","expires_at":"2026-08-26T12:15:00Z","expires_in":900}"#)
        }
        record(request)
        do {
            return try await handler(request)
        } catch {
            if Task.isCancelled { record(request, cancelled: true) }
            throw error
        }
    }

    public func stream(_ request: URLRequest) async throws -> (TalqynLineStream, TalqynHTTPResponse) {
        record(request)
        throw StubTransport.StubError.queueEmpty
    }
}
