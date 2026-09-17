#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import TalqynTestSupport
import UIKit
import XCTest
@testable import TalqynUI

/// A navigation controller that counts the pops it is asked for.
private final class PopRecordingNavigationController: UINavigationController {
    private(set) var popRequests = 0

    override func popViewController(animated: Bool) -> UIViewController? {
        popRequests += 1
        return super.popViewController(animated: animated)
    }
}

/// Who owns a turn's lifetime. Every turn is an LLM call, so a screen that goes
/// away for good has to stop paying for an answer nobody will read — while a
/// screen that is merely covered by a product card must not lose the answer the
/// shopper is coming back to.
@MainActor
final class ConsultantScreenLifecycleTests: XCTestCase {
    private func turnLines() -> [String] {
        ["event: status", #"data: {"stage":"thinking"}"#, "",
         "event: delta", #"data: {"text":"Taking"}"#, "",
         "event: delta", #"data: {"text":" a laptop"}"#, "",
         "event: done", #"data: {"session_id":"sess-1"}"#, ""]
    }

    private func makeScreen() -> (TalqynConsultantViewController, SlowStreamTransport) {
        let transport = SlowStreamTransport()
        transport.responses.enqueueDeviceToken()
        transport.enqueueStream(lines: turnLines())
        let conversation = TalqynConversation(talqyn: TestFixtures.client(transport: transport))
        return (TalqynConsultantViewController(conversation: conversation), transport)
    }

    /// Puts the screen on a real window: appearance callbacks are what is under
    /// test, and they do not fire off-screen.
    private func present(_ screen: UIViewController) -> (UIWindow, UINavigationController) {
        let navigation = UINavigationController(rootViewController: UIViewController())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        navigation.pushViewController(screen, animated: false)
        screen.view.layoutIfNeeded()
        return (window, navigation)
    }

    private func wait(_ condition: @MainActor () -> Bool, _ message: String) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(message)
    }

    func testLeavingTheScreenStopsTheTurn() async throws {
        let (screen, transport) = makeScreen()
        let (window, navigation) = present(screen)
        defer { window.isHidden = true }

        screen.conversation.send("need a laptop for school")
        await wait({ screen.conversation.turns.last?.assistant?.text.isEmpty == false },
                   "the answer never started")

        navigation.popViewController(animated: false)
        await wait({ !screen.conversation.isStreaming }, "the turn never settled")

        XCTAssertEqual(screen.conversation.turns.last?.assistant?.wasStopped, true)
        XCTAssertTrue(transport.wasTerminated, "the request behind the stream is still open")
    }

    private func visibleButton(labeled label: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityLabel == label, !button.isHidden { return button }
        for subview in view.subviews {
            if let found = visibleButton(labeled: label, in: subview) { return found }
        }
        return nil
    }

    /// The screen hides the navigation bar, so it has to offer the way back
    /// itself — and the edge swipe must keep working without the bar.
    func testAPushedScreenOffersTheWayBackAndKeepsTheSwipe() async throws {
        let (screen, _) = makeScreen()
        // A scene-less test window never finishes an animated transition, so
        // what is checked is that the stack is asked to pop, not the stack.
        let navigation = PopRecordingNavigationController(rootViewController: UIViewController())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        navigation.pushViewController(screen, animated: false)
        screen.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(navigation.isNavigationBarHidden)
        let back = try XCTUnwrap(visibleButton(labeled: TalqynUIStrings.en.back, in: screen.view), "no way back on a pushed screen")
        let gesture = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        XCTAssertEqual(gesture.delegate?.gestureRecognizerShouldBegin?(gesture), true, "the swipe back must begin")

        // `sendActions(for:)` goes through the application, which delivers
        // nothing to a scene-less window: the wired action is invoked as the
        // tap would invoke it.
        for target in back.allTargets {
            for action in back.actions(forTarget: target, forControlEvent: .touchUpInside) ?? [] {
                _ = (target as NSObject).perform(Selector(action), with: back)
            }
        }
        XCTAssertEqual(navigation.popRequests, 1, "back asks the stack to pop the screen")
    }

    /// A tab of its own has nowhere to go back to: no arrow, no cross.
    func testARootScreenHasNoWayOut() async throws {
        let (screen, _) = makeScreen()
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        screen.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(visibleButton(labeled: TalqynUIStrings.en.back, in: screen.view))
        XCTAssertNil(visibleButton(labeled: TalqynUIStrings.en.close, in: screen.view))
        XCTAssertNotNil(visibleButton(labeled: TalqynUIStrings.en.historyTitle, in: screen.view), "history takes the leading slot")
    }

    /// A product card opens over the transcript mid-answer: the turn continues,
    /// and the shopper comes back to a finished answer.
    func testOpeningAProductOverTheScreenKeepsTheTurn() async throws {
        let (screen, _) = makeScreen()
        let (window, navigation) = present(screen)
        defer { window.isHidden = true }

        screen.conversation.send("need a laptop for school")
        await wait({ screen.conversation.turns.last?.assistant?.text.isEmpty == false },
                   "the answer never started")

        navigation.pushViewController(UIViewController(), animated: false)
        await wait({ !screen.conversation.isStreaming }, "the turn never settled")

        let turn = try XCTUnwrap(screen.conversation.turns.last?.assistant)
        XCTAssertNotEqual(turn.wasStopped, true)
        XCTAssertEqual(turn.text, "Taking a laptop")
        XCTAssertEqual(screen.conversation.sessionID, "sess-1")
    }

    // MARK: - A question asked out of sight

    private func makeAskingScreen() -> TalqynConsultantViewController {
        let transport = SlowStreamTransport()
        transport.responses.enqueueDeviceToken()
        transport.enqueueStream(lines: [
            "event: status", #"data: {"stage":"thinking"}"#, "",
            "event: clarify",
            #"data: {"message":"clarify","questions":[{"id":"budget","label":"Budget?","multi":false,"options":["under 300k"]}]}"#, "",
            "event: done", #"data: {"session_id":"sess-1"}"#, "",
        ])
        return TalqynConsultantViewController(conversation: TalqynConversation(talqyn: TestFixtures.client(transport: transport)))
    }

    /// A clarifying question that settles under a product page waits for the
    /// shopper to come back. Asked from the covered screen, the sheet would
    /// come up over the product page, from a controller UIKit calls detached.
    ///
    /// Another tab takes the same path — the screen leaves the window either
    /// way, and there UIKit refuses the sheet outright — but it has no test of
    /// its own: a scene-less test window never finishes a tab switch, and the
    /// screen is told it will appear, never that it did.
    func testAQuestionThatSettlesUnderAProductPageIsAskedOnReturn() async throws {
        let screen = makeAskingScreen()
        let (window, navigation) = present(screen)
        defer { window.isHidden = true }

        screen.conversation.send("recommend something")
        navigation.pushViewController(UIViewController(), animated: false)
        await wait({ !screen.conversation.isStreaming }, "the turn never settled")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(navigation.presentedViewController, "the question came up over the product page")

        navigation.popViewController(animated: false)
        await wait({ screen.presentedViewController is TalqynClarifySheetViewController }, "the question was lost")
    }
}
#endif
