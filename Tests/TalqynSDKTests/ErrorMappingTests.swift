import XCTest
import TalqynTestSupport
@testable import TalqynSDK

final class ErrorMappingTests: XCTestCase {
    private func failingSearch(
        json: String,
        status: Int,
        headers: [String: String] = [:],
        retryPolicy: TalqynRetryPolicy = .none
    ) async -> TalqynError? {
        let transport = StubTransport()
        transport.enqueue(json: json, status: status, headers: headers)
        do {
            let talqyn = try await TestFixtures.preparedClient(transport: transport, retryPolicy: retryPolicy)
            _ = try await talqyn.search.search("iphone")
            return nil
        } catch let error as TalqynError {
            return error
        } catch {
            return nil
        }
    }

    func testRateLimitCarriesRetryAfter() async throws {
        let error = await failingSearch(
            json: #"{"detail":"Rate limit exceeded"}"#, status: 429, headers: ["Retry-After": "60"]
        )
        guard case let .rateLimited(retryAfter, detail, _)? = error else {
            return XCTFail("expected rateLimited, got \(String(describing: error))")
        }
        XCTAssertEqual(retryAfter, 60)
        XCTAssertEqual(detail, "Rate limit exceeded")
        XCTAssertEqual(error?.isRetryable, true)
    }

    /// HTTP headers are case-insensitive: the server may use any casing.
    func testRetryAfterIsCaseInsensitive() async throws {
        let error = await failingSearch(
            json: "{}", status: 429, headers: ["retry-after": "5"]
        )
        XCTAssertEqual(error?.retryAfter, 5)
    }

    func testValidationErrorNamesFields() async throws {
        let error = await failingSearch(json: """
        {"error":"validation_error","request_id":"req-1",
         "detail":[{"loc":["body","filters",0],"msg":"too many keys","type":"value_error"}]}
        """, status: 422)
        guard case let .validation(fields, detail, requestID)? = error else {
            return XCTFail("expected validation, got \(String(describing: error))")
        }
        XCTAssertEqual(fields, ["body.filters.0"])
        XCTAssertEqual(detail, "too many keys")
        XCTAssertEqual(requestID, "req-1")
        XCTAssertEqual(error?.isRetryable, false)
    }

    func testForbiddenKeepsServerDetail() async throws {
        let error = await failingSearch(
            json: #"{"detail":"API key is missing the 'search' scope"}"#, status: 403
        )
        guard case let .forbidden(detail, _)? = error else {
            return XCTFail("expected forbidden, got \(String(describing: error))")
        }
        XCTAssertEqual(detail, "API key is missing the 'search' scope")
    }

    func testNotFound() async throws {
        let error = await failingSearch(json: #"{"detail":"chat not found"}"#, status: 404)
        guard case .notFound? = error else {
            return XCTFail("expected notFound, got \(String(describing: error))")
        }
    }

    func testServerEnvelopeCarriesCodeAndRequestID() async throws {
        let error = await failingSearch(
            json: #"{"error":"database_unavailable","request_id":"a1b2c3"}"#, status: 503
        )
        guard case let .server(status, code, _, _, requestID)? = error else {
            return XCTFail("expected server, got \(String(describing: error))")
        }
        XCTAssertEqual(status, 503)
        XCTAssertEqual(code, "database_unavailable")
        XCTAssertEqual(requestID, "a1b2c3")
        XCTAssertEqual(error?.isRetryable, true)
    }

    /// A 503 during a deploy names its own wait; the policy should see it.
    func testServerErrorCarriesRetryAfter() async throws {
        let error = await failingSearch(
            json: #"{"error":"overloaded"}"#, status: 503, headers: ["Retry-After": "2"]
        )
        XCTAssertEqual(error?.retryAfter, 2)
    }

    /// Only a 5xx is the server's own failure. A 400 or a 405 is a fixed
    /// answer to a fixed request: repeating it three times is three times the
    /// same answer, later.
    func testClientErrorOutsideTheKnownSetIsNotRetried() async throws {
        let transport = StubTransport()
        transport.enqueue(json: #"{"detail":"bad request"}"#, status: 400)

        let talqyn = try await TestFixtures.preparedClient(
            transport: transport, retryPolicy: TalqynRetryPolicy(maxRetries: 3, baseDelay: 0, maxDelay: 0)
        )
        do {
            _ = try await talqyn.search.search("iphone")
            XCTFail("expected a failure")
        } catch let error as TalqynError {
            guard case let .server(status, _, _, _, _) = error else {
                return XCTFail("expected server, got \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertFalse(error.isRetryable)
        }
        XCTAssertEqual(transport.sent.count, 1)
    }

    func testEmptyBodyStillMapsByStatus() async throws {
        let error = await failingSearch(json: "", status: 502)
        guard case let .server(status, code, _, _, _)? = error else {
            return XCTFail("expected server, got \(String(describing: error))")
        }
        XCTAssertEqual(status, 502)
        XCTAssertNil(code)
    }

    func testRetryPolicyRepeatsServerErrors() async throws {
        let transport = StubTransport()
        transport.enqueue(json: #"{"error":"overloaded"}"#, status: 503)
        transport.enqueue(json: #"{"error":"overloaded"}"#, status: 503)
        transport.enqueue(json: #"{"search_id":"s","query":"x","locale":"ru","total":0,"results":[]}"#)

        let talqyn = try await TestFixtures.preparedClient(
            transport: transport, retryPolicy: TalqynRetryPolicy(maxRetries: 2, baseDelay: 0, maxDelay: 0)
        )
        _ = try await talqyn.search.search("iphone")
        XCTAssertEqual(transport.sent.count, 3)
    }

    /// A `5xx` may arrive after the event was already recorded, and these rows
    /// are the denominator of click-through: a duplicate is worse than a miss.
    func testEventsAreNotRepeatedAfterAServerError() async throws {
        let transport = StubTransport()
        transport.enqueue(json: #"{"error":"internal_error"}"#, status: 500)
        transport.enqueue(json: "", status: 204)

        let talqyn = try await TestFixtures.preparedClient(
            transport: transport, retryPolicy: TalqynRetryPolicy(maxRetries: 2, baseDelay: 0, maxDelay: 0)
        )
        do {
            try await talqyn.events.productClick(
                .init(searchID: "s1", talqynID: 1, position: 0, source: .instant)
            )
            XCTFail("expected a failure")
        } catch let error as TalqynError {
            XCTAssertEqual(error.statusCode, 500)
        }
        XCTAssertEqual(transport.sent.count, 1)
    }

    /// A `429` is the one refusal that says the event was certainly not
    /// recorded, so it is the one worth repeating.
    func testEventsAreRepeatedAfterARateLimit() async throws {
        let transport = StubTransport()
        transport.enqueue(json: #"{"detail":"Rate limit exceeded"}"#, status: 429)
        transport.enqueue(json: "", status: 204)

        let talqyn = try await TestFixtures.preparedClient(
            transport: transport, retryPolicy: TalqynRetryPolicy(maxRetries: 2, baseDelay: 0, maxDelay: 0)
        )
        try await talqyn.events.searchSubmit(.init(query: "iphone", source: .instant, resultsCount: 8))
        XCTAssertEqual(transport.sent.count, 2)
    }

    func testClientErrorsAreNotRetried() async throws {
        let transport = StubTransport()
        transport.enqueue(json: #"{"detail":"nope"}"#, status: 403)

        let talqyn = try await TestFixtures.preparedClient(
            transport: transport, retryPolicy: TalqynRetryPolicy(maxRetries: 3, baseDelay: 0, maxDelay: 0)
        )
        _ = try? await talqyn.search.search("iphone")
        XCTAssertEqual(transport.sent.count, 1)
    }

    func testDecodingFailureIsReported() async throws {
        let error = await failingSearch(json: "not json", status: 200)
        guard case .decoding? = error else {
            return XCTFail("expected decoding, got \(String(describing: error))")
        }
    }

    /// `Retry-After` comes in two forms; a date in the past is "now", not a
    /// negative wait.
    func testRetryAfterIsReadInBothForms() throws {
        let now = try XCTUnwrap(TalqynCoding.httpDate(from: "Tue, 26 Aug 2025 12:15:00 GMT"))
        XCTAssertEqual(TalqynHTTPResponse(statusCode: 429, headers: ["Retry-After": "7"]).retryAfter(now: now), 7)
        XCTAssertEqual(TalqynHTTPResponse(statusCode: 429, headers: ["Retry-After": " 7 "]).retryAfter(now: now), 7)
        XCTAssertEqual(
            TalqynHTTPResponse(statusCode: 503, headers: ["Retry-After": "Tue, 26 Aug 2025 12:15:30 GMT"])
                .retryAfter(now: now),
            30
        )
        XCTAssertEqual(
            TalqynHTTPResponse(statusCode: 503, headers: ["Retry-After": "Tue, 26 Aug 2025 12:00:00 GMT"])
                .retryAfter(now: now),
            0
        )
        XCTAssertNil(TalqynHTTPResponse(statusCode: 429, headers: ["Retry-After": "soon"]).retryAfter(now: now))
        XCTAssertNil(TalqynHTTPResponse(statusCode: 429).retryAfter(now: now))
    }

    /// `NaN` parses as a number and is no wait: it reads as a header that
    /// cannot be read, and the error carries no `retryAfter` at all.
    func testANaNRetryAfterIsUnreadable() async throws {
        for raw in ["NaN", "nan", " -nan "] {
            XCTAssertNil(TalqynHTTPResponse(statusCode: 429, headers: ["Retry-After": raw]).retryAfter(), raw)
        }
        let error = await failingSearch(json: #"{"detail":"Rate limit exceeded"}"#, status: 429, headers: ["Retry-After": "NaN"])
        guard case let .rateLimited(retryAfter, _, _)? = error else {
            return XCTFail("expected rateLimited, got \(String(describing: error))")
        }
        XCTAssertNil(retryAfter)
    }

    func testRetryPolicyHonoursCap() {
        let policy = TalqynRetryPolicy(maxRetries: 2, baseDelay: 0.3, maxDelay: 5)
        XCTAssertEqual(policy.delay(forAttempt: 0, retryAfter: nil, jitter: 1), 0.3)
        XCTAssertEqual(policy.delay(forAttempt: 1, retryAfter: nil, jitter: 1), 0.6)
        XCTAssertEqual(policy.delay(forAttempt: 10, retryAfter: nil, jitter: 1), 5, "backoff is capped")
        XCTAssertEqual(policy.delay(forAttempt: 0, retryAfter: 2, jitter: 0), 2, "a short Retry-After is honoured as-is")
        XCTAssertNil(
            policy.delay(forAttempt: 0, retryAfter: 60),
            "a Retry-After beyond the cap declines the retry: a shorter wait would land in the same exhausted bucket"
        )
    }

    /// Every installation fails at the same moment of an outage; the waits
    /// spread between half and all of each step, so they do not all return at
    /// the same moment either. The cap holds under the spread.
    func testBackoffIsJitteredWithinItsStep() {
        let policy = TalqynRetryPolicy(maxRetries: 2, baseDelay: 0.4, maxDelay: 5)
        XCTAssertEqual(policy.delay(forAttempt: 1, retryAfter: nil, jitter: 0) ?? -1, 0.4, accuracy: 1e-9, "half of the 0.8 s step")
        XCTAssertEqual(policy.delay(forAttempt: 1, retryAfter: nil, jitter: 0.5) ?? -1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 10, retryAfter: nil, jitter: 0) ?? -1, 2.5, accuracy: 1e-9, "half of the capped step")
        for _ in 0..<50 {
            let wait = try? XCTUnwrap(policy.delay(forAttempt: 0, retryAfter: nil))
            XCTAssertTrue((0.2...0.4).contains(wait ?? -1), "\(String(describing: wait)) is outside the step")
        }
    }

    /// A per-minute bucket answers `Retry-After: 60`. Waiting the cap and
    /// asking again is ten seconds of a hung search field, then the same 429.
    func testRateLimitBeyondCapSurfacesAtOnce() async throws {
        let transport = StubTransport()
        transport.enqueue(
            json: #"{"detail":"Rate limit exceeded"}"#, status: 429, headers: ["Retry-After": "60"]
        )

        let talqyn = try await TestFixtures.preparedClient(transport: transport, retryPolicy: .default)
        let started = Date()
        do {
            _ = try await talqyn.search.search("iphone")
            XCTFail("expected a rate-limit failure")
        } catch let error as TalqynError {
            XCTAssertEqual(error.retryAfter, 60, "the app gets the server's wait to act on")
        }
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testRateLimitWithinCapIsRetried() async throws {
        let transport = StubTransport()
        transport.enqueue(
            json: #"{"detail":"Rate limit exceeded"}"#, status: 429, headers: ["Retry-After": "0"]
        )
        transport.enqueue(json: #"{"search_id":"s","query":"x","locale":"ru","total":0,"results":[]}"#)

        let talqyn = try await TestFixtures.preparedClient(transport: transport, retryPolicy: .default)
        _ = try await talqyn.search.search("iphone")
        XCTAssertEqual(transport.sent.count, 2)
    }

    /// Every failure an SDK call surfaces is a ``TalqynError`` — including one
    /// the caller produced before anything was sent.
    func testEncodingFailureIsTalqynError() async throws {
        let transport = StubTransport()
        let talqyn = try await TestFixtures.preparedClient(transport: transport)
        do {
            _ = try await talqyn.search.search(TalqynSearchQuery(query: "iphone", priceMin: .infinity))
            XCTFail("expected an encoding failure")
        } catch let error as TalqynError {
            guard case .encoding = error else { return XCTFail("expected encoding, got \(error)") }
            XCTAssertFalse(error.isRetryable)
        }
        XCTAssertTrue(transport.sent.isEmpty, "nothing must be sent")
    }
}
