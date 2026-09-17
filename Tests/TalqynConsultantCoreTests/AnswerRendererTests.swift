import XCTest
import TalqynSDK
@testable import TalqynConsultantCore

final class AnswerRendererTests: XCTestCase {
    private let products: [Int: TalqynProduct] = [
        1: TalqynProduct(talqynID: 1, title: "Acer"),
        2: TalqynProduct(talqynID: 2, title: "Lenovo"),
    ]

    private func paragraphs(_ blocks: [TalqynAnswerBlock]) -> [[String]] {
        blocks.compactMap { block in
            if case let .paragraph(_, lines) = block { return lines.map(\.plainText) }
            return nil
        }
    }

    func testCitationCardsFollowTheSentenceThatCitesThem() {
        let blocks = TalqynAnswerRenderer.blocks(
            text: "Take [p:1]. It is quieter. Or [p:2] — pricier.",
            products: products
        )
        XCTAssertEqual(blocks.count, 4)
        guard case let .paragraph(_, first) = blocks[0], case let .products(_, cited) = blocks[1],
              case let .paragraph(_, second) = blocks[2], case let .products(_, cited2) = blocks[3]
        else { return XCTFail("expected paragraph, cards, paragraph, cards: \(blocks)") }
        XCTAssertEqual(first.map(\.plainText), ["Take Acer."])
        XCTAssertEqual(cited.map(\.talqynID), [1])
        XCTAssertEqual(second.map(\.plainText), ["It is quieter. Or Lenovo — pricier."])
        XCTAssertEqual(cited2.map(\.talqynID), [2])
    }

    func testAMarkerBecomesTheProductNameInItsOwnRun() {
        let blocks = TalqynAnswerRenderer.blocks(text: "The [p:2] has a quieter fan than the [p:1].", products: products)
        guard case let .paragraph(_, lines) = blocks.first else { return XCTFail("expected a paragraph: \(blocks)") }
        XCTAssertEqual(lines[0].runs, [
            TalqynTextRun(text: "The "),
            TalqynTextRun(text: "Lenovo", productID: 2),
            TalqynTextRun(text: " has a quieter fan than the "),
            TalqynTextRun(text: "Acer", productID: 1),
            TalqynTextRun(text: "."),
        ])
    }

    func testANameInsideBoldStaysBold() {
        let blocks = TalqynAnswerRenderer.blocks(text: "**Pick: [p:1]** — and that is that.", products: products)
        guard case let .paragraph(_, lines) = blocks.first else { return XCTFail("expected a paragraph: \(blocks)") }
        XCTAssertEqual(lines[0].runs, [
            TalqynTextRun(text: "Pick: ", isBold: true),
            TalqynTextRun(text: "Acer", isBold: true, productID: 1),
            TalqynTextRun(text: " — and that is that."),
        ])
    }

    func testANamelessProductFallsBackToItsBrand() {
        let catalog: [Int: TalqynProduct] = [
            7: TalqynProduct(talqynID: 7, title: "  ", brandName: "Asus"),
            8: TalqynProduct(talqynID: 8, title: ""),
        ]
        let blocks = TalqynAnswerRenderer.blocks(text: "Compare [p:7] and [p:8].", products: catalog)
        XCTAssertEqual(paragraphs(blocks), [["Compare Asus and."]], "no title, no brand: the marker is dropped")
        guard case let .products(_, items) = blocks.last else { return XCTFail("expected cards: \(blocks)") }
        XCTAssertEqual(items.map(\.talqynID), [7, 8], "a product with nothing to call it still gets its card")
    }

    func testAListItemIsCitedAsAWhole() {
        let blocks = TalqynAnswerRenderer.blocks(text: "1. Pick [p:1]. Fast SSD.\n2. Or [p:2].", products: products)
        guard case let .paragraph(_, lines) = blocks[0], case let .products(_, cards) = blocks[1] else {
            return XCTFail("expected a paragraph and cards: \(blocks)")
        }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].kind, .numbered("1"))
        XCTAssertEqual(lines[0].plainText, "Pick Acer. Fast SSD.", "the whole item stays together above its card")
        XCTAssertEqual(cards.map(\.talqynID), [1])
    }

    func testMarkdownLineKindsAndBoldRuns() {
        let blocks = TalqynAnswerRenderer.blocks(
            text: "# Summary\nPlain **bold** line\n- item\n* another item\n3) third",
            products: [:]
        )
        guard case let .paragraph(_, lines) = blocks.first, blocks.count == 1 else {
            return XCTFail("expected one paragraph: \(blocks)")
        }
        XCTAssertEqual(lines.map(\.kind), [.heading, .plain, .bullet, .bullet, .numbered("3")])
        XCTAssertEqual(lines[0].plainText, "Summary")
        XCTAssertEqual(lines[1].runs, [
            TalqynTextRun(text: "Plain "), TalqynTextRun(text: "bold", isBold: true), TalqynTextRun(text: " line"),
        ])
        XCTAssertEqual(lines[4].plainText, "third")
    }

    func testBlankLinesSplitParagraphsWithStableIDs() {
        let blocks = TalqynAnswerRenderer.blocks(text: "First paragraph.\n\nSecond paragraph.", products: [:])
        XCTAssertEqual(blocks.map(\.id), [0, 2])
        XCTAssertEqual(paragraphs(blocks), [["First paragraph."], ["Second paragraph."]])
    }

    /// A CRLF ends a line the way an LF does: the blank line between two
    /// paragraphs still splits them, and no line keeps a "\r" at its end.
    func testCRLFLineEndingsReadLikeLF() {
        let blocks = TalqynAnswerRenderer.blocks(text: "a\r\n\r\nb", products: [:])
        XCTAssertEqual(blocks.map(\.id), [0, 2])
        XCTAssertEqual(paragraphs(blocks), [["a"], ["b"]])

        let text = "# Summary\nTake [p:1].\n\n- quieter\n- cheaper [p:2]\n1. first"
        XCTAssertEqual(
            TalqynAnswerRenderer.blocks(text: text.replacingOccurrences(of: "\n", with: "\r\n"), products: products),
            TalqynAnswerRenderer.blocks(text: text, products: products)
        )
        XCTAssertFalse(TalqynAnswerRenderer.plainText("a\r\nb\r\n\r\n- c", products: [:]).contains("\r"))
    }

    func testUnknownMarkersAreDroppedAndRepeatedOnesNamedAgain() {
        let blocks = TalqynAnswerRenderer.blocks(text: "See [p:42] and [p:1], then again [p:1].", products: products)
        let cards = blocks.compactMap { block -> [Int]? in
            if case let .products(_, items) = block { return items.map(\.talqynID) }
            return nil
        }
        XCTAssertEqual(cards, [[1]], "an unknown product vanishes, a repeat is shown once")
        XCTAssertEqual(
            paragraphs(blocks).flatMap { $0 }.joined(separator: "|"),
            "See and Acer, then again Acer.",
            "the unknown marker leaves no trace, the repeat is named without a second card"
        )
    }

    func testAMarkerStillBeingTypedIsHidden() {
        for partial in ["Take [", "Take [p", "Take [p:", "Take [p:12"] {
            let blocks = TalqynAnswerRenderer.blocks(text: partial, products: products)
            XCTAssertEqual(paragraphs(blocks), [["Take"]], partial)
        }
    }

    func testStrippedRemovesMarkers() {
        XCTAssertEqual(TalqynAnswerRenderer.stripped("Take [p:1] or [p:2]. More [p:"), "Take or. More")
    }

    func testPlainTextNamesProductsAndWritesListsOut() {
        let text = "# Summary\nTake [p:1].\n\n- quieter\n- cheaper [p:2]\n1. first\n2) second"
        XCTAssertEqual(
            TalqynAnswerRenderer.plainText(text, products: products),
            "Summary\nTake Acer.\n\n• quieter\n• cheaper Lenovo\n\n1. first\n2. second",
            "a blank line stands where the cited cards were"
        )
        XCTAssertEqual(TalqynAnswerRenderer.plainText("", products: products), "")
    }

    func testEmptyTextRendersNothing() {
        XCTAssertTrue(TalqynAnswerRenderer.blocks(text: "", products: products).isEmpty)
        XCTAssertTrue(TalqynAnswerRenderer.blocks(text: "\n\n  \n", products: products).isEmpty)
    }
}

final class UIStringsTests: XCTestCase {
    func testRussianProductsCountPicksThePluralForm() {
        let ru = TalqynUIStrings.ru
        XCTAssertEqual([1, 2, 4, 5, 11, 14, 21, 22, 25, 111].map(ru.productsCount), [
            "1 товар", "2 товара", "4 товара", "5 товаров", "11 товаров", "14 товаров",
            "21 товар", "22 товара", "25 товаров", "111 товаров",
        ])
    }

    func testEnglishProductsCountPicksTheTwoForms() {
        let en = TalqynUIStrings.en
        XCTAssertEqual([1, 2, 5, 11, 21, 111].map(en.productsCount), [
            "1 product", "2 products", "5 products", "11 products", "21 products", "111 products",
        ])
    }

    func testKazakhProductsCountHasOneForm() {
        let kk = TalqynUIStrings.kk
        XCTAssertEqual([1, 2, 5].map(kk.productsCount), ["1 тауар", "2 тауар", "5 тауар"])
    }

    /// Every copy set labels every reason the API accepts: a reason with no
    /// label is silently not offered.
    func testEveryFeedbackReasonHasALabel() {
        let reasons: [TalqynFeedbackReason] = [.notRelevant, .wrongInfo, .tooManyQuestions, .noAnswer, .priceStock, .other]
        for strings in [TalqynUIStrings.en, .ru, .kk] {
            for reason in reasons {
                XCTAssertNotNil(strings.feedbackReasonText(for: reason), "\(reason.rawValue) has no label")
            }
        }
    }

    /// The shopper's own limit clears in hours, the account's does not: the
    /// two must not read the same, and neither promises "today".
    func testBudgetFallbacksSayDifferentThings() {
        for strings in [TalqynUIStrings.en, .ru, .kk] {
            let own = strings.fallbackText(for: .userBudgetExceeded)
            let account = strings.fallbackText(for: .budgetExceeded)
            XCTAssertNotEqual(own, account)
            let lowered = own.lowercased()
            XCTAssertFalse(lowered.contains("today") || lowered.contains("сегодня") || lowered.contains("бүгін"))
        }
        XCTAssertEqual(TalqynUIStrings.ru.fallbackText(for: TalqynFallbackReason(rawValue: "timeout:llm")),
                       TalqynUIStrings.ru.fallbackText(for: .timeout), "a suffix after the colon is detail")
    }

    /// A repeat would meet the same wall after a spent budget, a turn that ran
    /// out, or a refusal — and may well work after a timeout.
    func testWhichFallbacksInviteARetry() {
        XCTAssertFalse(TalqynFallbackReason.userBudgetExceeded.invitesRetry)
        XCTAssertFalse(TalqynFallbackReason.budgetExceeded.invitesRetry)
        XCTAssertFalse(TalqynFallbackReason.turnBudget.invitesRetry)
        XCTAssertFalse(TalqynFallbackReason(rawValue: "refusal:policy").invitesRetry)
        XCTAssertTrue(TalqynFallbackReason.timeout.invitesRetry)
        XCTAssertTrue(TalqynFallbackReason(rawValue: "something_new").invitesRetry)
    }

    /// A price is written on every card of every re-render; the shared
    /// formatter must write the same thing from any thread.
    func testTengeFormatsWholeAndFractionalPrices() async {
        let tenge = TalqynPriceFormatter.tenge
        XCTAssertEqual(tenge.format(449_990), "449\u{00A0}990\u{00A0}₸")
        let results = await withTaskGroup(of: String.self) { group in
            for _ in 0..<50 { group.addTask { tenge.format(1_000) } }
            return await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        XCTAssertEqual(results, ["1\u{00A0}000\u{00A0}₸"])
    }
}

final class ClarifyDraftTests: XCTestCase {
    private let budget = TalqynClarify.Question(id: "budget", label: "What is the budget?", multi: false, options: ["under 150k", "under 300k"])
    private let use = TalqynClarify.Question(id: "use", label: "What for? ", multi: true, options: ["school", "games"])

    func testSingleChoiceReplacesAndMultiChoiceAccumulates() {
        var draft = TalqynClarifyDraft()
        draft.toggle("under 150k", in: budget)
        draft.toggle("under 300k", in: budget)
        XCTAssertEqual(draft.selected["budget"], ["under 300k"])
        draft.toggle("under 300k", in: budget)
        XCTAssertNil(draft.selected["budget"], "toggling the selection off clears it")

        draft.toggle("school", in: use)
        draft.toggle("games", in: use)
        XCTAssertEqual(draft.selected["use"], ["school", "games"])
        draft.toggle("school", in: use)
        XCTAssertEqual(draft.selected["use"], ["games"])
        XCTAssertTrue(draft.isSelected("games", in: use))
    }

    func testAnswerRestatesLabelsWithoutQuestionMarks() {
        var draft = TalqynClarifyDraft()
        XCTAssertTrue(draft.isEmpty)
        XCTAssertEqual(draft.answer(for: [budget, use]), "")

        draft.toggle("under 300k", in: budget)
        draft.toggle("school", in: use)
        draft.toggle("games", in: use)
        XCTAssertEqual(draft.answer(for: [budget, use]), "What is the budget: under 300k. What for: school, games.")

        draft.custom = "  and it should be quiet  "
        XCTAssertEqual(draft.answer(for: [budget, use]), "What is the budget: under 300k. What for: school, games. and it should be quiet")

        let onlyText = TalqynClarifyDraft(custom: "any")
        XCTAssertEqual(onlyText.answer(for: [budget]), "any")
        XCTAssertFalse(onlyText.isEmpty)
    }
}
