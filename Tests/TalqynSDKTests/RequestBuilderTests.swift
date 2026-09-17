import XCTest
import TalqynTestSupport
@testable import TalqynSDK

final class RequestBuilderTests: XCTestCase {
    private func builder(_ base: String, version: String = "v1") -> TalqynRequestBuilder {
        TalqynRequestBuilder(baseURL: URL(string: base)!, apiVersion: version, timeout: 30)
    }

    /// The SDK carries no endpoint of its own: the host of the configuration is
    /// the only one there is, and the token mint goes there too — the minter and
    /// the API calls share one builder.
    func testConfiguredHostIsWhereEveryRequestGoes() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        let talqyn = TestFixtures.client(
            transport: transport, baseURL: URL(string: "https://gateway.example.com/talqyn")!
        )
        transport.enqueue(json: #"{"search_id":"s","query":"x","locale":"ru","total":0,"results":[]}"#)
        _ = try await talqyn.search.search("iphone")

        XCTAssertEqual(
            transport.sent.map { $0.request.url?.absoluteString },
            [
                "https://gateway.example.com/talqyn/v1/consultant/token",
                "https://gateway.example.com/talqyn/v1/search/",
            ]
        )
    }

    /// A stand is addressed by its own URL, and requests are built against it.
    func testGivenBaseURLIsBuiltAgainst() throws {
        let stand = URL(string: "https://gateway.example.com/talqyn")!
        let configuration = TalqynConfiguration(
            baseURL: stand,
            credentials: .init(storefront: "myshop", clientKeyID: "ck_1", clientSecret: "s")
        )
        XCTAssertEqual(configuration.baseURL, stand)
        let url = try builder(configuration.baseURL.absoluteString).url(path: "search/")
        XCTAssertEqual(url.absoluteString, "https://gateway.example.com/talqyn/v1/search/")
    }

    /// The trailing slash of instant search is part of the endpoint address.
    func testInstantSearchPathKeepsTrailingSlash() throws {
        let url = try builder("https://api.example.com").url(path: "search/")
        XCTAssertEqual(url.absoluteString, "https://api.example.com/v1/search/")
    }

    func testBaseWithTrailingSlashDoesNotDoubleUp() throws {
        let url = try builder("https://api.example.com/").url(path: "search/full")
        XCTAssertEqual(url.absoluteString, "https://api.example.com/v1/search/full")
    }

    func testBaseWithPathPrefixIsPreserved() throws {
        let url = try builder("https://gateway.example.com/talqyn").url(path: "consultant/ask")
        XCTAssertEqual(url.absoluteString, "https://gateway.example.com/talqyn/v1/consultant/ask")
    }

    func testEmptyVersionSkipsSegment() throws {
        let url = try builder("https://api.example.com", version: "").url(path: "search/")
        XCTAssertEqual(url.absoluteString, "https://api.example.com/search/")
    }

    func testQueryItemsAreEncoded() throws {
        let url = try builder("https://api.example.com").url(
            path: "consultant/chats", query: [URLQueryItem(name: "limit", value: "20")]
        )
        XCTAssertEqual(url.absoluteString, "https://api.example.com/v1/consultant/chats?limit=20")
    }

    /// A gateway may be addressed with a query of its own; it must survive.
    func testBaseURLQueryIsKeptAheadOfRequestItems() throws {
        let url = try builder("https://gw.example.com/talqyn?key=abc").url(
            path: "consultant/chats", query: [URLQueryItem(name: "limit", value: "20")]
        )
        XCTAssertEqual(url.absoluteString, "https://gw.example.com/talqyn/v1/consultant/chats?key=abc&limit=20")

        let bare = try builder("https://gw.example.com/talqyn?key=abc").url(path: "search/")
        XCTAssertEqual(bare.absoluteString, "https://gw.example.com/talqyn/v1/search/?key=abc")
    }

    func testSessionIDIsEscapedIntoPath() throws {
        let url = try builder("https://api.example.com").url(path: "consultant/chats/a b?c")
        XCTAssertEqual(url.absoluteString, "https://api.example.com/v1/consultant/chats/a%20b%3Fc")
    }

    func testRequestCarriesJSONContentTypeOnlyWithBody() throws {
        let withBody = try builder("https://api.example.com").request(
            method: "POST", path: "search/", body: Data("{}".utf8)
        )
        XCTAssertEqual(withBody.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let withoutBody = try builder("https://api.example.com").request(
            method: "GET", path: "consultant/chats"
        )
        XCTAssertNil(withoutBody.value(forHTTPHeaderField: "Content-Type"))
    }
}
