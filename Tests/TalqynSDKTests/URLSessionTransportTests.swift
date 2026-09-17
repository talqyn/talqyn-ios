import XCTest
import TalqynTestSupport
@testable import TalqynSDK

/// The default transport end to end, over a `URLProtocol` stub: headers come
/// back before the body, and the body is split into lines the way the SDK
/// expects — including a terminator torn across two chunks.
final class URLSessionTransportTests: XCTestCase {
    private func transport() -> TalqynURLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return TalqynURLSessionTransport(session: URLSession(configuration: configuration))
    }

    private var request: URLRequest {
        URLRequest(url: URL(string: "https://stub.talqyn.test/v1/consultant/ask")!)
    }

    func testSendReturnsBodyStatusAndLowercasedHeaders() async throws {
        StubURLProtocol.respond(
            status: 429,
            headers: ["Retry-After": "7", "X-Request-ID": "req-1"],
            chunks: [Data(#"{"detail":"Rate limit exceeded"}"#.utf8)]
        )
        let (data, response) = try await transport().send(request)
        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(response.value(for: "retry-after"), "7")
        XCTAssertEqual(response.value(for: "X-REQUEST-ID"), "req-1")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"detail":"Rate limit exceeded"}"#)
    }

    func testStreamSplitsLinesAcrossChunks() async throws {
        StubURLProtocol.respond(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: [
                Data("event: status\r".utf8),
                Data("\ndata: {\"stage\":\"thinking\"}\r\n\r\nevent: delta\ndata: {\"text\":\"a\u{2028}b\"}\n\n".utf8),
                Data("event: done\ndata: {\"session_id\":\"s\"}".utf8),
            ]
        )
        let (lines, response) = try await transport().stream(request)
        XCTAssertEqual(response.statusCode, 200)

        var collected: [String] = []
        for try await line in lines { collected.append(line) }
        XCTAssertEqual(collected, [
            "event: status", "data: {\"stage\":\"thinking\"}", "",
            "event: delta", "data: {\"text\":\"a\u{2028}b\"}", "",
            "event: done", "data: {\"session_id\":\"s\"}",
        ])
    }

    func testStreamedErrorBodyIsReadableAsLines() async throws {
        StubURLProtocol.respond(status: 401, headers: [:], chunks: [Data(#"{"detail":"Invalid device token"}"#.utf8)])
        let (lines, response) = try await transport().stream(request)
        XCTAssertEqual(response.statusCode, 401)
        var collected: [String] = []
        for try await line in lines { collected.append(line) }
        XCTAssertEqual(collected, [#"{"detail":"Invalid device token"}"#])
    }
}

/// Answers every request with the canned response set by `respond`.
final class StubURLProtocol: URLProtocol {
    private struct Canned: Sendable {
        var status: Int
        var headers: [String: String]
        var chunks: [Data]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var canned: Canned?

    static func respond(status: Int, headers: [String: String], chunks: [Data]) {
        lock.lock()
        defer { lock.unlock() }
        canned = Canned(status: status, headers: headers, chunks: chunks)
    }

    private static func current() -> Canned? {
        lock.lock()
        defer { lock.unlock() }
        return canned
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let canned = Self.current(), let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in canned.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
