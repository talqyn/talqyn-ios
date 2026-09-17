import Foundation

/// The SDK's coders, one instance per process.
///
/// Keys are declared as explicit `CodingKeys` on every model rather than derived
/// by a strategy: this is a public contract, and a field name should be readable
/// next to the model instead of following from a decoder setting.
enum TalqynCoding {
    static var decoder: JSONDecoder { Shared.instance.decoder }

    static var encoder: JSONEncoder { Shared.instance.encoder }

    /// ISO-8601 with and without fractional seconds: Postgres emits `created_at`
    /// both ways, and a client has no business failing on that.
    static func date(from raw: String) -> Date? {
        let shared = Shared.instance
        if let date = shared.fractional.date(from: raw) { return date }
        if let date = shared.plain.date(from: raw) { return date }
        return nil
    }

    /// An RFC 7231 HTTP date, `Sun, 06 Nov 1994 08:49:37 GMT` — the form of the
    /// `Date` header and the second form of `Retry-After`.
    ///
    /// The formatter is built on demand: this runs on a rejected request, not
    /// on every response.
    static func httpDate(from raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    /// Coders and formatters are expensive to build, so there is one of each.
    /// `@unchecked Sendable`: they are never reconfigured after init, and
    /// `JSONDecoder`, `JSONEncoder`, and `ISO8601DateFormatter` are thread-safe
    /// for read-only use.
    private final class Shared: @unchecked Sendable {
        static let instance = Shared()

        let decoder = JSONDecoder()
        let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            // Key order must stay as declared: a mint request body is signed
            // byte for byte, so no .sortedKeys and no .prettyPrinted here.
            encoder.outputFormatting = []
            return encoder
        }()
        let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        let plain: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
    }
}

extension KeyedDecodingContainer {
    /// A value or a fallback. A missing key and a `null` read the same: Talqyn
    /// serializes SSE events with `exclude_none`, so a field left at its default
    /// simply never arrives.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// An optional value, tolerant of an unexpected type: one odd field must not
    /// bring down the whole response.
    func optional<T: Decodable>(_ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }

    func date(_ key: Key) -> Date? {
        guard let raw: String = optional(key) else { return nil }
        return TalqynCoding.date(from: raw)
    }

    /// An array that drops the elements it cannot decode. One malformed card
    /// must cost that card, not the whole page it came in.
    func array<T: Decodable>(_ key: Key) -> [T] {
        (try? decodeIfPresent(TalqynLossyArray<T>.self, forKey: key))?.elements ?? []
    }

    /// ``array(_:)`` for a field whose absence is meaningful.
    func optionalArray<T: Decodable>(_ key: Key) -> [T]? {
        (try? decodeIfPresent(TalqynLossyArray<T>.self, forKey: key))?.elements
    }
}

/// An array decoded element by element, skipping what does not decode.
///
/// `[T].init(from:)` is all-or-nothing: one element failing fails the array,
/// and behind a `try?` that reads as an empty list — a listing page with
/// `total: 2` and no results, a transcript with no messages. Server-side data
/// is not uniform enough to bet a whole screen on every row.
struct TalqynLossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(TalqynSkippedValue.self)) == nil {
                // A failed decode leaves the index in place; consuming the
                // value as a placeholder moves past it. If even that fails,
                // stop rather than spin.
                break
            }
        }
        self.elements = elements
    }
}

/// A placeholder that consumes one value of any type without keeping it.
struct TalqynSkippedValue: Decodable {
    init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer()
    }
}
