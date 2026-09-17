import XCTest
import TalqynTestSupport
@testable import TalqynSDK

final class ConsultantEventTests: XCTestCase {
    private func event(_ name: String, _ json: String) -> TalqynConsultantEvent? {
        TalqynConsultantEvent(message: TalqynSSEMessage(name: name, data: Data(json.utf8)))
    }

    func testStatusProductsDeltaDone() throws {
        XCTAssertEqual(event("status", #"{"stage":"thinking"}"#), .status(.thinking))
        XCTAssertEqual(event("delta", #"{"text":"hi"}"#), .delta(text: "hi"))

        guard case let .products(payload)? = event(
            "products", #"{"items":[{"talqyn_id":1,"title":"A"}],"search_id":"s1"}"#
        ) else { return XCTFail("expected a products event") }
        XCTAssertEqual(payload.items.count, 1)
        XCTAssertEqual(payload.searchID, "s1")
        XCTAssertNil(payload.groups)

        guard case let .done(done)? = event("done", #"{"session_id":"abc","ttft_ms":320,"total_ms":1800}"#)
        else { return XCTFail("expected a done event") }
        XCTAssertEqual(done.sessionID, "abc")
        XCTAssertEqual(done.timeToFirstTokenMs, 320)
        XCTAssertTrue(TalqynConsultantEvent.done(done).isTerminal)
    }

    func testMultiStepProductsCarryGroups() throws {
        guard case let .products(payload)? = event("products", """
        {"items":[{"talqyn_id":1,"title":"A"}],
         "groups":[{"role":"sofa","items":[{"talqyn_id":1,"title":"A"}]}]}
        """) else { return XCTFail("expected a products event") }
        XCTAssertEqual(payload.groups?.first?.role, "sofa")
    }

    func testClarifyEvent() throws {
        guard case let .clarify(clarify)? = event("clarify", """
        {"message":"clarify","questions":[{"id":"budget","label":"Budget","multi":false,"options":["under 300k"]}]}
        """) else { return XCTFail("expected a clarify event") }
        XCTAssertEqual(clarify.message, "clarify")
        XCTAssertEqual(clarify.questions.first?.id, "budget")
        XCTAssertEqual(clarify.questions.first?.multi, false)
    }

    func testRedirectAcceptsBothEventNames() {
        XCTAssertEqual(event("redirect_to_search", #"{"query":"iphone"}"#), .redirectToSearch(query: "iphone"))
        XCTAssertEqual(event("redirect", #"{"query":"iphone"}"#), .redirectToSearch(query: "iphone"))
    }

    func testFallbackReasonIsOpenSet() {
        XCTAssertEqual(event("fallback", #"{"reason":"budget_exceeded"}"#), .fallback(reason: .budgetExceeded))
        guard case let .fallback(reason)? = event("fallback", #"{"reason":"provider_meltdown"}"#) else {
            return XCTFail("an unknown reason must arrive, not be dropped")
        }
        XCTAssertEqual(reason.rawValue, "provider_meltdown")
        XCTAssertFalse(reason.isBudgetExhausted)
    }

    func testComparisonAction() throws {
        guard case let .action(action)? = event("action", """
        {"type":"show_comparison","table":{"talqyn_ids":[1,2],"titles":["A","B"],
         "rows":[{"label":"Screen","values":["15\\"",null]}]}}
        """) else { return XCTFail("expected an action event") }
        guard case let .showComparison(table) = action else { return XCTFail("expected a comparison") }
        XCTAssertEqual(table.talqynIDs, [1, 2])
        let values = try XCTUnwrap(table.rows.first?.values)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0], "15\"")
        XCTAssertNil(values[1], "a missing characteristic is nil, not an empty string")
    }

    func testUnknownActionTypeDoesNotBreakTurn() {
        guard case let .action(action)? = event("action", #"{"type":"open_cart"}"#) else {
            return XCTFail("expected an action event")
        }
        XCTAssertEqual(action, .unknown(type: "open_cart"))
    }

    func testFollowUpsAndError() {
        XCTAssertEqual(
            event("follow_ups", #"{"items":["which one is quieter?"]}"#),
            .followUps(items: ["which one is quieter?"])
        )
        XCTAssertEqual(event("error", #"{"code":"retrieval_failed"}"#), .error(code: "retrieval_failed"))
    }

    /// A new server-side event type must not break a shipped app.
    func testUnknownEventIsSkipped() {
        XCTAssertNil(event("telemetry", "{}"))
    }

    func testUnknownStageSurvives() {
        guard case let .status(stage)? = event("status", #"{"stage":"composing"}"#) else {
            return XCTFail("expected a status event")
        }
        XCTAssertEqual(stage.rawValue, "composing")
    }
}
