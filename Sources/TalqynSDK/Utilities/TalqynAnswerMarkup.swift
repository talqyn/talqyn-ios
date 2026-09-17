import Foundation

/// Product markers inside consultant text.
///
/// Text arriving in ``TalqynConsultantEvent/delta(text:)`` may contain inline
/// markers of the form `[p:1234]`, where the number is a
/// ``TalqynProduct/talqynID`` from a `products` event already delivered in the
/// same turn. The server strips markers pointing at products outside the turn's
/// results before they leave, so any marker reaching a client is valid and
/// resolves to an element of ``TalqynConsultantProducts/items``.
///
/// Render one as a link or a chip to the product — or drop it with
/// ``stripped(_:)`` if inline mentions are not part of your design.
///
/// ```swift
/// for segment in TalqynAnswerMarkup.segments(text) {
///     switch segment {
///     case .text(let run):          append(run)
///     case .product(let talqynID):  appendChip(for: talqynID)
///     }
/// }
/// ```
public enum TalqynAnswerMarkup {
    /// A run of answer text, or a product mentioned inside it.
    public enum Segment: Sendable, Equatable {
        /// Plain text, with no markers left in it.
        case text(String)
        /// A product mention.
        ///
        /// - Parameter talqynID: The product's ``TalqynProduct/talqynID``.
        case product(talqynID: Int)
    }

    // `[0-9]`, not `\d`: in ICU `\d` matches every Unicode digit, and `Int`
    // parses ASCII only — such a marker would match and then vanish.
    private static let pattern = try? NSRegularExpression(pattern: "\\[p:([0-9]+)\\]")

    /// Splits answer text into text runs and product mentions.
    ///
    /// Anything that looks like a marker but does not parse — `[p:abc]`, or a
    /// number too large for `Int` — stays as text.
    ///
    /// - Parameter text: The answer text, or one delta of it.
    /// - Returns: The segments in order. Empty for empty input; a single
    ///   ``Segment/text(_:)`` when there are no markers.
    public static func segments(_ text: String) -> [Segment] {
        guard let pattern, !text.isEmpty else {
            return text.isEmpty ? [] : [.text(text)]
        }
        let nsText = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return [.text(text)] }

        var segments: [Segment] = []
        // Adjacent text runs merge, so a marker kept as text does not split
        // the sentence around it into three segments.
        func append(text: String) {
            guard !text.isEmpty else { return }
            if case let .text(previous)? = segments.last {
                segments[segments.count - 1] = .text(previous + text)
            } else {
                segments.append(.text(text))
            }
        }

        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                append(text: nsText.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                ))
            }
            if match.numberOfRanges > 1,
               let identifier = Int(nsText.substring(with: match.range(at: 1))) {
                segments.append(.product(talqynID: identifier))
            } else {
                append(text: nsText.substring(with: match.range))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            append(text: nsText.substring(from: cursor))
        }
        return segments
    }

    /// Removes every product marker from answer text.
    ///
    /// Built on ``segments(_:)``, so the two agree on what counts as a marker.
    ///
    /// - Parameter text: The answer text, or one delta of it.
    /// - Returns: The same text with `[p:ID]` markers deleted. Surrounding
    ///   spacing is left untouched.
    public static func stripped(_ text: String) -> String {
        segments(text).compactMap {
            if case let .text(run) = $0 { return run }
            return nil
        }.joined()
    }

    /// Collects the products mentioned in answer text.
    ///
    /// - Parameter text: The answer text, or one delta of it.
    /// - Returns: The ``TalqynProduct/talqynID`` values in order of appearance,
    ///   including repeats.
    public static func mentionedProductIDs(_ text: String) -> [Int] {
        segments(text).compactMap {
            if case let .product(identifier) = $0 { return identifier }
            return nil
        }
    }
}
