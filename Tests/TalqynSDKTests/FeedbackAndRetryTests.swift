import XCTest
import TalqynTestSupport
@testable import TalqynSDK

/// Ratings of consultant turns, and which failed requests may be sent again.
final class FeedbackAndRetryTests: XCTestCase {
    private let turnID = "3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f"

    // MARK: - Feedback

    func testFeedbackIsPostedWithReasonsOnlyForADislike() async throws {
        let transport = StubTransport()
        transport.enqueue(json: "", status: 204)
        transport.enqueue(json: "", status: 204)
        transport.enqueue(json: "", status: 204)
        let talqyn = try await TestFixtures.preparedClient(transport: transport)
        talqyn.setVariant("exp-b")

        try await talqyn.consultant.submitFeedback(TalqynFeedback(
            turnID: turnID, sessionID: "sess-0001", verdict: .down,
            reasons: [.notRelevant, .priceStock], comment: "wrong ones", talqynIDs: [7]
        ))
        try await talqyn.consultant.submitFeedback(TalqynFeedback(
            turnID: turnID, sessionID: "sess-0001", verdict: .up, reasons: [.other], comment: "extra"
        ))
        try await talqyn.consultant.withdrawFeedback(turnID: turnID)

        let down = transport.sent[0]
        XCTAssertEqual(down.path, "/v1/consultant/feedback")
        XCTAssertEqual(down.request.httpMethod, "POST")
        XCTAssertEqual(down.bodyJSON["turn_id"] as? String, turnID)
        XCTAssertEqual(down.bodyJSON["session_id"] as? String, "sess-0001")
        XCTAssertEqual(down.bodyJSON["verdict"] as? String, "down")
        XCTAssertEqual(down.bodyJSON["reasons"] as? [String], ["not_relevant", "price_stock"])
        XCTAssertEqual(down.bodyJSON["comment"] as? String, "wrong ones")
        XCTAssertEqual(down.bodyJSON["talqyn_ids"] as? [Int], [7])
        XCTAssertEqual(down.bodyJSON["variant"] as? String, "exp-b", "the client's bucket is filled in")

        let up = transport.sent[1].bodyJSON
        XCTAssertEqual(up["verdict"] as? String, "up")
        XCTAssertNil(up["reasons"], "an up rating carries no reasons for the server to drop")
        XCTAssertNil(up["comment"])

        XCTAssertEqual(transport.sent[2].request.httpMethod, "DELETE")
        XCTAssertEqual(transport.sent[2].path, "/v1/consultant/feedback/\(turnID)")
    }

    /// A rating replaces itself, so a repeat is harmless and a failure is
    /// retried like a read.
    func testFeedbackIsRetriedAfterAServerError() async throws {
        let transport = StubTransport()
        transport.enqueue(json: #"{"error":"database_unavailable"}"#, status: 503)
        transport.enqueue(json: "", status: 204)
        let talqyn = try await TestFixtures.preparedClient(
            transport: transport, retryPolicy: TalqynRetryPolicy(maxRetries: 2, baseDelay: 0, maxDelay: 0)
        )
        try await talqyn.consultant.submitFeedback(TalqynFeedback(turnID: turnID, sessionID: "sess-0001", verdict: .up))
        XCTAssertEqual(transport.sent.count, 2)
    }

    func testTurnIDArrivesOnDoneTheAnswerAndTheTranscript() throws {
        let done = try TalqynCoding.decoder.decode(TalqynConsultantDone.self, from: Data(
            #"{"session_id":"s1","turn_id":"\#(turnID)","total_ms":10}"#.utf8
        ))
        XCTAssertEqual(done.turnID, turnID)

        let answer = try TalqynCoding.decoder.decode(TalqynConsultantAnswer.self, from: Data(
            #"{"answer":"","products":[],"turn_id":"\#(turnID)"}"#.utf8
        ))
        XCTAssertEqual(answer.turnID, turnID)

        let transcript = try TalqynCoding.decoder.decode(TalqynChatTranscript.self, from: Data("""
        {"session_id":"s1","messages":[
          {"role":"user","text":"q","turn_id":"\(turnID)","feedback":"down"},
          {"role":"assistant","text":"a","turn_id":"\(turnID)","feedback":"down"},
          {"role":"user","text":"old"}
        ],"products":[]}
        """.utf8))
        XCTAssertEqual(transcript.messages[1].turnID, turnID)
        XCTAssertEqual(transcript.messages[1].feedback, .down)
        XCTAssertNil(transcript.messages[2].turnID, "a turn from before ratings has no id")
        XCTAssertNil(transcript.messages[2].feedback)
    }

    // MARK: - Retry safety

    /// A consultant turn starts once the server accepts the stream. A refusal
    /// before that is safe to repeat; a connection that dropped may have left
    /// a paid turn running on the other end, and is not repeated.
    func testAStreamIsRepeatedAfterARefusalButNotAfterADroppedConnection() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: [#"{"error":"overloaded"}"#], status: 503)
        transport.enqueueStream(lines: ["event: done", #"data: {"session_id":"s"}"#, ""])
        transport.enqueueStream(error: URLError(.networkConnectionLost))
        transport.enqueueStream(lines: ["event: done", #"data: {"session_id":"s"}"#, ""])
        let talqyn = try await TestFixtures.preparedClient(
            transport: transport, retryPolicy: TalqynRetryPolicy(maxRetries: 2, baseDelay: 0, maxDelay: 0)
        )

        for try await _ in talqyn.consultant.ask("question") {}
        XCTAssertEqual(transport.sent.count, 2, "the 503 was repeated")

        do {
            for try await _ in talqyn.consultant.ask("another question") {}
            XCTFail("expected the dropped connection to surface")
        } catch let error as TalqynError {
            guard case let .transport(urlError) = error else { return XCTFail("expected transport, got \(error)") }
            XCTAssertEqual(urlError.code, .networkConnectionLost)
        }
        XCTAssertEqual(transport.sent.count, 3, "a dropped connection is not repeated")
    }

    /// Nothing comes back from `stream=false` until the turn is written, so a
    /// `5xx` may follow a turn that ran. Only a `429` says it did not.
    func testTheJSONAnswerIsRepeatedOnlyAfterARateLimit() async throws {
        let transport = StubTransport()
        transport.enqueue(json: #"{"detail":"Rate limit exceeded"}"#, status: 429)
        transport.enqueue(json: #"{"answer":"ok","products":[]}"#)
        transport.enqueue(json: #"{"error":"internal_error"}"#, status: 500)
        transport.enqueue(json: #"{"answer":"ok","products":[]}"#)
        let talqyn = try await TestFixtures.preparedClient(
            transport: transport, retryPolicy: TalqynRetryPolicy(maxRetries: 2, baseDelay: 0, maxDelay: 0)
        )

        _ = try await talqyn.consultant.answer(TalqynConsultantQuery(question: "hi"))
        XCTAssertEqual(transport.sent.count, 2)

        do {
            _ = try await talqyn.consultant.answer(TalqynConsultantQuery(question: "hi"))
            XCTFail("expected the server error to surface")
        } catch let error as TalqynError {
            XCTAssertEqual(error.statusCode, 500)
        }
        XCTAssertEqual(transport.sent.count, 3)
        XCTAssertEqual(
            transport.sent[0].request.timeoutInterval, 60,
            "the whole turn is waited for as long as a stream waits for its first byte"
        )
    }

    /// A token that could not be minted means the request itself was never
    /// sent: even an event, which is otherwise repeated only after a `429`,
    /// is safe to try again.
    func testAFailedMintIsRetriedEvenForAnEvent() async throws {
        let transport = StubTransport()
        transport.enqueue(error: URLError(.notConnectedToInternet))
        transport.enqueueDeviceToken()
        transport.enqueue(json: "", status: 204)
        let talqyn = TestFixtures.client(
            transport: transport, retryPolicy: TalqynRetryPolicy(maxRetries: 2, baseDelay: 0, maxDelay: 0)
        )

        try await talqyn.events.productClick(.init(searchID: "s1", talqynID: 1, position: 0, source: .instant))
        XCTAssertEqual(transport.sent.map(\.path), [
            "/v1/consultant/token", "/v1/consultant/token", "/v1/events/product-click",
        ])
    }

    func testRetrySafetyRules() {
        let overloaded = TalqynError.server(status: 503, code: "overloaded", detail: nil, retryAfter: nil, requestID: nil)
        let limited = TalqynError.rateLimited(retryAfter: nil, detail: nil, requestID: nil)
        let dropped = TalqynError.transport(URLError(.networkConnectionLost))
        let refused = TalqynError.forbidden(detail: nil, requestID: nil)

        for error in [overloaded, limited, dropped] {
            XCTAssertTrue(TalqynAPIClient.canRetry(error, safety: .idempotent, didSend: true))
        }
        XCTAssertTrue(TalqynAPIClient.canRetry(overloaded, safety: .untilAccepted, didSend: true))
        XCTAssertFalse(TalqynAPIClient.canRetry(dropped, safety: .untilAccepted, didSend: true))
        XCTAssertTrue(TalqynAPIClient.canRetry(limited, safety: .onlyIfRejected, didSend: true))
        XCTAssertFalse(TalqynAPIClient.canRetry(overloaded, safety: .onlyIfRejected, didSend: true))
        XCTAssertTrue(TalqynAPIClient.canRetry(dropped, safety: .onlyIfRejected, didSend: false), "nothing was sent")
        XCTAssertFalse(TalqynAPIClient.canRetry(refused, safety: .idempotent, didSend: false), "a refusal stays a refusal")
    }

    // MARK: - Errors

    /// A transport of your own may fail with an error of its own; the SDK
    /// reports it as a transport failure without losing what it was.
    func testWrapKeepsAForeignErrorUnderneath() {
        struct PinningFailed: Error, CustomStringConvertible {
            var description: String { "certificate pin mismatch" }
        }
        let wrapped = TalqynError.wrap(PinningFailed())
        guard case let .transport(urlError) = wrapped else { return XCTFail("expected transport, got \(wrapped)") }
        XCTAssertEqual(urlError.code, .unknown)
        XCTAssertNotNil(urlError.userInfo[NSUnderlyingErrorKey])
        XCTAssertTrue(
            wrapped.localizedDescription.contains("PinningFailed") || wrapped.localizedDescription.contains("pin"),
            wrapped.localizedDescription
        )
    }

    func testErrorsCompareByValue() {
        XCTAssertEqual(TalqynError.notFound(requestID: "a"), .notFound(requestID: "a"))
        XCTAssertNotEqual(TalqynError.notFound(requestID: "a"), .notFound(requestID: "b"))
        XCTAssertNotEqual(TalqynError.notFound(requestID: nil), .forbidden(detail: nil, requestID: nil))
        XCTAssertEqual(TalqynError.transport(URLError(.timedOut)), .transport(URLError(.timedOut)))
        XCTAssertEqual(TalqynError.cancelled, .cancelled)
    }

    /// The advice given for exhaustive switches must compile without a
    /// warning here: this target builds the way an app's does.
    func testAnEventSwitchWithAnUnknownDefaultCompiles() {
        let event = TalqynConsultantEvent.status(.thinking)
        let name: String
        switch event {
        case .status: name = "status"
        case .products: name = "products"
        case .delta: name = "delta"
        case .clarify: name = "clarify"
        case .redirectToSearch: name = "redirect"
        case .fallback: name = "fallback"
        case .action: name = "action"
        case .followUps: name = "followUps"
        case .error: name = "error"
        case .done: name = "done"
        @unknown default: name = "unknown"
        }
        XCTAssertEqual(name, "status")
    }
}
