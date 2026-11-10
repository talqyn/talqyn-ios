#if os(iOS)
import SwiftUI
import TalqynConsultantCore
import TalqynSDK
import TalqynTestSupport
import UIKit
import XCTest
@testable import TalqynUI

@MainActor
final class ImageLoaderTests: XCTestCase {
    /// A property a type keeps to itself, read the way `dump` reads it.
    private func stored(_ label: String, of subject: Any) -> AnyObject? {
        guard let value = Mirror(reflecting: subject).children.first(where: { $0.label == label })?.value else {
            return nil
        }
        return value as AnyObject
    }

    /// Every screen built without a loader of the app's shares one, and its
    /// memory cache with it: a card seen in the consultant does not load and
    /// fade in again in the comparison opened from it, or on the next
    /// consultant screen.
    func testScreensShareOneLoaderByDefault() {
        let talqyn = TestFixtures.client(transport: StubTransport())
        let conversation = TalqynConversation(talqyn: talqyn)
        let shared = TalqynURLImageLoader.shared

        XCTAssertTrue(TalqynConsultantViewController(talqyn: talqyn).imageLoader as AnyObject === shared)
        XCTAssertTrue(TalqynConsultantViewController(conversation: conversation).imageLoader as AnyObject === shared)
        let comparison = TalqynComparisonViewController(table: TalqynComparisonTable(), products: [:]) { _ in }
        XCTAssertTrue(stored("loader", of: comparison) === shared, "the comparison keeps a cache of its own")
        let view = TalqynConsultantView(
            conversation: conversation, onOpenProduct: { _ in }, onOpenSearch: { _ in }, onApplyFilters: { _ in }
        )
        XCTAssertTrue(stored("imageLoader", of: view) === shared, "the SwiftUI screen keeps a cache of its own")
    }

    /// A catalog's picture is made for a product page; a card shows it a few
    /// times smaller. The loader keeps it at the size the screens draw, not
    /// at the size it came — decoded whole, a screenful of them is hundreds
    /// of megabytes.
    func testALargeImageIsKeptAtTheSizeTheScreensDraw() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PictureProtocol.self]
        let session = URLSession(configuration: configuration)

        let bounded = TalqynURLImageLoader(session: session)
        let large = try await bounded.image(for: try XCTUnwrap(URL(string: "https://img.example.com/2000x1000.png")))
        XCTAssertEqual(large.size.width * large.scale, TalqynURLImageLoader.defaultMaxPixelSize, accuracy: 1)
        XCTAssertEqual(large.size.height * large.scale, TalqynURLImageLoader.defaultMaxPixelSize / 2, accuracy: 1)

        let small = try await bounded.image(for: try XCTUnwrap(URL(string: "https://img.example.com/300x200.png")))
        XCTAssertEqual(small.size.width * small.scale, 300, accuracy: 1, "an image that fits is left alone")

        let whole = TalqynURLImageLoader(session: session, maxPixelSize: 0)
        let untouched = try await whole.image(for: try XCTUnwrap(URL(string: "https://img.example.com/2000x1000.png")))
        XCTAssertEqual(untouched.size.width * untouched.scale, 2000, accuracy: 1)
    }
}

/// Answers every request with a picture of the size its address names.
private final class PictureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let name = request.url?.deletingPathExtension().lastPathComponent ?? "1x1"
        let sides = name.split(separator: "x").compactMap { Int($0) }
        let size = CGSize(width: sides.first ?? 1, height: sides.last ?? 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
