#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import TalqynTestSupport
import XCTest
@testable import TalqynUI

/// What a turn's row shows, and when.
@MainActor
final class TranscriptRowsTests: XCTestCase {
    private func event(_ name: String, _ data: String) -> [String] { ["event: \(name)", "data: \(data)", ""] }

    /// A turn that asks instead of answering, up to its `done`.
    private var asking: [String] {
        event("status", #"{"stage":"thinking"}"#)
            + event("clarify", #"{"message":"clarify","questions":[{"id":"budget","label":"Budget?","multi":false,"options":["under 300k"]}]}"#)
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(message)
    }

    private func settle(_ conversation: TalqynConversation) async {
        await waitUntil("the turn never settled") { !conversation.isStreaming }
    }

    private func row(
        _ turn: TalqynAssistantTurn, in conversation: TalqynConversation, dismissed: Set<UUID> = []
    ) -> TalqynTurnRow {
        TalqynTranscriptRowBuilder(theme: .default, strings: .en, price: .tenge)
            .turnRow(turn, conversation: conversation, dismissedClarifyTurns: dismissed)
    }

    // MARK: - Clarify

    /// While the turn that asks is still streaming there is nothing to answer
    /// yet: no greyed-out card stands in the transcript first. The question
    /// comes up — as a sheet or as a card — once the turn is done.
    func testNoClarifyCardWhileTheTurnThatAsksStreams() async throws {
        let transport = SlowStreamTransport()
        transport.responses.enqueueDeviceToken()
        transport.enqueueStream(lines: asking, keepsOpen: true)
        let conversation = TalqynConversation(talqyn: TestFixtures.client(transport: transport))

        conversation.send("recommend something")
        await waitUntil("the question never arrived") { conversation.turns.last?.assistant?.clarify != nil }
        let turn = try XCTUnwrap(conversation.turns.last?.assistant)
        XCTAssertTrue(conversation.isStreaming)
        XCTAssertNil(row(turn, in: conversation).clarify)

        conversation.stop()
        await settle(conversation)
    }

    /// Once the turn is done the sheet asks first; dismissed, it leaves the
    /// question in the transcript as a card that takes an answer.
    func testASettledQuestionIsTheSheetsUntilItIsDismissed() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: asking + event("done", #"{"session_id":"sess-1"}"#))
        let conversation = TalqynConversation(talqyn: try await TestFixtures.preparedClient(transport: transport))

        conversation.send("recommend something")
        await settle(conversation)

        let turn = try XCTUnwrap(conversation.turns.last?.assistant)
        XCTAssertNil(row(turn, in: conversation).clarify, "the sheet asks first")
        guard case let .pending(_, _, isInteractive)? = row(turn, in: conversation, dismissed: [turn.id]).clarify else {
            return XCTFail("a dismissed sheet must leave its question in the transcript")
        }
        XCTAssertTrue(isInteractive)
    }

    /// An earlier question nobody answered stays in the transcript while a
    /// newer turn streams — greyed out, since only the latest turn takes an
    /// answer.
    func testAnEarlierQuestionStaysGreyedWhileANewerTurnStreams() async throws {
        let transport = SlowStreamTransport()
        transport.responses.enqueueDeviceToken()
        transport.enqueueStream(lines: asking + event("done", #"{"session_id":"sess-1"}"#))
        let conversation = TalqynConversation(talqyn: TestFixtures.client(transport: transport))
        conversation.send("recommend something")
        await settle(conversation)
        let earlier = try XCTUnwrap(conversation.turns.last?.assistant)

        transport.enqueueStream(lines: event("status", #"{"stage":"thinking"}"#), keepsOpen: true)
        conversation.send("actually — a laptop")
        XCTAssertTrue(conversation.isStreaming)
        guard case let .pending(_, _, isInteractive)? = row(earlier, in: conversation).clarify else {
            return XCTFail("the earlier question left the transcript")
        }
        XCTAssertFalse(isInteractive)

        conversation.stop()
        await settle(conversation)
    }

    // MARK: - Products

    /// A group that lists a product twice shows it once: one card per product
    /// in a section, and the count in its title says so.
    func testAGroupShowsEachProductOnce() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: event("products", #"{"items":[{"talqyn_id":1,"title":"Sofa"},{"talqyn_id":2,"title":"Table"}],"groups":[{"role":"sofa","items":[{"talqyn_id":1,"title":"Sofa"},{"talqyn_id":1,"title":"Sofa"}]},{"role":"table","items":[{"talqyn_id":2,"title":"Table"},{"talqyn_id":1,"title":"Sofa"},{"talqyn_id":2,"title":"Table"}]}]}"#)
            + event("done", #"{"session_id":"sess-1"}"#))
        let conversation = TalqynConversation(talqyn: try await TestFixtures.preparedClient(transport: transport))

        conversation.send("a sofa and a table to match")
        await settle(conversation)

        let sections = row(try XCTUnwrap(conversation.turns.last?.assistant), in: conversation).productSections
        XCTAssertEqual(sections.map { $0.products.map(\.talqynID) }, [[1], [2, 1]])
        XCTAssertEqual(sections.map(\.title), ["Sofa · 1", "Table · 2"])
    }
}
#endif
