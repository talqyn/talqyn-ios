import XCTest
import TalqynTestSupport
@testable import TalqynSDK

/// Endpoints: path, body, headers, and how defaults are filled in.
final class APIRequestTests: XCTestCase {
    private let emptySearch = #"{"search_id":"s","query":"x","locale":"ru","total":0,"results":[]}"#
    private let emptyListing = #"{"query":"x","locale":"ru","offset":0,"limit":20,"sort":"relevance","total":0,"results":[]}"#

    func testEveryRequestCarriesTheTokenAndARequestID() async throws {
        let transport = StubTransport()
        let talqyn = try await TestFixtures.preparedClient(transport: transport)
        transport.enqueue(json: emptySearch)
        _ = try await talqyn.search.search("iphone")

        let sent = transport.sent[0]
        XCTAssertEqual(sent.header("Authorization"), "Bearer tlqd_test")
        XCTAssertNotNil(sent.header("X-Request-ID"))
        XCTAssertEqual(sent.header("Accept"), "application/json")
        XCTAssertEqual(sent.header("X-Talqyn-SDK"), Talqyn.clientHeader)
    }

    /// Support cannot narrow a report to a build without this, so it travels on
    /// the mint too — the one request sent before there is any token.
    func testTheMintCarriesTheSDKVersion() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        let talqyn = TestFixtures.client(transport: transport)
        try await talqyn.prepare()

        let header = transport.sent[0].header("X-Talqyn-SDK")
        XCTAssertEqual(header, Talqyn.clientHeader)
        XCTAssertTrue(header?.hasSuffix("/" + Talqyn.version) == true, "got \(header ?? "nil")")
    }

    func testSearchPathsAndBodies() async throws {
        let transport = StubTransport()
        transport.enqueue(json: emptySearch)
        transport.enqueue(json: emptyListing)
        transport.enqueue(json: #"{"groups":[]}"#)

        let talqyn = try await TestFixtures.preparedClient(transport: transport)
        _ = try await talqyn.search.search("iphone")
        _ = try await talqyn.search.full(TalqynFullSearchQuery(query: "smartphone", sort: .priceAscending))
        _ = try await talqyn.search.filters(TalqynFiltersQuery(query: "smartphone"))

        XCTAssertEqual(transport.sent.map(\.path), ["/v1/search/", "/v1/search/full", "/v1/search/filters"])
        XCTAssertEqual(transport.sent[0].bodyJSON["query"] as? String, "iphone")
        XCTAssertEqual(transport.sent[1].bodyJSON["sort"] as? String, "price_asc")
    }

    func testListingWithFiltersSendsSameCriteria() async throws {
        let transport = StubTransport()
        transport.enqueue(json: emptyListing)
        transport.enqueue(json: #"{"groups":[]}"#)

        let talqyn = try await TestFixtures.preparedClient(transport: transport)
        let query = TalqynFullSearchQuery(
            query: "smartphone", limit: 24, filters: ["brand": ["apple"]], categoryID: 7
        )
        _ = try await talqyn.search.listingWithFilters(query)

        XCTAssertEqual(transport.sent.count, 2)
        let bodies = transport.sent.map(\.bodyJSON)
        for body in bodies {
            XCTAssertEqual(body["query"] as? String, "smartphone")
            XCTAssertEqual(body["category_id"] as? Int, 7)
            XCTAssertEqual((body["filters"] as? [String: [String]])?["brand"], ["apple"])
        }
    }

    /// The listing and its panel count against one place. A place changed
    /// while the pair is on its way reaches both requests or neither: the
    /// defaults are read once for the two.
    func testListingAndPanelTakeTheDefaultsFromOneRead() async throws {
        let listing = emptyListing
        let transport = ScriptedTransport { request in
            ScriptedTransport.json(request.url?.path.hasSuffix("/filters") == true ? #"{"groups":[]}"# : listing)
        }
        let talqyn = TestFixtures.client(transport: transport, cityID: "10")
        try await talqyn.prepare()

        // The shopper keeps switching cities while the pairs go out.
        let switching = Task.detached {
            var city = "10"
            while !Task.isCancelled {
                city = city == "10" ? "47" : "10"
                talqyn.setPlace(cityID: city)
            }
        }
        for _ in 0..<200 {
            _ = try await talqyn.search.listingWithFilters(TalqynFullSearchQuery(query: "smartphone"))
        }
        switching.cancel()
        await switching.value

        let cities = transport.sent.map { $0.bodyJSON["city_id"] as? String }
        XCTAssertEqual(cities.count, 400)
        let split = stride(from: 0, to: cities.count - 1, by: 2).filter { cities[$0] != cities[$0 + 1] }
        XCTAssertEqual(split.count, 0, "\(split.count) of 200 pairs counted against two places")
    }

    /// A panel that fails is reported at once, not once the listing has come
    /// back — and the listing, which nobody will show without its panel, is
    /// cancelled rather than fetched to the end.
    func testAFailedPanelFailsTheCallWithoutWaitingForTheListing() async throws {
        let listing = emptyListing
        let transport = ScriptedTransport { request in
            if request.url?.path.hasSuffix("/filters") == true {
                return ScriptedTransport.json(#"{"error":"internal_error"}"#, status: 500)
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return ScriptedTransport.json(listing)
        }
        let talqyn = TestFixtures.client(transport: transport)

        let started = Date()
        do {
            _ = try await talqyn.search.listingWithFilters(TalqynFullSearchQuery(query: "smartphone"))
            XCTFail("expected the panel's failure")
        } catch let error as TalqynError {
            XCTAssertEqual(error.statusCode, 500, "not the failure that came first: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the failure waited for the listing")
        XCTAssertEqual(transport.cancelledPaths, ["/v1/search/full"], "the listing was fetched for nobody")
    }

    func testConsultantJSONModeAddsStreamFalse() async throws {
        let transport = StubTransport()
        transport.enqueue(json: #"{"tenant_id":"t","answer":"answer","products":[]}"#)

        let talqyn = try await TestFixtures.preparedClient(transport: transport)
        let answer = try await talqyn.consultant.answer(TalqynConsultantQuery(question: "hi"))

        XCTAssertEqual(answer.answer, "answer")
        XCTAssertEqual(transport.sent[0].path, "/v1/consultant/ask")
        XCTAssertEqual(transport.sent[0].query, "stream=false")
    }

    func testChatEndpoints() async throws {
        let transport = StubTransport()
        transport.enqueue(json: "[]")
        transport.enqueue(json: #"{"session_id":"s1","messages":[],"products":[]}"#)
        transport.enqueue(json: "")

        let talqyn = try await TestFixtures.preparedClient(transport: transport)
        _ = try await talqyn.consultant.chats(limit: 5, offset: 10)
        _ = try await talqyn.consultant.chat(sessionID: "s1", locale: .kk)
        try await talqyn.consultant.deleteChat(sessionID: "s1")

        XCTAssertEqual(transport.sent[0].path, "/v1/consultant/chats")
        XCTAssertEqual(transport.sent[0].query, "limit=5&offset=10")
        XCTAssertEqual(transport.sent[0].request.httpMethod, "GET")
        XCTAssertEqual(transport.sent[1].path, "/v1/consultant/chats/s1")
        XCTAssertEqual(transport.sent[1].query, "locale=kk")
        XCTAssertEqual(transport.sent[2].request.httpMethod, "DELETE")
    }

    func testEventEndpoints() async throws {
        let transport = StubTransport()
        transport.enqueue(json: "", status: 204)
        transport.enqueue(json: "", status: 204)
        transport.enqueue(json: "", status: 204)

        let talqyn = try await TestFixtures.preparedClient(transport: transport)
        try await talqyn.events.productClick(
            .init(searchID: "s1", talqynID: 1, position: 0, source: .instant)
        )
        try await talqyn.events.searchSubmit(.init(query: "iphone", source: .instant, resultsCount: 8))
        try await talqyn.events.categoryClick(.init(categoryID: 42))

        XCTAssertEqual(transport.sent.map(\.path), [
            "/v1/events/product-click", "/v1/events/search", "/v1/events/category-click",
        ])
        XCTAssertEqual(transport.sent[1].bodyJSON["locale"] as? String, "en")
    }

    // MARK: - Defaults

    func testDefaultCityIsInjected() async throws {
        let transport = StubTransport()
        transport.enqueue(json: emptySearch)

        let talqyn = try await TestFixtures.preparedClient(transport: transport, cityID: "10")
        _ = try await talqyn.search.search("iphone")

        XCTAssertEqual(transport.sent[0].bodyJSON["city_id"] as? String, "10")
    }

    /// A store beats a city: pairing a default city with an explicitly named
    /// store (or the reverse) would override the shopper's choice.
    func testExplicitPlaceSuppressesDefaults() async throws {
        let transport = StubTransport()
        transport.enqueue(json: emptySearch)

        let talqyn = try await TestFixtures.preparedClient(transport: transport, cityID: "10")
        talqyn.setPlace(cityID: "10", locationID: "5")
        _ = try await talqyn.search.search(TalqynSearchQuery(query: "iphone", cityID: "47"))

        XCTAssertEqual(transport.sent[0].bodyJSON["city_id"] as? String, "47")
        XCTAssertNil(transport.sent[0].bodyJSON["location_id"])
    }

    func testSetPlaceAndLocaleAffectSubsequentRequests() async throws {
        let transport = StubTransport()
        transport.enqueue(json: emptySearch)
        transport.enqueue(json: #"{"tenant_id":"t","answer":"","products":[]}"#)

        let talqyn = try await TestFixtures.preparedClient(transport: transport)
        talqyn.setPlace(cityID: "10", locationID: "5")
        talqyn.setLocale(.kk)
        talqyn.setVariant("exp-b")

        _ = try await talqyn.search.search("iphone")
        _ = try await talqyn.consultant.answer(TalqynConsultantQuery(question: "hi"))

        let search = transport.sent[0].bodyJSON
        XCTAssertEqual(search["city_id"] as? String, "10")
        XCTAssertEqual(search["location_id"] as? String, "5")
        XCTAssertEqual(search["locale"] as? String, "kk")
        XCTAssertEqual(search["variant"] as? String, "exp-b")

        // Place and locale travel on every consultant turn: a session keeps neither.
        let ask = transport.sent[1].bodyJSON
        XCTAssertEqual(ask["city_id"] as? String, "10")
        XCTAssertEqual(ask["locale"] as? String, "kk")

        XCTAssertEqual(talqyn.currentLocale, .kk)
        XCTAssertEqual(talqyn.currentPlace.locationID, "5")
    }
}
