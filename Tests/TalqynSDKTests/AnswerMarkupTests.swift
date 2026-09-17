import XCTest
import TalqynTestSupport
@testable import TalqynSDK

final class AnswerMarkupTests: XCTestCase {
    func testSegmentsSplitTextAndProducts() {
        let segments = TalqynAnswerMarkup.segments("Take [p:1234] — it is quieter than [p:99].")
        XCTAssertEqual(segments, [
            .text("Take "),
            .product(talqynID: 1234),
            .text(" — it is quieter than "),
            .product(talqynID: 99),
            .text("."),
        ])
    }

    func testTextWithoutMarkersIsOneSegment() {
        XCTAssertEqual(TalqynAnswerMarkup.segments("plain text"), [.text("plain text")])
        XCTAssertEqual(TalqynAnswerMarkup.segments(""), [])
    }

    func testMarkerAtBothEnds() {
        XCTAssertEqual(
            TalqynAnswerMarkup.segments("[p:1] and [p:2]"),
            [.product(talqynID: 1), .text(" and "), .product(talqynID: 2)]
        )
    }

    func testStrippedRemovesMarkers() {
        XCTAssertEqual(TalqynAnswerMarkup.stripped("Take [p:1234]."), "Take .")
    }

    func testMentionedIDsInOrder() {
        XCTAssertEqual(TalqynAnswerMarkup.mentionedProductIDs("[p:3] [p:1] [p:3]"), [3, 1, 3])
    }

    func testMalformedMarkerStaysText() {
        XCTAssertEqual(TalqynAnswerMarkup.segments("[p:abc]"), [.text("[p:abc]")])
    }
}
