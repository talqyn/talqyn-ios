#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import UIKit
import XCTest
@testable import TalqynUI

/// The room under the transcript changes with the composer and with the
/// keyboard it rides. What the shopper was looking at stays in view.
@MainActor
final class TranscriptKeyboardTests: XCTestCase {
    nonisolated(unsafe) private var window: UIWindow?
    private let composer: CGFloat = 120
    private let keyboard: CGFloat = 336

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + find(type, in: $0) }
    }

    private func turn(_ id: UUID, sentences: Int) -> TalqynTranscriptRow {
        let plain = Array(repeating: "A basic model with a manual frother that keeps the same tank.", count: sentences)
            .joined(separator: " ")
        return .assistant(TalqynTurnRow(
            turnID: id, question: "coffee", stage: nil, isStreaming: false,
            blocks: [.text(
                id: 0, content: NSAttributedString(string: plain, attributes: [.font: UIFont.systemFont(ofSize: 15)]), plain: plain
            )],
            catalog: [:], productSections: [], actions: [], clarify: nil, redirectQuery: nil, notice: nil,
            toolbar: .init(rating: nil, offeredReasons: [], selectedReasons: [], copyText: plain)
        ))
    }

    private func transcript(sentences: Int, anchor: TalqynTranscriptAnchor) throws -> (TalqynTranscriptView, UICollectionView) {
        let view = TalqynTranscriptView(theme: .default, strings: .en, price: .tenge, loader: TalqynURLImageLoader.shared)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        self.window = window
        view.bottomReserve = composer
        window.layoutIfNeeded()
        view.reload(rows: [.user(id: UUID(), text: "coffee"), turn(UUID(), sentences: sentences)], anchor: anchor)
        settle()
        return (view, try XCTUnwrap(find(UICollectionView.self, in: view).first))
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        window?.layoutIfNeeded()
    }

    /// How much of the end of the transcript is under the composer.
    private func hiddenTail(_ view: TalqynTranscriptView, _ collection: UICollectionView) -> CGFloat {
        let last = collection.visibleCells.map(\.frame.maxY).max() ?? 0
        return last - (collection.contentOffset.y + collection.bounds.height - view.bottomReserve)
    }

    /// A shopper at the end of the conversation taps the field: the last
    /// answer moves up with the keyboard rather than under it, and comes back
    /// down with it, with no room left over to scroll into.
    func testTheEndOfTheTranscriptStaysInViewAsTheKeyboardComesAndGoes() throws {
        let (view, collection) = try transcript(sentences: 40, anchor: .bottom)
        XCTAssertLessThanOrEqual(hiddenTail(view, collection), 0.5)

        view.bottomReserve = composer + keyboard
        settle()
        XCTAssertLessThanOrEqual(hiddenTail(view, collection), 0.5, "the keyboard covers the end of the answer")
        XCTAssertTrue(view.isPinnedToBottom)

        view.bottomReserve = composer
        settle()
        XCTAssertLessThanOrEqual(hiddenTail(view, collection), 0.5)
        XCTAssertTrue(view.isPinnedToBottom)
        XCTAssertEqual(collection.contentInset.bottom, composer, accuracy: 0.5, "the keyboard's room outlived the keyboard")
    }

    /// One reading somewhere above the end is left where they are.
    func testAShopperReadingAboveTheEndIsNotMoved() throws {
        let (view, collection) = try transcript(sentences: 60, anchor: .bottom)
        collection.delegate?.scrollViewWillBeginDragging?(collection)
        collection.contentOffset.y = 100
        collection.delegate?.scrollViewDidScroll?(collection)
        collection.delegate?.scrollViewDidEndDragging?(collection, willDecelerate: false)
        settle()
        XCTAssertFalse(view.isPinnedToBottom)

        view.bottomReserve = composer + keyboard
        settle()
        XCTAssertEqual(collection.contentOffset.y, 100, accuracy: 0.5)

        view.bottomReserve = composer
        settle()
        XCTAssertEqual(collection.contentOffset.y, 100, accuracy: 0.5)
        XCTAssertEqual(collection.contentInset.bottom, composer, accuracy: 0.5)
    }

    /// A question pinned to the top of the screen keeps its place: the
    /// shopper reads the answer from its start, keyboard or not.
    func testAPinnedQuestionKeepsItsPlace() throws {
        let (view, collection) = try transcript(sentences: 3, anchor: .newestTurn)
        let pinned = collection.contentOffset.y

        view.bottomReserve = composer + keyboard
        settle()
        XCTAssertEqual(collection.contentOffset.y, pinned, accuracy: 0.5)

        view.bottomReserve = composer
        settle()
        XCTAssertEqual(collection.contentOffset.y, pinned, accuracy: 0.5)
    }
}
#endif
