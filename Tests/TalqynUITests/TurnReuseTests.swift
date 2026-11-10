#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import UIKit
import XCTest
@testable import TalqynUI

/// A cell is handed another turn every time one scrolls into view, and keeps
/// the views of the turn before to draw the next one with. What it then shows
/// has to be the new turn and nothing of the old.
@MainActor
final class TurnReuseTests: XCTestCase {
    nonisolated(unsafe) private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func find<T>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + find(type, in: $0) }
    }

    private func product(_ id: Int) -> TalqynProduct {
        TalqynProduct(talqynID: id, title: "Product \(id)", price: Double(1000 * id))
    }

    private func text(_ id: Int, _ plain: String) -> TalqynTurnRow.Block {
        .text(id: id, content: NSAttributedString(string: plain, attributes: [.font: UIFont.systemFont(ofSize: 15)]), plain: plain)
    }

    private func row(_ name: String, cited: [[Int]], carousel: [Int]) -> TalqynTurnRow {
        var blocks: [TalqynTurnRow.Block] = []
        for (index, ids) in cited.enumerated() {
            blocks.append(text(index * 2, "\(name) paragraph \(index)"))
            blocks.append(.products(id: index * 2 + 1, items: ids.map(product)))
        }
        blocks.append(text(cited.count * 2, "\(name) closing"))
        return TalqynTurnRow(
            turnID: UUID(), question: name, stage: nil, isStreaming: false, blocks: blocks, catalog: [:],
            productSections: carousel.isEmpty ? [] : [.init(title: "\(name) more", products: carousel.map(product))],
            actions: [], clarify: nil, redirectQuery: nil, notice: nil,
            toolbar: .init(rating: nil, offeredReasons: [], selectedReasons: [], copyText: name)
        )
    }

    private func turnView() -> TalqynTurnContentView {
        let view = TalqynTurnContentView(theme: .default, strings: .en, price: .tenge, loader: TalqynURLImageLoader.shared)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.addSubview(view)
        window.isHidden = false
        self.window = window
        return view
    }

    private func show(_ row: TalqynTurnRow, in view: TalqynTurnContentView) {
        view.prepareForReuse()
        view.update(row: row, delegate: nil, availableWidth: 390)
        view.frame.size = view.systemLayoutSizeFitting(
            CGSize(width: 390, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        view.layoutIfNeeded()
    }

    /// What the view shows, top to bottom: its paragraphs and the products of
    /// its cards, cited and in the carousel.
    private func shown(_ view: TalqynTurnContentView) -> (texts: [String], cited: [Int], carousel: [Int]) {
        let texts = find(UITextView.self, in: view).sorted { $0.convert(CGPoint.zero, to: view).y < $1.convert(CGPoint.zero, to: view).y }
        let carousel = find(TalqynCompactProductRowView.self, in: view).flatMap { find(TalqynProductCardView.self, in: $0) }
        let cards = find(TalqynProductCardView.self, in: view)
            .filter { card in !carousel.contains { $0 === card } }
            .sorted { $0.convert(CGPoint.zero, to: view).y < $1.convert(CGPoint.zero, to: view).y }
        return (
            texts.map { $0.attributedText.string },
            cards.compactMap { $0.product?.talqynID },
            carousel.sorted { $0.frame.minX < $1.frame.minX }.compactMap { $0.product?.talqynID }
        )
    }

    func testAReusedViewShowsTheNewTurnAndNothingOfTheOld() {
        let view = turnView()
        let long = row("long", cited: [[1], [2, 3], [4, 5, 6]], carousel: [7, 8, 9, 10])
        let short = row("short", cited: [[11]], carousel: [12])
        let bare = row("bare", cited: [], carousel: [])

        for turn in [long, short, long, bare, short, long] {
            show(turn, in: view)
            let seen = shown(view)
            let expectedTexts = turn.blocks.compactMap { block -> String? in
                if case let .text(_, _, plain) = block { return plain }
                return nil
            }
            let expectedCited = turn.blocks.flatMap { block -> [Int] in
                if case let .products(_, items) = block { return items.map(\.talqynID) }
                return []
            }
            XCTAssertEqual(seen.texts, expectedTexts, turn.question)
            XCTAssertEqual(seen.cited.sorted(), expectedCited.sorted(), turn.question)
            XCTAssertEqual(seen.carousel, turn.productSections.flatMap { $0.products.map(\.talqynID) }, turn.question)
        }
    }

    /// The point of keeping the views: a turn drawn where another was reuses
    /// them rather than making its own.
    func testAReusedViewDrawsTheNextTurnWithTheViewsItHas() {
        let view = turnView()
        show(row("first", cited: [[1], [2]], carousel: [3, 4]), in: view)
        let texts = Set(find(UITextView.self, in: view).map(ObjectIdentifier.init))
        let cards = Set(find(TalqynProductCardView.self, in: view).map(ObjectIdentifier.init))

        show(row("second", cited: [[5], [6]], carousel: [7, 8]), in: view)
        XCTAssertEqual(Set(find(UITextView.self, in: view).map(ObjectIdentifier.init)), texts)
        XCTAssertEqual(Set(find(TalqynProductCardView.self, in: view).map(ObjectIdentifier.init)), cards)
    }

    /// A card that changes hands opens the product it shows now.
    func testAReusedCardOpensItsNewProduct() {
        final class Taps: TalqynTurnViewDelegate {
            var opened: [Int] = []
            func turnDidTapProduct(_ product: TalqynProduct, turnID: UUID) { opened.append(product.talqynID) }
            func turnCardView(for product: TalqynProduct, layout: TalqynProductCardLayout) -> UIView? { nil }
            func turnDidTapRetry(turnID: UUID) {}
            func turnDidTapRedirect(query: String) {}
            func turnDidTapFilters(_ filters: TalqynActionFilters, question: String) {}
            func turnDidTapComparison(_ table: TalqynComparisonTable, turnID: UUID) {}
            func turnDidSubmitClarify(answer: String, turnID: UUID) {}
            func turnDidUpdateClarifyDraft(_ draft: TalqynClarifyDraft, turnID: UUID) {}
            func turnDidTapSuggestion(_ text: String) {}
            func turnDidRate(_ rating: TalqynAnswerRating?, reasons: [TalqynFeedbackReason], turnID: UUID) {}
            func turnDidRequestEdit(question: String) {}
        }
        let taps = Taps()
        let view = turnView()
        view.update(row: row("first", cited: [[1]], carousel: [2]), delegate: taps, availableWidth: 390)
        view.prepareForReuse()
        view.update(row: row("second", cited: [[5]], carousel: [6]), delegate: taps, availableWidth: 390)

        for card in find(TalqynProductCardView.self, in: view) { card.onTap?() }
        XCTAssertEqual(taps.opened.sorted(), [5, 6])
    }

    /// The tiles of a carousel end on one line and keep their prices on one,
    /// however long each title is.
    func testCarouselTilesShareAHeight() throws {
        let view = turnView()
        let short = TalqynProduct(talqynID: 1, title: "Acer", price: 100_000)
        let long = TalqynProduct(talqynID: 2, title: "Coffee machine Delonghi Magnifica S ECAM-21.117.SB", price: 200_000)
        let turn = TalqynTurnRow(
            turnID: UUID(), question: "q", stage: nil, isStreaming: false, blocks: [text(0, "Two of them.")], catalog: [:],
            productSections: [.init(title: "More", products: [short, long])],
            actions: [], clarify: nil, redirectQuery: nil, notice: nil, toolbar: nil
        )
        show(turn, in: view)

        let tiles = find(TalqynProductCardView.self, in: view).sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(tiles[0].frame.height, tiles[1].frame.height, accuracy: 0.5)
        let prices = tiles.map { tile -> CGFloat in
            let label = find(UILabel.self, in: tile).first { $0.text?.contains("000") == true }
            return label?.convert(CGPoint.zero, to: view).y ?? -1
        }
        XCTAssertGreaterThan(prices[0], 0)
        XCTAssertEqual(prices[0], prices[1], accuracy: 0.5, "the prices are on different lines")
    }
}
#endif
