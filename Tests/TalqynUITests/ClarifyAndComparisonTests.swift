#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import TalqynTestSupport
import UIKit
import XCTest
@testable import TalqynUI

/// The screens the consultant brings up over the transcript: the clarifying
/// questions and the comparison.
@MainActor
final class ClarifyAndComparisonTests: XCTestCase {
    nonisolated(unsafe) private var window: UIWindow?

    override func tearDown() async throws {
        await MainActor.run {
            window?.isHidden = true
            window = nil
        }
        try await super.tearDown()
    }

    private func find<T>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + find(type, in: $0) }
    }

    private func show(_ screen: UIViewController, width: CGFloat = 390) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        self.window = window
    }

    // MARK: - Clarify

    /// A detent is a height inside the sheet's safe area: the system adds the
    /// home indicator's strip itself. Counted into the sheet's own height as
    /// well, it showed up as a blank band between the field and the buttons.
    func testTheClarifySheetIsAsTallAsItsContentWhateverTheSafeArea() throws {
        func height(safeAreaBottom: CGFloat) throws -> CGFloat {
            let sheet = TalqynClarifySheetViewController(
                theme: .default, strings: .en,
                clarify: TalqynClarify(message: "A couple of details", questions: [
                    .init(id: "budget", label: "Budget", options: ["under 120 000 ₸", "120–450 000 ₸", "over 450 000 ₸"]),
                    .init(id: "brand", label: "Brand", options: ["Samsung", "Apple", "Xiaomi"]),
                ]),
                draft: TalqynClarifyDraft(), onDraftChange: { _ in }, onSubmit: { _ in }
            )
            sheet.additionalSafeAreaInsets.bottom = safeAreaBottom
            show(sheet)
            XCTAssertGreaterThanOrEqual(sheet.view.safeAreaInsets.bottom, safeAreaBottom)
            let field = try XCTUnwrap(find(UITextField.self, in: sheet.view).first)
            let actions = try XCTUnwrap(find(TalqynPillButton.self, in: sheet.view).first?.superview?.superview)
            let fieldBottom = field.convert(field.bounds, to: field.superview?.superview).maxY
            XCTAssertEqual(sheet.contentDetentHeight, 24 + fieldBottom + 24 + actions.bounds.height, accuracy: 1)
            return sheet.contentDetentHeight
        }
        let plain = try height(safeAreaBottom: 0)
        let withHomeIndicator = try height(safeAreaBottom: 34)
        XCTAssertGreaterThan(plain, 100)
        XCTAssertEqual(withHomeIndicator, plain, accuracy: 0.5, "the safe area was counted into the sheet's height")
    }

    /// A chip stays the chip it was when it is tapped: only its selection
    /// changes. Replaced by a new one, it would drop VoiceOver's cursor and
    /// whatever else was holding on to it.
    func testChoosingAnOptionKeepsTheChips() throws {
        let clarify = TalqynClarify(message: "A couple of details", questions: [
            .init(id: "budget", label: "Budget", options: ["cheap", "dear"]),
            .init(id: "brand", label: "Brand", multi: true, options: ["Samsung", "Apple"]),
        ])
        var drafts: [TalqynClarifyDraft] = []

        let sheet = TalqynClarifySheetViewController(
            theme: .default, strings: .en, clarify: clarify, draft: TalqynClarifyDraft(),
            onDraftChange: { drafts.append($0) }, onSubmit: { _ in }
        )
        show(sheet)
        let card = TalqynClarifyCardView(theme: .default, strings: .en)
        card.frame = CGRect(x: 0, y: 0, width: 358, height: 400)
        sheet.view.addSubview(card)
        card.configure(
            clarify: clarify, draft: TalqynClarifyDraft(), isInteractive: true, availableWidth: 358,
            onDraftChange: { drafts.append($0) }, onSubmit: { _ in }
        )

        for (name, container) in [("sheet", sheet.view!), ("card", card as UIView)] {
            func chips() -> [TalqynChipView] {
                find(TalqynChipView.self, in: container).filter { name == "card" || !$0.isDescendant(of: card) }
            }
            let before = chips()
            XCTAssertEqual(before.count, 4, name)
            let cheap = try XCTUnwrap(before.first { $0.accessibilityLabel == "cheap" })
            cheap.onTap?()
            if name == "card" {
                card.configure(
                    clarify: clarify, draft: try XCTUnwrap(drafts.last), isInteractive: true, availableWidth: 358,
                    onDraftChange: { drafts.append($0) }, onSubmit: { _ in }
                )
            }
            let after = chips()
            XCTAssertEqual(after.map(ObjectIdentifier.init), before.map(ObjectIdentifier.init), "\(name): the chips were replaced")
            XCTAssertTrue(cheap.isSelected, name)
            XCTAssertEqual(after.filter(\.isSelected).count, 1, name)
            XCTAssertEqual(drafts.last?.selected["budget"], ["cheap"], name)
        }
    }

    // MARK: - Comparison

    private let products = [
        1: TalqynProduct(talqynID: 1, title: "Delonghi Magnifica Start", price: 229_990),
        2: TalqynProduct(talqynID: 2, title: "Delonghi Magnifica S", price: 219_990),
    ]

    private func table(differs: Bool) -> TalqynComparisonTable {
        TalqynComparisonTable(talqynIDs: [1, 2], titles: ["A", "B"], rows: [
            .init(label: "tank", values: ["1.8 l", "1.8 l"]),
            .init(label: "display", values: ["yes", differs ? nil : "yes"]),
        ])
    }

    private func header(of screen: UIViewController, _ strings: TalqynUIStrings) throws -> (title: UILabel, differences: UIButton) {
        let title = try XCTUnwrap(find(UILabel.self, in: screen.view).first { $0.text == strings.comparisonTitle })
        let button = try XCTUnwrap(find(UIButton.self, in: screen.view).first { $0.title(for: .normal) == strings.comparisonOnlyDifferences })
        return (title, button)
    }

    /// The switch is written out whole in every language the SDK speaks: cut
    /// short, it does not say what it switches. The Kazakh one is the longest.
    func testTheDifferencesSwitchIsNeverCutShort() throws {
        for (name, strings) in [("en", TalqynUIStrings.en), ("ru", .ru), ("kk", .kk)] {
            for width in [375.0, 390.0] as [CGFloat] {
                let screen = TalqynComparisonViewController(table: table(differs: true), products: products, strings: strings) { _ in }
                show(screen, width: width)
                let (title, button) = try header(of: screen, strings)
                let label = try XCTUnwrap(button.titleLabel)
                XCTAssertFalse(button.isHidden)
                XCTAssertGreaterThanOrEqual(
                    label.bounds.width + 0.5, label.intrinsicContentSize.width, "\(name) at \(Int(width)): the switch is cut short"
                )
                XCTAssertGreaterThanOrEqual(
                    title.frame.minX, button.frame.maxX, "\(name) at \(Int(width)): the title runs into the switch"
                )
            }
        }
    }

    /// With nothing to switch, the title has the middle of the bar to itself.
    func testTheTitleIsCenteredWhenThereIsNothingToSwitch() throws {
        let screen = TalqynComparisonViewController(table: table(differs: false), products: products, strings: .kk) { _ in }
        show(screen)
        let (title, button) = try header(of: screen, .kk)
        XCTAssertTrue(button.isHidden)
        XCTAssertEqual(title.frame.midX, 195, accuracy: 1)
    }

    /// A product opened from the comparison is a click on the turn's product
    /// like any other, and is reported like one.
    func testAProductOpenedFromTheComparisonIsReportedAsAClick() async throws {
        final class Opened: TalqynConsultantDelegate {
            var products: [Int] = []
            func consultant(_ controller: TalqynConsultantViewController, openProduct product: TalqynProduct) { products.append(product.talqynID) }
            func consultant(_ controller: TalqynConsultantViewController, openSearch query: String) {}
            func consultant(_ controller: TalqynConsultantViewController, applyFilters criteria: TalqynFilterCriteria) {}
        }
        func event(_ name: String, _ data: String) -> [String] { ["event: \(name)", "data: \(data)", ""] }
        let transport = SlowStreamTransport()
        transport.responses.enqueueDeviceToken()
        transport.responses.enqueue(json: "", status: 204)
        transport.enqueueStream(lines:
            event("products", #"{"search_id":"srch-1","items":[{"talqyn_id":1,"title":"Start"},{"talqyn_id":2,"title":"S"}]}"#)
                + event("delta", #"{"text":"Compare them."}"#)
                + event("done", #"{"session_id":"sess-1"}"#))
        let conversation = TalqynConversation(talqyn: TestFixtures.client(transport: transport))
        let screen = TalqynConsultantViewController(conversation: conversation, strings: .en)
        let opened = Opened()
        screen.delegate = opened
        show(screen)

        conversation.send("which one")
        for _ in 0..<300 where conversation.isStreaming || conversation.turns.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let turn = try XCTUnwrap(conversation.turns.last?.assistant)

        let comparison = screen.makeComparison(table(differs: true), turnID: turn.id)
        comparison.onOpenProduct(try XCTUnwrap(products[2]))

        XCTAssertEqual(opened.products, [2], "the product never opened")
        for _ in 0..<100 where !transport.responses.sent.contains(where: { $0.path.hasSuffix("/events/product-click") }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let click = try XCTUnwrap(transport.responses.sent.last { $0.path.hasSuffix("/events/product-click") }, "the click was not reported")
        XCTAssertEqual(click.bodyJSON["talqyn_id"] as? Int, 2)
        XCTAssertEqual(click.bodyJSON["search_id"] as? String, "srch-1")
        XCTAssertEqual(click.bodyJSON["position"] as? Int, 1)
    }
}
#endif
