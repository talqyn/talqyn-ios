import XCTest
import TalqynTestSupport
@testable import TalqynSDK

/// Responses are taken from the contract (`docs/public_api.md`): this test pins
/// the models to it.
final class DecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TalqynCoding.decoder.decode(type, from: Data(json.utf8))
    }

    func testInstantSearchResponse() throws {
        let response = try decode(TalqynSearchResponse.self, """
        {
          "search_id": "6c5f2e8a-0000-4000-8000-000000000000",
          "query": "iphone 15", "locale": "ru", "total": 8,
          "results": [{
            "talqyn_id": 1234, "external_id": "256073",
            "title": "Apple iPhone 15 128GB",
            "slug": "apple-iphone-15-128gb", "brand_name": "Apple",
            "brand_id": 7, "brand_slug": "apple", "brand_logo_url": null,
            "category_path": ["Phones and gadgets", "Phones"],
            "price": 449990, "price_before": 479990, "in_stock": true,
            "rating": 4.8, "reviews_count": 213,
            "image_url": "https://cdn.example.com/1.jpg", "url": "https://shop.example.com/p/1",
            "score": 0.87
          }],
          "suggestions": [{"text": "iphone 15 pro", "weight": 12, "highlight_from": 9}],
          "chips": [{"text": "Apple", "weight": 5}],
          "showcase": [{"text": "headphones", "weight": 3, "highlight_from": 0}],
          "categories": [{"id": 42, "name": "Phones", "slug": "smartfony", "path": "1.42", "parent_name": "Phones and gadgets"}],
          "brands": [{"id": 7, "name": "Apple", "slug": "apple", "logo_url": null}],
          "history": ["headphones"],
          "corrected_from": "iphone15"
        }
        """)

        XCTAssertEqual(response.searchID, "6c5f2e8a-0000-4000-8000-000000000000")
        XCTAssertEqual(response.total, 8)
        XCTAssertEqual(response.correctedFrom, "iphone15")
        XCTAssertEqual(response.history, ["headphones"])
        // showcase carries suggestions, not products.
        XCTAssertEqual(response.showcase.first?.text, "headphones")
        XCTAssertEqual(response.suggestions.first?.highlightFrom, 9)
        XCTAssertEqual(response.categories.first?.parentName, "Phones and gadgets")

        let product = try XCTUnwrap(response.results.first)
        XCTAssertEqual(product.talqynID, 1234)
        XCTAssertEqual(product.externalID, "256073")
        XCTAssertEqual(product.brandSlug, "apple")
        XCTAssertEqual(product.categoryPath.count, 2)
        XCTAssertEqual(product.price, 449_990)
        XCTAssertEqual(product.inStock, true)
        XCTAssertTrue(product.hasDiscount)
        XCTAssertEqual(product.imageURL?.absoluteString, "https://cdn.example.com/1.jpg")
        XCTAssertEqual(product.productURL?.absoluteString, "https://shop.example.com/p/1")
        XCTAssertNil(product.brandLogoURL)
    }

    func testProductAcceptsLegacyProductIDAlias() throws {
        let product = try decode(TalqynProduct.self, #"{"product_id": 55, "title": "x"}"#)
        XCTAssertEqual(product.talqynID, 55)
        XCTAssertNil(product.inStock, "a card that does not mention stock is not out of stock")
        XCTAssertEqual(product.reviewsCount, 0)
        XCTAssertNil(product.price)
        XCTAssertFalse(product.hasDiscount)
    }

    func testProductWithoutIdentifierIsRejected() {
        XCTAssertThrowsError(try decode(TalqynProduct.self, #"{"title": "x"}"#))
    }

    /// One malformed card costs that card, not the page it came in.
    func testMalformedCardIsDroppedNotThePage() throws {
        let response = try decode(TalqynSearchResponse.self, """
        {"search_id": "s", "query": "x", "locale": "ru", "total": 4,
         "results": [
           {"talqyn_id": 1, "title": "a"},
           {"title": "no identifier"},
           null,
           "not even an object",
           {"talqyn_id": 2, "title": "b"}
         ]}
        """)
        XCTAssertEqual(response.results.map(\.talqynID), [1, 2])
        XCTAssertEqual(response.total, 4)
    }

    func testProductURLWithCyrillicPath() throws {
        let product = try decode(TalqynProduct.self, #"{"talqyn_id":1,"title":"x","url":"https://shop.kz/товар/1"}"#)
        XCTAssertNotNil(product.productURL)
    }

    /// Catalog URLs are taken leniently, byte for byte the way the Android SDK
    /// takes them: what a URL may not carry is percent-encoded, an escape
    /// already in place is kept rather than encoded again, a second `#` is part
    /// of the fragment, and a URL that is valid as written comes back as
    /// written.
    func testCatalogURLsAreEncodedOnceAndTheSameOnBothPlatforms() {
        let cases: [(raw: String, expected: String)] = [
            ("https://x.kz/img 50%.jpg", "https://x.kz/img%2050%25.jpg"),
            ("https://cdn.kz/img[1].jpg", "https://cdn.kz/img%5B1%5D.jpg"),
            ("https://x/a#b#c", "https://x/a#b%23c"),
            ("https://x/a%20b c.jpg", "https://x/a%20b%20c.jpg"),
            ("https://x.kz/фото 1.jpg", "https://x.kz/%D1%84%D0%BE%D1%82%D0%BE%201.jpg"),
            ("https://cdn.example.com/a%20b.jpg?w=200&h=100#top", "https://cdn.example.com/a%20b.jpg?w=200&h=100#top"),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(TalqynProduct.url(raw)?.absoluteString, expected, raw)
        }
    }

    func testFiltersResponseGroupsAndPlaceHelpers() throws {
        let response = try decode(TalqynFiltersResponse.self, """
        {"groups": [
          {"slug": "brand", "label": "Brand", "type": "list",
           "options": [
             {"slug": "apple", "label": "Apple", "count": 42, "state": "active"},
             {"slug": "samsung", "label": "Samsung", "count": 0, "state": "disabled"}
           ]},
          {"slug": "price", "label": "Price", "type": "range",
           "options": [], "min": 15000, "max": 890000, "selected_min": null, "selected_max": null},
          {"slug": "city", "label": "City", "type": "list",
           "options": [{"slug": "almaty", "label": "Almaty", "id": "10", "count": 297, "state": "enabled"}]},
          {"slug": "location", "label": "Store", "type": "list",
           "options": [{"slug": "5", "label": "Mega Mall", "id": "2f5f", "city_slug": "almaty", "count": 12, "state": "enabled"}]}
        ]}
        """)

        XCTAssertEqual(response.groups.count, 4)
        XCTAssertEqual(response.panelGroups.map(\.slug), ["brand", "price"])
        XCTAssertEqual(response.priceGroup?.min, 15000)
        XCTAssertEqual(response.priceGroup?.type, .range)
        XCTAssertEqual(response.cityGroup?.options.first?.id, "10")
        XCTAssertEqual(response.locationGroup?.options.first?.citySlug, "almaty")
        XCTAssertEqual(response.selectedFilters, ["brand": ["apple"]])

        let samsung = try XCTUnwrap(response.group("brand")?.options.last)
        XCTAssertTrue(samsung.isDisabled)
        XCTAssertFalse(samsung.isSelected)
    }

    func testUnknownFilterKindAndStateSurviveDecoding() throws {
        let response = try decode(TalqynFiltersResponse.self, """
        {"groups": [{"slug": "x", "type": "colorpicker",
          "options": [{"slug": "a", "state": "highlighted"}]}]}
        """)
        XCTAssertEqual(response.groups.first?.type.rawValue, "colorpicker")
        XCTAssertEqual(response.groups.first?.options.first?.state.rawValue, "highlighted")
    }

    func testConsultantJSONAnswer() throws {
        let answer = try decode(TalqynConsultantAnswer.self, """
        {"tenant_id": "3f2a", "answer": "Here are the options [p:1]", "session_id": "a1b2c3d4",
         "products": [{"talqyn_id": 1, "title": "Laptop"}],
         "fallback_reason": null, "clarify": null, "groups": null,
         "redirect_query": null, "actions": [
            {"type": "apply_filters", "filters": {"category_id": 5, "filters": {"ram": ["16"]}, "attrs": {"ram": "16"}}}
         ],
         "follow_ups": ["show cheaper ones"], "search_id": "s1"}
        """)
        XCTAssertEqual(answer.sessionID, "a1b2c3d4")
        XCTAssertEqual(answer.products.count, 1)
        XCTAssertEqual(answer.followUps, ["show cheaper ones"])
        XCTAssertFalse(answer.isFallback)

        guard case let .applyFilters(filters) = answer.actions.first else {
            return XCTFail("expected an apply_filters action")
        }
        XCTAssertEqual(filters.categoryID, 5)
        XCTAssertEqual(filters.filters["ram"], ["16"])
        XCTAssertEqual(filters.attributes["ram"], "16")

        let criteria = filters.criteria(query: "laptop", cityID: "10")
        XCTAssertEqual(criteria.query, "laptop")
        XCTAssertEqual(criteria.categoryID, 5)
        XCTAssertEqual(criteria.cityID, "10")
    }

    func testFallbackAnswerCarriesReason() throws {
        let answer = try decode(TalqynConsultantAnswer.self, """
        {"tenant_id": "3f2a", "answer": "", "products": [], "fallback_reason": "user_budget_exceeded"}
        """)
        XCTAssertTrue(answer.isFallback)
        XCTAssertEqual(answer.fallbackReason, .userBudgetExceeded)
        XCTAssertEqual(answer.fallbackReason?.isBudgetExhausted, true)
    }

    func testChatTranscriptHydratesProductsPerMessage() throws {
        let transcript = try decode(TalqynChatTranscript.self, """
        {"session_id": "s1", "title": "laptop for school",
         "messages": [
           {"role": "user", "text": "need a laptop", "talqyn_ids": [], "route": "consult", "created_at": "2026-08-26T12:00:00Z"},
           {"role": "assistant", "text": "here", "talqyn_ids": [2, 1], "created_at": "2026-08-26T12:00:03.512Z"}
         ],
         "products": [{"talqyn_id": 1, "title": "A"}, {"talqyn_id": 2, "title": "B"}]}
        """)
        XCTAssertEqual(transcript.messages.count, 2)
        XCTAssertEqual(transcript.messages[0].route, .consult)
        XCTAssertFalse(transcript.messages[0].isRedirect)
        XCTAssertNotNil(transcript.messages[0].createdAt)
        // Postgres fractional seconds parse too.
        XCTAssertNotNil(transcript.messages[1].createdAt)
        XCTAssertEqual(transcript.products(for: transcript.messages[1]).map(\.title), ["B", "A"])
    }

    func testChatSummaryList() throws {
        let chats = try decode([TalqynChatSummary].self, """
        [{"session_id": "s1", "title": null, "message_count": 4,
          "created_at": "2026-08-26T12:00:00Z", "last_message_at": "2026-08-26T12:10:00Z"}]
        """)
        XCTAssertEqual(chats.first?.messageCount, 4)
        XCTAssertNil(chats.first?.title)
        XCTAssertNotNil(chats.first?.lastMessageAt)
    }

    func testDeviceTokenResponse() throws {
        let token = try decode(TalqynDeviceToken.self, """
        {"token": "tlqd_eyJ", "expires_at": "2026-08-26T12:15:00Z", "expires_in": 900,
         "user_id": "6f1c2b9a-3e47-4b8f-9a10-2c5d8e7f4a01"}
        """)
        XCTAssertEqual(token.token, "tlqd_eyJ")
        XCTAssertEqual(token.expiresIn, 900)
        XCTAssertNotNil(token.expiresAt)
        XCTAssertEqual(token.userID, "6f1c2b9a-3e47-4b8f-9a10-2c5d8e7f4a01")
    }
}
