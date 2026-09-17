import XCTest
import TalqynSDK
import TalqynTestSupport
@testable import TalqynConsultantCore

@MainActor
final class ChatHistoryTests: XCTestCase {
    private func chats(_ ids: [String]) -> String {
        "[" + ids.map { #"{"session_id":"\#($0)","title":"chat \#($0)","message_count":2,"last_message_at":"2026-08-26T12:00:00Z"}"# }
            .joined(separator: ",") + "]"
    }

    private func settled(_ history: TalqynChatHistory) async {
        for _ in 0..<100 {
            switch history.state {
            case .loading: try? await Task.sleep(nanoseconds: 10_000_000)
            case let .loaded(_, isLoadingMore) where isLoadingMore: try? await Task.sleep(nanoseconds: 10_000_000)
            default: return
            }
        }
    }

    func testPagesLoadUntilAShortPage() async throws {
        let transport = StubTransport()
        transport.enqueue(json: chats(["a", "b"]))
        transport.enqueue(json: chats(["b", "c"]))
        transport.enqueue(json: chats(["d"]))
        let history = TalqynChatHistory(talqyn: try await TestFixtures.preparedClient(transport: transport), pageSize: 2)

        history.load()
        XCTAssertEqual(history.state, .loading)
        await settled(history)
        guard case let .loaded(first, _) = history.state else { return XCTFail("expected a loaded page") }
        XCTAssertEqual(first.map(\.sessionID), ["a", "b"])
        XCTAssertEqual(transport.sent.last?.query, "limit=2&offset=0")

        history.loadMoreIfNeeded(after: first[1])
        await settled(history)
        guard case let .loaded(second, _) = history.state else { return XCTFail("expected the second page") }
        XCTAssertEqual(second.map(\.sessionID), ["a", "b", "c"], "an overlap is not shown twice")
        XCTAssertEqual(transport.sent.last?.query, "limit=2&offset=2")

        history.loadMoreIfNeeded(after: second[2])
        await settled(history)
        guard case let .loaded(third, _) = history.state else { return XCTFail("expected the third page") }
        XCTAssertEqual(third.map(\.sessionID), ["a", "b", "c", "d"])

        history.loadMoreIfNeeded(after: third[3])
        await settled(history)
        XCTAssertEqual(transport.sent.count, 3, "a short page ends the list: no request after it")
    }

    func testEmptyAndFailedStates() async throws {
        let transport = StubTransport()
        transport.enqueue(json: "[]")
        transport.enqueue(json: #"{"detail":"no shopper"}"#, status: 403)
        let history = TalqynChatHistory(talqyn: try await TestFixtures.preparedClient(transport: transport))

        history.load()
        await settled(history)
        XCTAssertEqual(history.state, .empty)

        history.load()
        await settled(history)
        guard case let .failed(error) = history.state, case .forbidden = error else {
            return XCTFail("expected a forbidden failure, got \(history.state)")
        }
    }

    func testDeleteRemovesTheRowAtOnceAndReloadsOnFailure() async throws {
        let transport = StubTransport()
        transport.enqueue(json: chats(["a", "b"]))
        transport.enqueue(json: "", status: 204)
        let history = TalqynChatHistory(talqyn: try await TestFixtures.preparedClient(transport: transport), pageSize: 20)
        history.load()
        await settled(history)

        history.delete(sessionID: "a")
        guard case let .loaded(rows, _) = history.state else { return XCTFail("expected rows") }
        XCTAssertEqual(rows.map(\.sessionID), ["b"], "gone before the server answers")
        for _ in 0..<100 {
            if transport.sent.last?.request.httpMethod == "DELETE" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.sent.last?.path, "/v1/consultant/chats/a")

        transport.enqueue(json: #"{"error":"internal_error"}"#, status: 500)
        transport.enqueue(json: chats(["b"]))
        history.delete(sessionID: "b")
        for _ in 0..<100 {
            if transport.sent.filter({ $0.path.hasSuffix("/consultant/chats") }).count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await settled(history)
        guard case let .loaded(reloaded, _) = history.state else { return XCTFail("expected the list back") }
        XCTAssertEqual(reloaded.map(\.sessionID), ["b"], "a failed deletion brings the row back")
    }

    func testSubtitleFormats() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 15, minute: 30)))
        let strings = TalqynUIStrings.ru
        let locale = strings.locale
        func subtitle(_ date: Date?) -> String {
            TalqynChatHistory.subtitle(for: date, strings: strings, locale: locale, calendar: calendar, now: now)
        }
        XCTAssertEqual(subtitle(nil), "")
        XCTAssertEqual(subtitle(calendar.date(byAdding: .hour, value: -2, to: now)), "13:30")
        XCTAssertEqual(subtitle(calendar.date(byAdding: .day, value: -1, to: now)), "Вчера")
        XCTAssertEqual(subtitle(calendar.date(byAdding: .day, value: -40, to: now)), "1 авг.")
        XCTAssertEqual(
            subtitle(calendar.date(byAdding: .year, value: -1, to: now)), "10 сент. 2025\u{202F}г.",
            "the year is written the way the locale writes it, narrow no-break space included"
        )
    }

    /// English is the set whose date shapes differ most from the other two:
    /// a 12-hour clock and the month before the day.
    func testEnglishSubtitleFormats() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 15, minute: 30)))
        let strings = TalqynUIStrings.en
        func subtitle(_ date: Date?) -> String {
            TalqynChatHistory.subtitle(for: date, strings: strings, locale: strings.locale, calendar: calendar, now: now)
        }
        XCTAssertEqual(
            subtitle(calendar.date(byAdding: .hour, value: -2, to: now)), "1:30\u{202F}PM",
            "a 12-hour clock, narrow no-break space included"
        )
        XCTAssertEqual(subtitle(calendar.date(byAdding: .day, value: -1, to: now)), "Yesterday")
        XCTAssertEqual(subtitle(calendar.date(byAdding: .day, value: -40, to: now)), "Aug 1")
        XCTAssertEqual(subtitle(calendar.date(byAdding: .year, value: -1, to: now)), "Sep 10, 2025")
    }
}
