import Foundation

/// One event parsed out of a `text/event-stream` response.
public struct TalqynSSEMessage: Sendable, Equatable {
    /// The event name, from the `event:` field. `"message"` when the stream
    /// omitted one.
    public var name: String

    /// The raw JSON payload assembled from the event's `data:` fields.
    public var data: Data
}

/// An incremental parser for `text/event-stream` bodies.
///
/// State lives outside the stream on purpose: the parser can then be exercised
/// line by line in a test, with no network and no concurrency.
///
/// Talqyn emits `event: <name>`, one or more `data: <json>` lines, and a blank
/// line. Comment lines (a leading `:`, used by proxies for keep-alive) and the
/// `id` and `retry` fields are skipped.
///
/// ```swift
/// var decoder = TalqynSSEDecoder()
/// for try await line in lines {
///     if let message = decoder.consume(line: line) { handle(message) }
/// }
/// if let tail = decoder.finish() { handle(tail) }
/// ```
public struct TalqynSSEDecoder: Sendable {
    private static let defaultEventName = "message"

    private var name = TalqynSSEDecoder.defaultEventName
    private var payload: [String] = []

    /// Creates a parser positioned at the start of a stream.
    public init() {}

    /// Feeds the parser one line of the response body.
    ///
    /// - Parameter line: A single line, with its terminator already stripped.
    /// - Returns: The event this line completed, or `nil` if the event is still
    ///   being accumulated.
    public mutating func consume(line: String) -> TalqynSSEMessage? {
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") {
            return nil
        }
        if line.hasPrefix("event:") {
            // Flush before renaming: `event:` always opens a new event here, so
            // a blank line dropped by a proxy must not merge two into one.
            let completed = flush()
            name = Self.fieldValue(line, prefix: "event:")
            return completed
        }
        if line.hasPrefix("data:") {
            payload.append(Self.fieldValue(line, prefix: "data:"))
            return nil
        }
        return nil
    }

    /// Closes the stream, emitting an event that never got its trailing blank
    /// line.
    ///
    /// - Returns: The pending event, or `nil` if nothing was buffered.
    public mutating func finish() -> TalqynSSEMessage? {
        flush()
    }

    private mutating func flush() -> TalqynSSEMessage? {
        defer {
            name = Self.defaultEventName
            payload = []
        }
        guard !payload.isEmpty else { return nil }
        guard let data = payload.joined(separator: "\n").data(using: .utf8) else { return nil }
        return TalqynSSEMessage(name: name, data: data)
    }

    /// A field value: the specification strips exactly **one** space after the
    /// colon, no more.
    private static func fieldValue(_ line: String, prefix: String) -> String {
        var value = Substring(line.dropFirst(prefix.count))
        if value.first == " " { value = value.dropFirst() }
        return String(value)
    }
}

/// Splits a byte stream into lines the way `text/event-stream` defines them.
///
/// CR, LF, or CR LF end a line, and nothing else does. Foundation's
/// `AsyncLineSequence` — `bytes.lines` — also breaks on U+2028, U+2029, and
/// NEL, characters that are legal inside a JSON string, so a `data:` line
/// carrying one would come apart and its event would be dropped. Splitting on
/// bytes is safe: no UTF-8 continuation byte equals CR or LF.
///
/// Public so a custom ``TalqynHTTPTransport`` can split its streamed body the
/// same way; ``lines(from:)`` does it over any byte sequence, such as
/// `URLSession.AsyncBytes`.
public struct TalqynLineSplitter: Sendable {
    private var buffer: [UInt8] = []
    /// A CR was just seen: a following LF belongs to the same terminator.
    private var pendingCR = false

    /// Creates a splitter positioned at the start of a stream.
    public init() {}

    /// Splits a byte sequence into a ``TalqynLineStream``.
    ///
    /// Cancelling the returned stream cancels the iteration of `bytes` — and,
    /// for `URLSession.AsyncBytes`, the request behind it.
    ///
    /// - Parameter bytes: The response body, byte by byte.
    /// - Returns: The body's lines, terminators stripped, as they complete.
    public static func lines<Bytes>(from bytes: Bytes) -> TalqynLineStream
    where Bytes: AsyncSequence & Sendable, Bytes.Element == UInt8 {
        TalqynLineStream { continuation in
            let task = Task {
                do {
                    var splitter = TalqynLineSplitter()
                    for try await byte in bytes {
                        if let line = splitter.consume(byte) {
                            continuation.yield(line)
                        }
                    }
                    if let tail = splitter.finish() {
                        continuation.yield(tail)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Feeds one byte.
    ///
    /// - Parameter byte: The next byte of the body.
    /// - Returns: The line this byte terminated, without its terminator, or
    ///   `nil` if the line is still being accumulated.
    public mutating func consume(_ byte: UInt8) -> String? {
        switch byte {
        case 0x0D:
            pendingCR = true
            return take()
        case 0x0A:
            if pendingCR {
                pendingCR = false
                return nil
            }
            return take()
        default:
            pendingCR = false
            buffer.append(byte)
            return nil
        }
    }

    /// Ends the stream, emitting a last line that had no terminator.
    ///
    /// - Returns: The unterminated last line, or `nil` if nothing was buffered.
    public mutating func finish() -> String? {
        pendingCR = false
        return buffer.isEmpty ? nil : take()
    }

    private mutating func take() -> String {
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }
}
