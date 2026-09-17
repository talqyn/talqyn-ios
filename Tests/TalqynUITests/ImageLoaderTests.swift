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
}
#endif
