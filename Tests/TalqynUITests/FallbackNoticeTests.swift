#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import TalqynTestSupport
import XCTest
@testable import TalqynUI

@MainActor
final class FallbackNoticeTests: XCTestCase {
    private func event(_ name: String, _ data: String) -> [String] { ["event: \(name)", "data: \(data)", ""] }

    /// A turn the consultant gave up on, with or without the products it
    /// found before giving up.
    private func fallbackTurn(withProducts: Bool, reason: String) -> [String] {
        var lines = event("status", #"{"stage":"thinking"}"#)
        if withProducts {
            lines += event("products", #"{"items":[{"talqyn_id":1,"title":"Acer"}],"search_id":"srch-1"}"#)
        }
        return lines
            + event("fallback", #"{"reason":"\#(reason)"}"#)
            + event("follow_ups", #"{"items":["anything cheaper?","compare them"]}"#)
            + event("done", #"{"session_id":"sess-1"}"#)
    }

    private func settle(_ conversation: TalqynConversation) async {
        for _ in 0..<200 {
            if !conversation.isStreaming { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the turn never settled")
    }

    private func fallbackRow(
        withProducts: Bool, reason: String = "budget_exceeded"
    ) async throws -> (TalqynTurnRow, TalqynConversation) {
        let transport = StubTransport()
        transport.enqueueStream(lines: fallbackTurn(withProducts: withProducts, reason: reason))
        let conversation = TalqynConversation(talqyn: try await TestFixtures.preparedClient(transport: transport))
        conversation.send("what to give as a housewarming gift?")
        await settle(conversation)

        let turn = try XCTUnwrap(conversation.turns.last?.assistant)
        XCTAssertEqual(turn.fallbackReason?.rawValue, reason)
        let builder = TalqynTranscriptRowBuilder(theme: .default, strings: .en, price: .tenge)
        return (builder.turnRow(turn, conversation: conversation, dismissedClarifyTurns: []), conversation)
    }

    /// The reason alone: there is no carousel under it to point at.
    func testAFallbackWithNoProductsDoesNotPromiseThem() async throws {
        let text = try await fallbackRow(withProducts: false).0.notice?.text
        XCTAssertEqual(text, "The consultant is unavailable right now")
    }

    /// The products the turn did find are worth pointing at.
    func testAFallbackWithProductsPointsAtThem() async throws {
        let text = try await fallbackRow(withProducts: true).0.notice?.text
        XCTAssertEqual(text, "The consultant is unavailable right now, but here is what matches")
    }

    /// The carousel is all the turn has, so it is not headed as an extra.
    func testFallbackProductsGetTheirOwnHeader() async throws {
        let (row, _) = try await fallbackRow(withProducts: true)
        XCTAssertEqual(row.productSections.map(\.title), ["What turned up for your request"])
    }

    /// Whatever stopped the turn would stop the next question too.
    func testAFallbackTurnOffersNoFollowUps() async throws {
        let (_, conversation) = try await fallbackRow(withProducts: true)
        XCTAssertEqual(conversation.turns.last?.assistant?.followUps, ["anything cheaper?", "compare them"])
        XCTAssertEqual(conversation.suggestedQuestions(examples: ["Example"]), [])
    }

    /// The shopper's own limit is spent for hours: a retry button would only
    /// walk them into it again. A timeout may clear, and gets one.
    func testRetryIsOfferedOnlyWhereItCouldWork() async throws {
        let spent = try await fallbackRow(withProducts: true, reason: "user_budget_exceeded").0.notice
        XCTAssertEqual(spent?.showsRetry, false)
        XCTAssertEqual(spent?.text, "You have used up your questions for the next few hours, but here is what matches")
        let timedOut = try await fallbackRow(withProducts: true, reason: "timeout").0.notice
        XCTAssertEqual(timedOut?.showsRetry, true)
    }

    /// "No answer" is exactly what a shopper may want to say about a turn
    /// that gave up: it is rated, with its own reasons, and has no text to
    /// copy.
    func testAFallbackTurnCanBeRatedButNotCopied() async throws {
        let (row, _) = try await fallbackRow(withProducts: true)
        let toolbar = try XCTUnwrap(row.toolbar)
        XCTAssertNil(toolbar.copyText)
        XCTAssertEqual(toolbar.offeredReasons.first, .noAnswer)
    }

    /// How many prompts to put in front of the shopper is the storefront's
    /// call: the server may send more than are worth showing.
    func testFollowUpCountFollowsTheConversation() {
        let sent = ["first", "second", "third", "fourth"]
        XCTAssertEqual(TalqynConversation.sanitizedFollowUps(sent).count, 3, "three by default")
        XCTAssertEqual(TalqynConversation.sanitizedFollowUps(sent, limit: 1), ["first"])
        XCTAssertEqual(TalqynConversation.sanitizedFollowUps(sent, limit: 0), [])
        XCTAssertEqual(TalqynConversation.sanitizedFollowUps(sent, limit: 10).count, 4, "no padding past what came")
    }
}

/// When a clarification comes up as a sheet and when it stays in the
/// transcript.
@MainActor
final class ClarifyPresentationTests: XCTestCase {
    private func asking(_ id: UUID = UUID()) -> TalqynAssistantTurn {
        var turn = TalqynAssistantTurn(id: id, question: "recommend something")
        turn.clarify = TalqynClarify(message: "clarify", questions: [
            .init(id: "budget", label: "Budget?", options: ["under 300k"]),
        ])
        return turn
    }

    func testOneSheetPerQuestionTheShopperTyped() {
        let policy = TalqynClarifyPresentation()
        policy.beginRequest()
        let first = asking()
        XCTAssertEqual(policy.decide(for: first, canPresent: true), .sheet)
        XCTAssertEqual(policy.decide(for: first, canPresent: true), .none, "a turn is decided once")

        let followUp = asking()
        XCTAssertEqual(policy.decide(for: followUp, canPresent: true), .inline, "a second sheet in a row is an interrogation")
        XCTAssertTrue(policy.inlineTurns.contains(followUp.id))

        policy.beginRequest()
        XCTAssertEqual(policy.decide(for: asking(), canPresent: true), .sheet, "a new question gets its own")
    }

    func testASheetThatCannotComeUpStaysInline() {
        let policy = TalqynClarifyPresentation()
        policy.beginRequest()
        let turn = asking()
        XCTAssertEqual(policy.decide(for: turn, canPresent: false), .inline)
    }

    func testADismissedSheetMovesIntoTheTranscriptAndIsForgottenWithItsTurn() {
        let policy = TalqynClarifyPresentation()
        policy.beginRequest()
        let turn = asking()
        _ = policy.decide(for: turn, canPresent: true)
        policy.sheetDismissed(turnID: turn.id)
        XCTAssertTrue(policy.inlineTurns.contains(turn.id))
        policy.forget(turnIDs: [turn.id])
        XCTAssertFalse(policy.inlineTurns.contains(turn.id))
    }

    func testAnAnsweredOrPlainTurnHasNothingToShow() {
        let policy = TalqynClarifyPresentation()
        var answered = asking()
        answered.clarifyAnswer = "Budget: under 300k."
        XCTAssertEqual(policy.decide(for: answered, canPresent: true), .none)
        XCTAssertEqual(policy.decide(for: TalqynAssistantTurn(question: "q"), canPresent: true), .none)
    }
}
#endif
