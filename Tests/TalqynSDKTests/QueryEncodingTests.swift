import XCTest
import TalqynTestSupport
@testable import TalqynSDK

final class QueryEncodingTests: XCTestCase {
    private func encode(_ value: Encodable) throws -> [String: Any] {
        let data = try TalqynCoding.encoder.encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSearchQueryUsesContractFieldNames() throws {
        let json = try encode(TalqynSearchQuery(
            query: "iphone 15",
            locale: .ru,
            limit: 10,
            categoryID: 42,
            priceMin: 1000,
            cityID: "10",
            variant: "b"
        ))
        XCTAssertEqual(json["query"] as? String, "iphone 15")
        XCTAssertEqual(json["locale"] as? String, "ru")
        XCTAssertEqual(json["limit"] as? Int, 10)
        XCTAssertEqual(json["category_id"] as? Int, 42)
        XCTAssertEqual(json["price_min"] as? Double, 1000)
        XCTAssertEqual(json["city_id"] as? String, "10")
        XCTAssertEqual(json["in_stock_only"] as? Bool, false)
        XCTAssertEqual(json["variant"] as? String, "b")
        XCTAssertNil(json["brand_id"])
        XCTAssertNil(json["location_id"])
        XCTAssertNil(json["price_max"])
    }

    func testStartQueryUsesContractFieldNamesAndCarriesNoQuery() throws {
        let json = try encode(TalqynStartQuery(locale: .kk, limit: 8, cityID: "10", variant: "b"))
        XCTAssertEqual(json["locale"] as? String, "kk")
        XCTAssertEqual(json["limit"] as? Int, 8)
        XCTAssertEqual(json["city_id"] as? String, "10")
        XCTAssertEqual(json["variant"] as? String, "b")
        // An empty query is not a query: the endpoint has no such field, and
        // sending one would be a 422.
        XCTAssertNil(json["query"])
        XCTAssertNil(json["location_id"])
    }

    func testStartQueryDefaultsToTenProducts() throws {
        let json = try encode(TalqynStartQuery())
        XCTAssertEqual(json["limit"] as? Int, 10)
        XCTAssertEqual(json.count, 1)
    }

    func testFullSearchQueryOmitsEmptyFilters() throws {
        let bare = try encode(TalqynFullSearchQuery(query: "smartphone"))
        XCTAssertNil(bare["filters"])
        XCTAssertEqual(bare["sort"] as? String, "relevance")
        XCTAssertEqual(bare["offset"] as? Int, 0)
        XCTAssertEqual(bare["limit"] as? Int, 20)
        XCTAssertEqual(bare["has_discount"] as? Bool, false)

        let filtered = try encode(TalqynFullSearchQuery(
            query: "smartphone",
            limit: 24,
            sort: .priceAscending,
            filters: ["brand": ["apple", "samsung"]]
        ))
        XCTAssertEqual(filtered["sort"] as? String, "price_asc")
        XCTAssertEqual(filtered["limit"] as? Int, 24)
        let filters = filtered["filters"] as? [String: [String]]
        XCTAssertEqual(filters?["brand"], ["apple", "samsung"])
    }

    /// The filter panel counts against the same selection as the listing.
    func testFiltersQueryDerivedFromListingKeepsCriteria() throws {
        let listing = TalqynFullSearchQuery(
            query: "smartphone", limit: 24, offset: 48, sort: .priceDescending,
            filters: ["brand": ["apple"]], categoryID: 7, cityID: "10"
        )
        let json = try encode(listing.filtersQuery)
        XCTAssertEqual(json["query"] as? String, "smartphone")
        XCTAssertEqual(json["category_id"] as? Int, 7)
        XCTAssertEqual(json["city_id"] as? String, "10")
        XCTAssertEqual((json["filters"] as? [String: [String]])?["brand"], ["apple"])
        // The facet panel has no limit/offset/sort: it counts the whole selection.
        XCTAssertNil(json["limit"])
        XCTAssertNil(json["offset"])
        XCTAssertNil(json["sort"])
    }

    func testConsultantQueryFieldNames() throws {
        let json = try encode(TalqynConsultantQuery(
            question: "need a laptop", locale: .kk, sessionID: "abc12345", locationID: "77"
        ))
        XCTAssertEqual(json["question"] as? String, "need a laptop")
        XCTAssertEqual(json["locale"] as? String, "kk")
        XCTAssertEqual(json["session_id"] as? String, "abc12345")
        XCTAssertEqual(json["location_id"] as? String, "77")
        XCTAssertNil(json["city_id"])
    }

    func testEventEncoding() throws {
        let click = try encode(TalqynProductClickEvent(
            searchID: "6c5f2e8a", talqynID: 1234, position: 3, source: .consultant
        ))
        XCTAssertEqual(click["search_id"] as? String, "6c5f2e8a")
        XCTAssertEqual(click["talqyn_id"] as? Int, 1234)
        XCTAssertEqual(click["position"] as? Int, 3)
        XCTAssertEqual(click["source"] as? String, "cip")

        let submit = try encode(TalqynSearchSubmitEvent(
            query: "iphone", source: .instant, locale: .ru, resultsCount: 8
        ))
        XCTAssertEqual(submit["results_count"] as? Int, 8)
        XCTAssertEqual(submit["source"] as? String, "instant")

        let category = try encode(TalqynCategoryClickEvent(categoryID: 42, query: "iphone"))
        XCTAssertEqual(category["category_id"] as? Int, 42)
    }

    func testNextPageAdvancesOffset() {
        let query = TalqynFullSearchQuery(query: "smartphone", limit: 24)
        let response = try! TalqynCoding.decoder.decode(
            TalqynFullSearchResponse.self,
            from: Data(#"{"query":"smartphone","locale":"ru","offset":0,"limit":24,"sort":"relevance","total":50,"results":[]}"#.utf8)
        )
        XCTAssertNil(
            query.nextPage(after: response),
            "an empty page ends the listing, or pagination loops"
        )

        let withItems = try! TalqynCoding.decoder.decode(
            TalqynFullSearchResponse.self,
            from: Data(#"{"query":"s","locale":"ru","offset":0,"limit":2,"sort":"relevance","total":5,"results":[{"talqyn_id":1,"title":"a"},{"talqyn_id":2,"title":"b"}]}"#.utf8)
        )
        XCTAssertEqual(query.nextPage(after: withItems)?.offset, 2)
    }

    /// The catalog is translated into three languages; every other app language
    /// gets the default rather than a language the catalog is not written in.
    func testMatchingMapsAnAppLanguageOntoASupportedLocale() {
        XCTAssertEqual(TalqynLocale.matching(languageCode: "kk"), .kk)
        XCTAssertEqual(TalqynLocale.matching(languageCode: "kk-KZ"), .kk)
        XCTAssertEqual(TalqynLocale.matching(languageCode: "KK"), .kk)
        XCTAssertEqual(TalqynLocale.matching(languageCode: "ru-RU"), .ru)
        XCTAssertEqual(TalqynLocale.matching(languageCode: "en-US"), .en)
        XCTAssertEqual(TalqynLocale.matching(languageCode: "de"), .en)
        XCTAssertEqual(TalqynLocale.matching(languageCode: nil), .en)
    }
}
