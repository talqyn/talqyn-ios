#if os(iOS)
import TalqynConsultantCore
import UIKit

/// Turns rendered answer lines into an attributed string in the theme's fonts:
/// headings, bullets and numbered items with a hanging indent, bold runs, and
/// product names that open the product.
enum TalqynAnswerText {
    private static let lineSpacing: CGFloat = 3
    private static let listIndent: CGFloat = 16
    private static let productScheme = "talqyn-product"

    static func attributed(_ lines: [TalqynAnswerLine], theme: TalqynTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            result.append(render(line, isLast: index == lines.count - 1, theme: theme))
        }
        return result
    }

    /// The link a product name carries in the text.
    static func link(toProduct id: Int) -> URL? {
        URL(string: "\(productScheme)://\(id)")
    }

    /// The product a link in the text points at, or `nil` for any other link.
    static func productID(from url: URL) -> Int? {
        guard url.scheme == productScheme, let host = url.host else { return nil }
        return Int(host)
    }

    private static func render(_ line: TalqynAnswerLine, isLast: Bool, theme: TalqynTheme) -> NSAttributedString {
        let color = theme.colors.textPrimary
        let body = theme.fonts.body
        let result = NSMutableAttributedString()

        switch line.kind {
        case .heading:
            result.append(inline(line.runs, font: theme.fonts.headline, bold: theme.fonts.headline, color: color))
        case .bullet:
            result.append(NSAttributedString(string: "•\t", attributes: [.font: body, .foregroundColor: color]))
            result.append(inline(line.runs, font: body, bold: theme.fonts.bodyBold, color: color))
        case let .numbered(number):
            result.append(NSAttributedString(string: "\(number).\t", attributes: [.font: body, .foregroundColor: color]))
            result.append(inline(line.runs, font: body, bold: theme.fonts.bodyBold, color: color))
        case .plain:
            result.append(inline(line.runs, font: body, bold: theme.fonts.bodyBold, color: color))
        }

        if !isLast {
            result.append(NSAttributedString(string: "\n", attributes: [.font: body, .foregroundColor: color]))
        }
        result.addAttribute(
            .paragraphStyle, value: paragraphStyle(for: line.kind), range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private static func paragraphStyle(for kind: TalqynAnswerLine.Kind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        switch kind {
        case .bullet, .numbered:
            style.headIndent = listIndent
            style.defaultTabInterval = listIndent
            style.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
        case .heading:
            style.paragraphSpacingBefore = 2
        case .plain:
            break
        }
        return style
    }

    /// Bold runs and product names are set in the bold face: a name stands
    /// where the consultant put a marker, and the weight tells it apart from
    /// the prose around it. A name is also a link to its product — the card
    /// may be a paragraph away, the name is right under the finger.
    private static func inline(_ runs: [TalqynTextRun], font: UIFont, bold: UIFont, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: run.isBold || run.isProduct ? bold : font,
                .foregroundColor: color,
            ]
            if let id = run.productID, let link = link(toProduct: id) {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    /// A non-editable text view for answer text: no insets, no scrolling,
    /// selectable so a shopper can copy a model name and follow a product
    /// link, which is drawn in the accent.
    @MainActor static func makeTextView(theme: TalqynTheme) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [.foregroundColor: theme.colors.accent]
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }
}
#endif
