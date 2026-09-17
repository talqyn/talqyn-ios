#if os(iOS)
import UIKit
import XCTest
@testable import TalqynUI

@MainActor
final class ChipsFlowTests: XCTestCase {
    /// A 390pt screen, which is what the suggestions cell is handed.
    private let screenWidth: CGFloat = 390
    private var rowWidth: CGFloat { screenWidth - TalqynTurnContentView.horizontalMargin(.default) * 2 }

    // The window is held so it outlives the helper that lays the cell out, and
    // released in `tearDown` — which XCTest does not call on the main actor,
    // hence the opt-out. It is only ever touched from the main thread.
    nonisolated(unsafe) private var window: UIWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    /// The chips as the transcript builds them: in the real cell, in a live
    /// window, so the layout engine has its say about the chips' own sizes.
    private func laidOutCell(_ questions: [String]) -> TalqynSuggestionsCell {
        let cell = TalqynSuggestionsCell(frame: CGRect(x: 0, y: 0, width: screenWidth, height: 200))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: screenWidth, height: 400))
        window.addSubview(cell)
        window.isHidden = false
        self.window = window

        cell.configure(questions: questions, theme: .default, availableWidth: screenWidth) { _ in }
        window.layoutIfNeeded()
        // What the collection view does to size the cell — and what lets the
        // layout engine reach the chips and reassign the frames the flow view
        // set by hand.
        _ = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: screenWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        cell.setNeedsLayout()
        window.layoutIfNeeded()
        return cell
    }

    private func chips(in cell: UIView) -> [TalqynChipView] {
        var found: [TalqynChipView] = []
        for view in cell.subviews {
            if let chip = view as? TalqynChipView { found.append(chip) }
            found += chips(in: view)
        }
        return found
    }

    /// A follow-up longer than the row is what the consultant actually
    /// returns; the chip has to wrap inside the row rather than run off the
    /// screen.
    func testAChipTooLongForTheRowWraps() {
        let long = "does either of them open its door automatically at the end"
        let cell = laidOutCell(["what are the cheapest options available?", long])
        let laid = chips(in: cell)
        XCTAssertEqual(laid.count, 2)
        for chip in laid {
            XCTAssertLessThanOrEqual(
                chip.frame.width.rounded(), rowWidth,
                "\"\(chip.accessibilityLabel ?? "")\" is wider than the row"
            )
        }
        let longChip = laid.first { $0.accessibilityLabel == long }
        XCTAssertNotNil(longChip)
        XCTAssertGreaterThan(longChip?.frame.height ?? 0, 36, "the long chip should have wrapped onto a second line")
    }

    /// The bound must not squeeze chips that already fit: they keep hugging
    /// their text and share a row.
    func testShortChipsKeepTheirOwnWidthAndShareARow() {
        let laid = chips(in: laidOutCell(["Yes", "No"]))
        XCTAssertEqual(laid.count, 2)
        XCTAssertLessThan(laid[0].frame.width, rowWidth / 2)
        XCTAssertEqual(laid[0].frame.minY, laid[1].frame.minY)
        XCTAssertGreaterThan(laid[1].frame.minX, laid[0].frame.maxX)
    }
}
#endif
