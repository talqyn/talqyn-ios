#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import TalqynTestSupport
import UIKit
import XCTest
@testable import TalqynUI

/// The height of a turn's cell is the height of what the turn shows — no
/// matter where on the screen the turn happens to sit.
@MainActor
final class TranscriptSizingTests: XCTestCase {
    nonisolated(unsafe) private var window: UIWindow?

    override func tearDown() async throws {
        await MainActor.run {
            window?.isHidden = true
            window = nil
        }
        try await super.tearDown()
    }

    private func event(_ name: String, _ data: String) -> [String] { ["event: \(name)", "data: \(data)", ""] }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + find(type, in: $0) }
    }

    /// An answer long enough to run off the bottom of the screen: text, two
    /// cited products, and more products for the carousel under it.
    private func longTurn() -> [String] {
        let products = ([1, 2] + Array(10..<16)).map {
            #"{"talqyn_id":\#($0),"title":"Coffee machine Delonghi Magnifica S ECAM-21.117.SB number \#($0)","price":219990,"price_before":259990}"#
        }.joined(separator: ",")
        let sentence = "A basic model with a manual frother that keeps the same tank and pressure. "
        var lines = event("status", #"{"stage":"thinking"}"#) + event("products", #"{"items":[\#(products)]}"#)
        for part in 0..<3 {
            for _ in 0..<8 { lines += event("delta", #"{"text":"\#(sentence)"}"#) }
            if part < 2 { lines += event("delta", #"{"text":"**Machine** [p:\#(part + 1)].\n\n"}"#) }
        }
        return lines
            + event("follow_ups", #"{"items":["And cheaper?","With a display?"]}"#)
            + event("done", #"{"session_id":"sess-1"}"#)
    }

    /// The screen in a tab of its own, the way an app with a tab bar hosts it.
    private func showScreen(_ transport: TalqynHTTPTransport) -> (TalqynConsultantViewController, UITabBarController) {
        let conversation = TalqynConversation(talqyn: TestFixtures.client(transport: transport))
        let screen = TalqynConsultantViewController(conversation: conversation, strings: .en)
        let tabs = UITabBarController()
        tabs.viewControllers = [screen, UIViewController()]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        self.window = window
        tabs.view.layoutIfNeeded()
        return (screen, tabs)
    }

    private func streamedScreen() async -> (TalqynConsultantViewController, UITabBarController) {
        let transport = SlowStreamTransport()
        transport.responses.enqueueDeviceToken()
        transport.enqueueStream(lines: longTurn())
        let shown = showScreen(transport)
        shown.0.conversation.send("coffee")
        await settle(shown.0)
        return shown
    }

    private func settle(_ screen: TalqynConsultantViewController) async {
        let conversation = screen.conversation
        for _ in 0..<600 where conversation.isStreaming || conversation.isRestoring || conversation.turns.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(conversation.isStreaming || conversation.isRestoring, "the transcript never settled")
        try? await Task.sleep(nanoseconds: 400_000_000)
        window?.layoutIfNeeded()
    }

    /// Every cell on screen is as tall as what it holds, no paragraph is cut
    /// short, and nothing a turn shows is squeezed out or left transparent.
    private func assertEveryCellFits(
        _ screen: TalqynConsultantViewController, _ situation: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let collection = try XCTUnwrap(find(UICollectionView.self, in: screen.view).first, file: file, line: line)
        XCTAssertFalse(collection.visibleCells.isEmpty, "\(situation): nothing on screen", file: file, line: line)
        for cell in collection.visibleCells {
            let content = cell.contentView.systemLayoutSizeFitting(
                CGSize(width: cell.bounds.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height
            XCTAssertEqual(
                cell.bounds.height, content, accuracy: 0.5,
                "\(situation): a \(type(of: cell)) is not as tall as its content", file: file, line: line
            )
            for text in find(UITextView.self, in: cell) {
                let needed = text.sizeThatFits(CGSize(width: text.bounds.width, height: .greatestFiniteMagnitude)).height
                XCTAssertEqual(
                    text.bounds.height, needed, accuracy: 0.5, "\(situation): a paragraph is cut short", file: file, line: line
                )
            }
        }
    }

    /// The transcript runs under the composer, the home indicator, and the
    /// app's tab bar, so the end of a long answer lies outside the safe area
    /// until it is scrolled to. A view's safe-area insets follow its place on
    /// the screen; were any of them to reach the turn's layout, the turn would
    /// be measured for one place and drawn in another — its last paragraph
    /// cut short, the carousel's header squeezed out, until the next scroll.
    func testATurnThatReachesUnderTheTabBarIsAsTallAsItsContent() async throws {
        let (screen, _) = await streamedScreen()

        let cell = try XCTUnwrap(find(TalqynAssistantTurnCell.self, in: screen.view).first)
        XCTAssertGreaterThan(
            cell.frame.maxY, try XCTUnwrap(window).bounds.height, "the turn has to run off the screen for this test"
        )
        try assertEveryCellFits(screen, "under the tab bar")

        let header = find(UILabel.self, in: cell).first { $0.text == TalqynUIStrings.en.productsHeader }
        XCTAssertGreaterThan(try XCTUnwrap(header).bounds.height, 1, "the carousel's header is squeezed out")
    }

    /// The same turn at every place it can sit on the screen: the end of it
    /// is where the composer and the tab bar cover the transcript.
    func testATurnKeepsItsHeightAsItIsScrolled() async throws {
        let (screen, _) = await streamedScreen()
        let collection = try XCTUnwrap(find(UICollectionView.self, in: screen.view).first)

        let end = collection.contentSize.height - collection.bounds.height + collection.contentInset.bottom
        for offset in stride(from: CGFloat(0), through: max(0, end), by: 150) {
            collection.delegate?.scrollViewWillBeginDragging?(collection)
            collection.contentOffset.y = offset
            collection.delegate?.scrollViewDidScroll?(collection)
            window?.layoutIfNeeded()
            try assertEveryCellFits(screen, "scrolled to \(Int(offset))")
        }
    }

    /// What a turn adds as it settles comes in softly, and ends up fully
    /// there: a fade that never finished would leave the carousel or the
    /// rating buttons half-visible.
    func testWhatASettledTurnAddsIsFullyShown() async throws {
        let (screen, _) = await streamedScreen()
        try await Task.sleep(nanoseconds: 400_000_000)

        let cell = try XCTUnwrap(find(TalqynAssistantTurnCell.self, in: screen.view).first)
        let carousel = try XCTUnwrap(find(TalqynProductListView.self, in: cell).first)
        let toolbar = try XCTUnwrap(find(TalqynAnswerToolbarView.self, in: cell).first)
        for view in [carousel, toolbar] as [UIView] {
            var current: UIView? = view
            while let ancestor = current, ancestor !== cell {
                XCTAssertFalse(ancestor.isHidden, "\(type(of: view)) is hidden by \(type(of: ancestor))")
                XCTAssertEqual(ancestor.alpha, 1, "\(type(of: view)) is dimmed by \(type(of: ancestor))")
                current = ancestor.superview
            }
        }
    }

    /// A larger text size is a new layout for every paragraph and card: the
    /// cells have to be measured again, not kept at the size they had.
    func testALargerTextSizeResizesTheTurn() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("trait overrides need iOS 17") }
        let (screen, _) = await streamedScreen()
        let before = try XCTUnwrap(find(TalqynAssistantTurnCell.self, in: screen.view).first).bounds.height

        window?.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        window?.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        window?.layoutIfNeeded()

        try assertEveryCellFits(screen, "at a larger text size")
        let after = try XCTUnwrap(find(TalqynAssistantTurnCell.self, in: screen.view).first).bounds.height
        XCTAssertGreaterThan(after, before, "larger type did not make the turn taller")
    }

    /// A rotation, or an iPad window resized, hands every row a new width.
    func testANewWidthResizesTheTurn() async throws {
        let (screen, _) = await streamedScreen()

        window?.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        window?.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        window?.layoutIfNeeded()

        try assertEveryCellFits(screen, "at a narrower width")
    }

    /// A chat opened from history is drawn whole, scrolled to its end — where
    /// its last turn lies under the composer and the tab bar from the start.
    func testAChatRestoredFromHistoryIsLaidOut() async throws {
        let paragraph = Array(repeating: "A basic model with a manual frother that keeps the same tank.", count: 6)
            .joined(separator: " ")
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        transport.enqueue(json: """
        {"session_id":"s1","messages":[
          {"role":"user","text":"coffee","talqyn_ids":[]},
          {"role":"assistant","text":"\(paragraph)\\n\\nTake **this one** [p:1]. \(paragraph)","talqyn_ids":[1,2,3,4]},
          {"role":"user","text":"and cheaper?","talqyn_ids":[]},
          {"role":"assistant","text":"\(paragraph)\\n\\nOr [p:2]. \(paragraph)","talqyn_ids":[2,3,4]}],
         "products":[{"talqyn_id":1,"title":"Delonghi Magnifica S","price":219990},
                     {"talqyn_id":2,"title":"Delonghi Magnifica Start","price":229990},
                     {"talqyn_id":3,"title":"Delonghi Magnifica Evo","price":269990},
                     {"talqyn_id":4,"title":"Delonghi PrimaDonna","price":719990}]}
        """)
        let (screen, _) = showScreen(transport)

        screen.conversation.restore(sessionID: "s1")
        await settle(screen)
        XCTAssertEqual(screen.conversation.turns.count, 4)

        try assertEveryCellFits(screen, "restored from history")
        let collection = try XCTUnwrap(find(UICollectionView.self, in: screen.view).first)
        let last = try XCTUnwrap(find(TalqynAssistantTurnCell.self, in: collection).max { $0.frame.maxY < $1.frame.maxY })
        let visibleBottom = collection.contentOffset.y + collection.bounds.height - collection.contentInset.bottom
        XCTAssertLessThanOrEqual(last.frame.maxY, visibleBottom + 0.5, "the end of the chat is under the composer")
    }

    /// A screen put up over a conversation that is already long — the tab
    /// opened again, the app back from a product page — shows its last
    /// question at the top of the screen with the answer under it, the way
    /// the shopper left it, and not the first words of the first turn.
    func testAScreenOverALongConversationOpensAtItsLastQuestion() async throws {
        let paragraph = Array(repeating: "A basic model with a manual frother that keeps the same tank.", count: 6)
            .joined(separator: " ")
        let messages = (0..<12).flatMap { index in [
            #"{"role":"user","text":"question \#(index)","talqyn_ids":[]}"#,
            #"{"role":"assistant","text":"\#(paragraph)\n\nTake [p:1]. \#(paragraph)","talqyn_ids":[1,2]}"#,
        ] }
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        transport.enqueue(json: """
        {"session_id":"s1","messages":[\(messages.joined(separator: ","))],
         "products":[{"talqyn_id":1,"title":"Delonghi Magnifica S","price":219990},
                     {"talqyn_id":2,"title":"Delonghi Magnifica Start","price":229990}]}
        """)
        let conversation = TalqynConversation(talqyn: TestFixtures.client(transport: transport))
        conversation.restore(sessionID: "s1")
        for _ in 0..<300 where conversation.isRestoring || conversation.turns.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(conversation.turns.count, 24)

        let screen = TalqynConsultantViewController(conversation: conversation, strings: .en)
        let tabs = UITabBarController()
        tabs.viewControllers = [screen, UIViewController()]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        self.window = window
        tabs.view.layoutIfNeeded()
        await settle(screen)

        let collection = try XCTUnwrap(find(UICollectionView.self, in: screen.view).first)
        let questions = find(TalqynUserBubbleCell.self, in: collection)
        let last = try XCTUnwrap(questions.max { $0.frame.minY < $1.frame.minY })
        XCTAssertEqual(find(UILabel.self, in: last).first?.text, "question 11")
        XCTAssertEqual(last.frame.minY - collection.contentOffset.y, 8, accuracy: 1, "the last question is not at the top of the screen")
        try assertEveryCellFits(screen, "opened over a long conversation")
    }
}
#endif
