import XCTest
import TalqynTestSupport
@testable import TalqynSDK

/// The one piece of SSE parsing written by hand instead of taken from
/// Foundation: `bytes.lines` breaks on U+2028, U+2029, and NEL, which are legal
/// inside a JSON string.
final class LineSplitterTests: XCTestCase {
    private func split(_ text: String) -> [String] {
        var splitter = TalqynLineSplitter()
        var lines = Array(text.utf8).compactMap { splitter.consume($0) }
        if let tail = splitter.finish() { lines.append(tail) }
        return lines
    }

    func testEveryTerminatorTheSpecificationAllows() {
        XCTAssertEqual(split("a\nb\n"), ["a", "b"])
        XCTAssertEqual(split("a\rb\r"), ["a", "b"])
        XCTAssertEqual(split("a\r\nb\r\n"), ["a", "b"])
        XCTAssertEqual(split("a\r\n\r\nb\n"), ["a", "", "b"], "CR LF is one terminator; the blank line survives")
        XCTAssertEqual(split("a\n\rb"), ["a", "", "b"], "LF CR is two terminators")
    }

    func testTailWithoutTerminatorIsEmittedOnFinish() {
        XCTAssertEqual(split("event: done\ndata: {}"), ["event: done", "data: {}"])
        XCTAssertEqual(split(""), [])
        XCTAssertEqual(split("\n"), [""])
    }

    func testUnicodeLineSeparatorsStayInsideTheLine() {
        let delta = "data: {\"text\":\"line\u{2028}more\u{2029}and\u{85}end\"}"
        XCTAssertEqual(split(delta + "\n\n"), [delta, ""])
    }

    func testTerminatorSplitAcrossChunksIsOneTerminator() async throws {
        // The CR ends one chunk and the LF opens the next.
        let chunks: [[UInt8]] = [Array("event: delta\r".utf8), Array("\ndata: {}\r\n\r\n".utf8)]
        let bytes = AsyncStream<UInt8> { continuation in
            for chunk in chunks { for byte in chunk { continuation.yield(byte) } }
            continuation.finish()
        }
        var lines: [String] = []
        for try await line in TalqynLineSplitter.lines(from: bytes) { lines.append(line) }
        XCTAssertEqual(lines, ["event: delta", "data: {}", ""])
    }

    func testLinesFromReportsTheUnderlyingFailure() async {
        struct Dropped: Error {}
        let bytes = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in "data: {".utf8 { continuation.yield(byte) }
            continuation.finish(throwing: Dropped())
        }
        var lines: [String] = []
        do {
            for try await line in TalqynLineSplitter.lines(from: bytes) { lines.append(line) }
            XCTFail("expected the failure to propagate")
        } catch {
            XCTAssertTrue(error is Dropped)
        }
        XCTAssertTrue(lines.isEmpty, "an unterminated line is not delivered on failure")
    }
}
