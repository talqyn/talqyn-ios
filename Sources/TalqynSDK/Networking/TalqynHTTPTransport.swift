import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The status line and headers of an HTTP response, without its body.
public struct TalqynHTTPResponse: Sendable {
    /// The HTTP status code.
    public var statusCode: Int

    /// The response headers, keyed by **lowercased** field name.
    ///
    /// HTTP header names are case-insensitive, but `allHeaderFields` reports
    /// whatever casing the server used. Immutable so the lowercasing done by
    /// the initializer cannot be undone; prefer ``value(for:)`` over
    /// subscripting this directly.
    public let headers: [String: String]

    /// Creates a response description.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code.
    ///   - headers: The response headers in any casing; they are lowercased.
    public init(statusCode: Int, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }

    /// Returns a header value, matching the field name case-insensitively.
    ///
    /// - Parameter field: The header field name, in any casing.
    /// - Returns: The value, or `nil` if the header is absent.
    public func value(for field: String) -> String? {
        headers[field.lowercased()]
    }

    /// Whether the status code is in the `2xx` range.
    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// The `Retry-After` header as seconds from now, in either form the header
    /// allows: a delay in seconds, or an HTTP date. A date already in the past
    /// reads as zero — "now" — rather than as a negative wait.
    ///
    /// - Parameter now: The moment to measure a dated value from.
    /// - Returns: The wait in seconds, or `nil` when the header is absent or
    ///   unreadable.
    func retryAfter(now: Date = Date()) -> TimeInterval? {
        guard let raw = value(for: "Retry-After")?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        if let seconds = TimeInterval(raw) {
            // `NaN` parses, and it is no wait: it compares false with every
            // number — `max` hands it back rather than zero — so it would pass
            // for a wait too long to honour and reach the app as `retryAfter`.
            guard !seconds.isNaN else { return nil }
            return max(seconds, 0)
        }
        if let date = TalqynCoding.httpDate(from: raw) { return max(date.timeIntervalSince(now), 0) }
        return nil
    }
}

/// A stream of response body lines, as produced by ``TalqynHTTPTransport/stream(_:)``.
public typealias TalqynLineStream = AsyncThrowingStream<String, Error>

/// The HTTP layer the SDK sends requests through.
///
/// Implement this to route Talqyn traffic through a `URLSession` of your own —
/// certificate pinning, a corporate proxy, a traffic logger such as Pulse — or
/// to stub the network in tests. Pass the implementation as
/// ``TalqynConfiguration/transport``; the default is
/// ``TalqynURLSessionTransport``. An implementation over `URLSession` splits
/// the streamed body with ``TalqynLineSplitter/lines(from:)``:
///
/// ```swift
/// func stream(_ request: URLRequest) async throws -> (TalqynLineStream, TalqynHTTPResponse) {
///     let (bytes, response) = try await session.bytes(for: request)
///     return (TalqynLineSplitter.lines(from: bytes), describe(response))
/// }
/// ```
///
/// - Note: The SDK calls a transport from multiple tasks concurrently.
public protocol TalqynHTTPTransport: Sendable {
    /// Performs a request and returns the whole body.
    ///
    /// The implementation must **not** throw on a non-`2xx` status: the SDK
    /// inspects the status itself and decodes the error envelope from the body.
    ///
    /// - Parameter request: The prepared request.
    /// - Returns: The response body and its status line and headers.
    /// - Throws: A `URLError` if the request could not be completed.
    func send(_ request: URLRequest) async throws -> (Data, TalqynHTTPResponse)

    /// Performs a request and returns its body line by line, as it arrives.
    ///
    /// Used for the consultant's `text/event-stream` responses. The status line
    /// and headers must be returned **immediately**, before the first body line:
    /// the SDK decides from the status whether this is a stream to parse or an
    /// error envelope to read. On a failing status the returned stream should
    /// still yield the error body.
    ///
    /// Cancelling the returned stream must cancel the underlying request.
    ///
    /// - Parameter request: The prepared request.
    /// - Returns: The body lines and the response status line and headers.
    /// - Throws: A `URLError` if the request could not be started.
    func stream(_ request: URLRequest) async throws -> (TalqynLineStream, TalqynHTTPResponse)
}

/// The default ``TalqynHTTPTransport``, backed by `URLSession`.
public struct TalqynURLSessionTransport: TalqynHTTPTransport {
    private let session: URLSession

    /// Wraps a session you configured yourself.
    ///
    /// - Parameter session: The session to send requests through. Its delegate,
    ///   if any, is where certificate pinning belongs.
    public init(session: URLSession) {
        self.session = session
    }

    /// Creates a transport over a private ephemeral session.
    ///
    /// The session carries no cookie or response cache: search results are
    /// per-tenant and personal, and no intermediary is allowed to store them.
    ///
    /// - Parameters:
    ///   - timeout: The per-request timeout, in seconds.
    ///   - streamTimeout: The wait for the first byte of a streamed response, in
    ///     seconds. Used to size the overall resource timeout.
    public init(timeout: TimeInterval = 30, streamTimeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        // A consultant turn outlives an ordinary request, so the resource cap
        // is generous; timeoutIntervalForRequest measures the gap between
        // chunks and does not cut a live stream short.
        configuration.timeoutIntervalForResource = max(timeout, streamTimeout) * 10
        configuration.waitsForConnectivity = false
        // Results are per-tenant and personal: no cache may hold them. The
        // server says so in a header; do not rely on that alone.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.init(session: URLSession(configuration: configuration))
    }

    /// Performs a request and returns the whole body.
    ///
    /// - Parameter request: The prepared request.
    /// - Returns: The response body and its status line and headers.
    /// - Throws: A `URLError` if the request could not be completed.
    public func send(_ request: URLRequest) async throws -> (Data, TalqynHTTPResponse) {
        let (data, response) = try await session.data(for: request)
        return (data, Self.describe(response))
    }

    /// Performs a request and returns its body line by line.
    ///
    /// - Parameter request: The prepared request.
    /// - Returns: The body lines and the response status line and headers.
    /// - Throws: A `URLError` if the request could not be started.
    public func stream(_ request: URLRequest) async throws -> (TalqynLineStream, TalqynHTTPResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        return (TalqynLineSplitter.lines(from: bytes), Self.describe(response))
    }

    private static func describe(_ response: URLResponse) -> TalqynHTTPResponse {
        guard let http = response as? HTTPURLResponse else {
            return TalqynHTTPResponse(statusCode: 200)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key] = value
        }
        return TalqynHTTPResponse(statusCode: http.statusCode, headers: headers)
    }
}
