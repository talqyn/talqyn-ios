import XCTest
import TalqynTestSupport
@testable import TalqynSDK

final class SSEDecoderTests: XCTestCase {
    private func messages(_ lines: [String]) -> [TalqynSSEMessage] {
        var decoder = TalqynSSEDecoder()
        var result = lines.compactMap { decoder.consume(line: $0) }
        if let tail = decoder.finish() { result.append(tail) }
        return result
    }

    func testEventAndDataDispatchedOnBlankLine() {
        let parsed = messages(["event: delta", "data: {\"text\":\"hi\"}", ""])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "delta")
        XCTAssertEqual(String(data: parsed[0].data, encoding: .utf8), "{\"text\":\"hi\"}")
    }

    func testMultilineDataJoinedWithNewline() {
        let parsed = messages(["event: delta", "data: {", "data: \"text\": \"a\"}", ""])
        XCTAssertEqual(String(data: parsed[0].data, encoding: .utf8), "{\n\"text\": \"a\"}")
    }

    func testCommentsAndUnknownFieldsIgnored() {
        let parsed = messages([": keep-alive", "id: 42", "retry: 1000", "event: done", "data: {}", ""])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "done")
    }

    /// A proxy may swallow the blank line between events; they must not merge.
    func testEventLineFlushesPendingMessage() {
        let parsed = messages(["event: status", "data: {\"stage\":\"thinking\"}", "event: done", "data: {}", ""])
        XCTAssertEqual(parsed.map(\.name), ["status", "done"])
    }

    func testFinishEmitsMessageWithoutTrailingBlankLine() {
        let parsed = messages(["event: done", "data: {\"session_id\":\"abc\"}"])
        XCTAssertEqual(parsed.map(\.name), ["done"])
    }

    func testOnlyOneLeadingSpaceStripped() {
        let parsed = messages(["event: delta", "data:  {\"text\":\"x\"}", ""])
        XCTAssertEqual(String(data: parsed[0].data, encoding: .utf8), " {\"text\":\"x\"}")
    }

    func testDataWithoutEventNameDefaultsToMessage() {
        let parsed = messages(["data: {}", ""])
        XCTAssertEqual(parsed.first?.name, "message")
    }
}
