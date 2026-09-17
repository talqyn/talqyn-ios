import XCTest
import TalqynTestSupport
@testable import TalqynSDK

final class ConsultantStreamTests: XCTestCase {
    private func collect(
        _ stream: AsyncThrowingStream<TalqynConsultantEvent, Error>
    ) async throws -> [TalqynConsultantEvent] {
        var events: [TalqynConsultantEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    func testTurnIsParsedIntoEvents() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        transport.enqueueStream(lines: [
            "event: status", "data: {\"stage\":\"thinking\"}", "",
            "event: status", "data: {\"stage\":\"searching\"}", "",
            "event: products", "data: {\"items\":[{\"talqyn_id\":1,\"title\":\"Laptop\"}],\"search_id\":\"s1\"}", "",
            "event: delta", "data: {\"text\":\"Here \"}", "",
            "event: delta", "data: {\"text\":\"[p:1]\"}", "",
            "event: follow_ups", "data: {\"items\":[\"cheaper\"]}", "",
            "event: done", "data: {\"session_id\":\"sess-1\",\"ttft_ms\":300,\"total_ms\":1500}", "",
        ])

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        let events = try await collect(talqyn.consultant.ask("need a laptop"))

        XCTAssertEqual(events.count, 7)
        XCTAssertEqual(events.first, .status(.thinking))
        XCTAssertTrue(events.last?.isTerminal == true)

        let text = events.compactMap { event -> String? in
            if case let .delta(text) = event { return text }
            return nil
        }.joined()
        XCTAssertEqual(TalqynAnswerMarkup.mentionedProductIDs(text), [1])

        let ask = transport.sent[1]
        XCTAssertEqual(ask.path, "/v1/consultant/ask")
        XCTAssertEqual(ask.header("Accept"), "text/event-stream")
        XCTAssertEqual(ask.bodyJSON["question"] as? String, "need a laptop")
    }

    func testSessionIsCarriedIntoNextTurn() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        transport.enqueueStream(lines: ["event: done", "data: {\"session_id\":\"sess-1\",\"total_ms\":10}", ""])
        transport.enqueueStream(lines: ["event: done", "data: {\"session_id\":\"sess-1\",\"total_ms\":10}", ""])

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        let first = try await collect(talqyn.consultant.ask("question"))
        guard case let .done(done)? = first.last else { return XCTFail("expected done") }

        _ = try await collect(talqyn.consultant.ask("second question", sessionID: done.sessionID))
        XCTAssertEqual(transport.sent[2].bodyJSON["session_id"] as? String, "sess-1")
    }

    func testClarifyTurnHasNoProducts() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        transport.enqueueStream(lines: [
            "event: status", "data: {\"stage\":\"thinking\"}", "",
            "event: clarify",
            "data: {\"message\":\"clarify\",\"questions\":[{\"id\":\"budget\",\"label\":\"Budget\",\"options\":[\"under 300k\"]}]}", "",
            "event: done", "data: {\"session_id\":\"s\",\"total_ms\":5}", "",
        ])

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        let events = try await collect(talqyn.consultant.ask("recommend something"))

        guard case let .clarify(clarify) = events[1] else { return XCTFail("expected clarify") }
        XCTAssertEqual(clarify.questions.first?.label, "Budget")
        XCTAssertFalse(events.contains { if case .products = $0 { return true } else { return false } })
    }

    func testStreamErrorStatusIsSurfaced() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        transport.enqueueStream(lines: [#"{"detail":"Rate limit exceeded"}"#], status: 429, headers: ["Retry-After": "60"])

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        do {
            _ = try await collect(talqyn.consultant.ask("question"))
            XCTFail("expected a rate-limit failure")
        } catch let error as TalqynError {
            guard case let .rateLimited(retryAfter, _, _) = error else {
                return XCTFail("expected rateLimited, got \(error)")
            }
            XCTAssertEqual(retryAfter, 60)
        }
    }

    func testStreamReissuesTokenOn401() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken(token: "tlqd_old")
        transport.enqueueStream(lines: [#"{"detail":"Invalid device token"}"#], status: 401)
        transport.enqueueDeviceToken(token: "tlqd_new")
        transport.enqueueStream(lines: ["event: done", "data: {\"session_id\":\"s\",\"total_ms\":1}", ""])

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        let events = try await collect(talqyn.consultant.ask("question"))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(transport.sent.count, 4)
        XCTAssertEqual(transport.sent[3].header("Authorization"), "Bearer tlqd_new")
    }

    func testFallbackTurnKeepsProducts() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        transport.enqueueStream(lines: [
            "event: products", "data: {\"items\":[{\"talqyn_id\":7,\"title\":\"A\"}]}", "",
            "event: fallback", "data: {\"reason\":\"user_budget_exceeded\"}", "",
            "event: done", "data: {\"session_id\":\"s\",\"total_ms\":9}", "",
        ])

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        let events = try await collect(talqyn.consultant.ask("question"))

        guard case let .products(payload) = events[0] else { return XCTFail("expected products") }
        XCTAssertEqual(payload.items.count, 1)
        XCTAssertEqual(events[1], .fallback(reason: .userBudgetExceeded))
    }

    /// The contract closes every turn with `done`. A stream that ends without
    /// it was cut somewhere between Talqyn and the device, and the app must not
    /// take a turn that merely stopped for one that finished.
    func testStreamCutBeforeDoneThrowsAfterDeliveredEvents() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        transport.enqueueStream(lines: [
            "event: status", "data: {\"stage\":\"thinking\"}", "",
            "event: delta", "data: {\"text\":\"Here\"}", "",
        ])

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        var events: [TalqynConsultantEvent] = []
        do {
            for try await event in talqyn.consultant.ask("question") { events.append(event) }
            XCTFail("expected the cut to be reported")
        } catch let error as TalqynError {
            guard case let .transport(urlError) = error else { return XCTFail("expected transport, got \(error)") }
            XCTAssertEqual(urlError.code, .networkConnectionLost)
        }
        XCTAssertEqual(events.count, 2, "what arrived before the cut is delivered first")
    }

    /// A dismissed screen stops reading. That cancels the request behind the
    /// stream, and it is not a cut stream: nothing to warn about.
    func testStoppingMidTurnCancelsTheRequestQuietly() async throws {
        let transport = SlowStreamTransport()
        transport.responses.enqueueDeviceToken()
        transport.enqueueStream(lines: [
            "event: status", "data: {\"stage\":\"thinking\"}", "",
            "event: delta", "data: {\"text\":\"a\"}", "",
            "event: delta", "data: {\"text\":\"b\"}", "",
            "event: done", "data: {\"session_id\":\"s\"}", "",
        ])
        let logs = LogCollector()
        let talqyn = Talqyn(configuration: TalqynConfiguration(
            baseURL: TestFixtures.baseURL,
            credentials: TestFixtures.deviceToken(),
            retryPolicy: .none,
            userIDStore: TalqynInMemoryUserIDStore(),
            transport: transport,
            logHandler: logs.append
        ))

        var seen = 0
        for try await _ in talqyn.consultant.ask("question") {
            seen += 1
            if seen == 1 { break }
        }

        let cancelled = await Self.waitUntil { transport.wasTerminated }
        XCTAssertTrue(cancelled, "dropping the stream must cancel the request")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(
            logs.all.contains { $0.level == .warning },
            "a stopped consumer is not a cut stream: \(logs.all.map(\.message))"
        )
    }

    /// `done` is the end of the turn, whatever the connection does next. A
    /// server — or a proxy — holding the connection open after it must not keep
    /// the iteration waiting, nor fail a finished turn with a transport error
    /// once the idle connection drops; and the request behind the turn is
    /// closed rather than left open.
    func testIterationEndsAtDoneAndClosesTheConnection() async throws {
        let transport = SlowStreamTransport()
        transport.responses.enqueueDeviceToken()
        transport.enqueueStream(lines: [
            "event: delta", "data: {\"text\":\"ok\"}", "",
            "event: done", "data: {\"session_id\":\"s\"}", "",
        ], keepsOpen: true)
        let talqyn = TestFixtures.client(transport: transport)

        let reading = Task { () -> (events: [TalqynConsultantEvent], wasCancelled: Bool) in
            var events: [TalqynConsultantEvent] = []
            for try await event in talqyn.consultant.ask("question") { events.append(event) }
            return (events, Task.isCancelled)
        }
        // Without it, an iteration that reads past `done` waits here for good.
        // A cancelled reader leaves the loop quietly too, which is why the
        // reading task says whether it was cancelled.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            reading.cancel()
        }
        defer { watchdog.cancel() }

        let (events, wasCancelled) = try await reading.value
        XCTAssertFalse(wasCancelled, "the iteration read past done until the watchdog stopped it")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.isTerminal, true)
        let closed = await Self.waitUntil { transport.wasTerminated }
        XCTAssertTrue(closed, "the request behind a finished turn is still open")
    }

    private static func waitUntil(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
