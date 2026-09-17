import Foundation
import TalqynSDK

/// A run of answer text: bold or not, and either prose or the name of a
/// product the consultant cited.
public struct TalqynTextRun: Equatable, Sendable {
    public var text: String
    public var isBold: Bool
    /// The ``TalqynProduct/talqynID`` of the product this run names, when the
    /// run stands where a `[p:ID]` marker was. `nil` for prose.
    public var productID: Int?

    public init(text: String, isBold: Bool = false, productID: Int? = nil) {
        self.text = text
        self.isBold = isBold
        self.productID = productID
    }

    /// Whether the run is a product's name put in place of a marker.
    public var isProduct: Bool { productID != nil }
}

/// One line of an answer paragraph.
public struct TalqynAnswerLine: Identifiable, Equatable, Sendable {
    /// How the line is set.
    public enum Kind: Equatable, Sendable {
        case plain
        case heading
        case bullet
        /// A numbered item, with its number as written.
        case numbered(String)
    }

    public let id: Int
    public var kind: Kind
    public var runs: [TalqynTextRun]

    public init(id: Int, kind: Kind, runs: [TalqynTextRun]) {
        self.id = id
        self.kind = kind
        self.runs = runs
    }

    /// The line as plain text, for accessibility and tests.
    public var plainText: String { runs.map(\.text).joined() }
}

/// A piece of a rendered answer: a paragraph, or the product cards cited by
/// the sentence just before them.
public enum TalqynAnswerBlock: Identifiable, Equatable, Sendable {
    case paragraph(id: Int, lines: [TalqynAnswerLine])
    case products(id: Int, items: [TalqynProduct])

    public var id: Int {
        switch self {
        case let .paragraph(id, _): return id
        case let .products(id, _): return id
        }
    }
}

/// Turns answer text into blocks a view can lay out.
///
/// The consultant writes light Markdown — `**bold**`, `# headings`, `-`
/// bullets, `1.` lists — and cites products inline as `[p:ID]`. The marker
/// stands where the product's name would be, so it is replaced by the title
/// (as a ``TalqynTextRun`` carrying the product id) and the product card is
/// pulled out of the text and placed right after the sentence that mentioned
/// it, so the card sits next to the claim rather than in a pile at the end.
/// Markers for products the turn does not have are dropped silently, and a
/// marker still being typed (`[p:12`) is hidden until it completes.
///
/// Public so a storefront with its own screen renders answers the same way.
public enum TalqynAnswerRenderer {
    // The trailing-marker pattern catches "[", "[p", "[p:", "[p:12" at the end
    // of a stream chunk: the rest of the marker is still on its way.
    private static let trailingPartialMarker = try! NSRegularExpression(pattern: #"\[(?:p(?::\d*)?)?$"#)
    private static let markerPattern = try! NSRegularExpression(pattern: #"[ \t]*\[p:(\d+)\]"#)
    // The same marker without the whitespace before it: a marker that turns
    // into a name keeps the space that separated it from the word before.
    private static let bareMarkerPattern = try! NSRegularExpression(pattern: #"\[p:(\d+)\]"#)
    private static let boldPattern = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let headingPattern = try! NSRegularExpression(pattern: #"^[ \t]{0,3}#{1,6}[ \t]+"#)
    private static let bulletPattern = try! NSRegularExpression(pattern: #"^[ \t]{0,3}[-*•][ \t]+"#)
    private static let numberedPattern = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(\d{1,2})[.)][ \t]+"#)
    private static let sentenceEndPattern = try! NSRegularExpression(pattern: #"[.!?…;]+[")»”’\]]*(?=\s|$)"#)

    /// Renders answer text.
    ///
    /// - Parameters:
    ///   - text: The answer so far, markers included.
    ///   - products: The products the markers may refer to, by Talqyn id.
    /// - Returns: Paragraphs and product blocks in reading order. Block ids
    ///   are stable across re-renders of a growing answer, so a view can diff
    ///   them.
    public static func blocks(text: String, products: [Int: TalqynProduct]) -> [TalqynAnswerBlock] {
        var blocks: [TalqynAnswerBlock] = []
        var pendingLines: [String] = []
        var shownIDs: Set<Int> = []
        var slot = 0

        func flushText() {
            let joined = pendingLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            pendingLines = []
            guard !joined.isEmpty else { return }
            blocks.append(.paragraph(id: slot * 2, lines: renderLines(joined, products: products)))
        }

        // A CRLF ends a line the way an LF does. Split on LF alone, a CRLF
        // answer keeps a "\r" at the end of every line, and the blank line
        // between two paragraphs is a lone "\r" — not the whitespace a blank
        // line is made of — so the two run into one with a stray line inside.
        let lfText = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in stripTrailingPartialMarker(lfText).components(separatedBy: "\n") {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                if !pendingLines.isEmpty {
                    flushText()
                    slot += 1
                }
                continue
            }

            var buffer = ""
            for segment in splitByCitations(line: line, products: products) {
                buffer = [buffer, segment.text].filter { !$0.isEmpty }.joined(separator: " ")
                let items = segment.citedIDs.filter { !shownIDs.contains($0) }.compactMap { products[$0] }
                guard !items.isEmpty else { continue }
                items.forEach { shownIDs.insert($0.talqynID) }
                pendingLines.append(buffer)
                buffer = ""
                flushText()
                blocks.append(.products(id: slot * 2 + 1, items: items))
                slot += 1
            }
            if !buffer.isEmpty {
                pendingLines.append(buffer)
            }
        }

        flushText()
        return blocks
    }

    /// Removes every `[p:ID]` marker, keeping the text.
    ///
    /// - Parameter text: The answer text.
    /// - Returns: The text with markers and the whitespace before them gone.
    public static func stripped(_ text: String) -> String {
        let ns = stripTrailingPartialMarker(text) as NSString
        var result = markerPattern.stringByReplacingMatches(
            in: ns as String, range: NSRange(location: 0, length: ns.length), withTemplate: ""
        )
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }

    /// The answer as plain text, with product names in place of the markers
    /// and lists written out — for the pasteboard, or a share sheet.
    ///
    /// - Parameters:
    ///   - text: The answer text, markers included.
    ///   - products: The products the markers may refer to, by Talqyn id.
    /// - Returns: Paragraphs separated by blank lines, bullets as `• `,
    ///   numbered items as `1. `. The product cards are not written out: the
    ///   sentences that cited them already name them.
    public static func plainText(_ text: String, products: [Int: TalqynProduct]) -> String {
        plainText(of: blocks(text: text, products: products))
    }

    /// The paragraphs of rendered blocks as plain text; see
    /// ``plainText(_:products:)``.
    ///
    /// - Parameter blocks: The blocks from ``blocks(text:products:)``.
    public static func plainText(of blocks: [TalqynAnswerBlock]) -> String {
        blocks.compactMap { block -> String? in
            guard case let .paragraph(_, lines) = block else { return nil }
            return lines.map { line in
                switch line.kind {
                case .plain, .heading: return line.plainText
                case .bullet: return "• " + line.plainText
                case let .numbered(number): return "\(number). " + line.plainText
                }
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// What a marker turns into: the product's title, or its brand when the
    /// title is empty. `nil` when there is nothing to show.
    private static func name(of product: TalqynProduct?) -> String? {
        guard let product else { return nil }
        for candidate in [product.title, product.brandName ?? ""] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Citations

    private struct CitationSegment {
        let text: String
        let citedIDs: [Int]
    }

    /// Splits a line at the end of every sentence that cites a product, so
    /// the cards can be placed right after it.
    ///
    /// A marker that resolves to a product stays in the segment's text, to be
    /// replaced by the product's name when the runs are built; one that does
    /// not is dropped together with the whitespace before it.
    private static func splitByCitations(line: String, products: [Int: TalqynProduct]) -> [CitationSegment] {
        let ns = line as NSString
        let matches = markerPattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [CitationSegment(text: line, citedIDs: [])] }

        // A list item is one unit: its cards go after the whole item, not
        // after the first period inside it.
        let splitsBySentence: Bool
        if case .plain = parseLine(line).kind { splitsBySentence = true } else { splitsBySentence = false }

        var segments: [CitationSegment] = []
        var cleaned = ""
        var citedIDs: [Int] = []
        var cursor = 0

        for (index, match) in matches.enumerated() {
            cleaned += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length

            let id = Int(ns.substring(with: match.range(at: 1)))
            if let id, name(of: products[id]) != nil {
                cleaned += ns.substring(with: match.range)
            }
            if let id, products[id] != nil, !citedIDs.contains(id) {
                citedIDs.append(id)
            }
            guard !citedIDs.isEmpty else { continue }

            let sentenceEnd = splitsBySentence ? sentenceEndLocation(in: ns, from: cursor) : ns.length
            let nextMarker = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard nextMarker >= sentenceEnd else { continue }

            cleaned += ns.substring(with: NSRange(location: cursor, length: sentenceEnd - cursor))
            cursor = sentenceEnd
            segments.append(CitationSegment(text: trimmed(cleaned, keepingIndent: segments.isEmpty), citedIDs: citedIDs))
            cleaned = ""
            citedIDs = []
        }

        cleaned += ns.substring(from: cursor)
        let tail = trimmed(cleaned, keepingIndent: segments.isEmpty)
        if !tail.isEmpty || !citedIDs.isEmpty {
            segments.append(CitationSegment(text: tail, citedIDs: citedIDs))
        }
        return segments
    }

    private static func sentenceEndLocation(in ns: NSString, from location: Int) -> Int {
        let range = NSRange(location: location, length: ns.length - location)
        guard let match = sentenceEndPattern.firstMatch(in: ns as String, range: range) else { return ns.length }
        return match.range.location + match.range.length
    }

    private static func trimmed(_ text: String, keepingIndent: Bool) -> String {
        var value = text
        while let last = value.last, last.isWhitespace { value.removeLast() }
        guard !keepingIndent else { return value }
        while let first = value.first, first.isWhitespace { value.removeFirst() }
        return value
    }

    // MARK: - Markdown

    private static func parseLine(_ line: String) -> (kind: TalqynAnswerLine.Kind, content: String) {
        let ns = line as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        if let match = headingPattern.firstMatch(in: line, range: fullRange) {
            return (.heading, ns.substring(from: match.range.length))
        }
        if let match = bulletPattern.firstMatch(in: line, range: fullRange) {
            return (.bullet, ns.substring(from: match.range.length))
        }
        if let match = numberedPattern.firstMatch(in: line, range: fullRange) {
            return (.numbered(ns.substring(with: match.range(at: 1))), ns.substring(from: match.range.length))
        }
        return (.plain, line)
    }

    private static func renderLines(_ text: String, products: [Int: TalqynProduct]) -> [TalqynAnswerLine] {
        text.components(separatedBy: "\n").enumerated().map { index, line in
            let (kind, content) = parseLine(line)
            return TalqynAnswerLine(id: index, kind: kind, runs: runs(content, products: products))
        }
    }

    /// `**bold**` becomes a bold run and a `[p:ID]` marker becomes the
    /// product's name; everything else stays regular.
    private static func runs(_ text: String, products: [Int: TalqynProduct]) -> [TalqynTextRun] {
        var result: [TalqynTextRun] = []
        let ns = text as NSString
        var cursor = 0
        for match in boldPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result += namedRuns(
                    ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                    isBold: false, products: products
                )
            }
            result += namedRuns(ns.substring(with: match.range(at: 1)), isBold: true, products: products)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += namedRuns(ns.substring(from: cursor), isBold: false, products: products)
        }
        return result
    }

    /// Splits a run at its markers, putting the product's name where each
    /// marker was. A marker with no name to show is dropped.
    private static func namedRuns(_ text: String, isBold: Bool, products: [Int: TalqynProduct]) -> [TalqynTextRun] {
        var result: [TalqynTextRun] = []
        let ns = text as NSString
        var cursor = 0
        for match in bareMarkerPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result.append(TalqynTextRun(
                    text: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                    isBold: isBold
                ))
            }
            if let id = Int(ns.substring(with: match.range(at: 1))), let name = name(of: products[id]) {
                result.append(TalqynTextRun(text: name, isBold: isBold, productID: id))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result.append(TalqynTextRun(text: ns.substring(from: cursor), isBold: isBold))
        }
        return result
    }

    private static func stripTrailingPartialMarker(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = trailingPartialMarker.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return text }
        return String(text[..<r.lowerBound])
    }
}
