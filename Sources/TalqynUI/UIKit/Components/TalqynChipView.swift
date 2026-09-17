#if os(iOS)
import UIKit

/// A pill-shaped chip: suggestions, clarify options, examples.
final class TalqynChipView: UIControl {
    private let label = UILabel()
    private let theme: TalqynTheme
    private let height: CGFloat

    /// The height the theme's metrics gave this chip.
    var intrinsicChipHeight: CGFloat { height }
    private let horizontalInset: CGFloat = 16

    var onTap: (() -> Void)?

    /// The widest the chip may be. Without it the label measures itself on one
    /// line however long the question is, and the pill runs off the screen
    /// instead of wrapping. `0` leaves the chip unbounded.
    var maxWidth: CGFloat = 0 {
        didSet {
            guard maxWidth != oldValue else { return }
            label.preferredMaxLayoutWidth = max(0, maxWidth - horizontalInset * 2)
            invalidateIntrinsicContentSize()
        }
    }

    init(theme: TalqynTheme, title: String, isSelected: Bool = false, maxLines: Int = 3) {
        self.theme = theme
        height = theme.metrics.chipHeight
        super.init(frame: .zero)
        label.text = title
        label.font = theme.fonts.footnote
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = maxLines
        label.isUserInteractionEnabled = false
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 7),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: horizontalInset),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: height - 14),
        ])
        layer.cornerRadius = theme.metrics.chipRadius ?? height / 2
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        self.isSelected = isSelected
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isSelected: Bool {
        didSet {
            apply()
            accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    /// A chip can be drawn shorter than a finger; it still takes the tap. Rows
    /// of chips sit 8 points apart, which is exactly what a 36-point chip
    /// grows by, so neighbours never overlap.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        TalqynHitArea.contains(point, in: bounds)
    }

    @objc private func tapped() {
        TalqynHaptics.tap(theme)
        onTap?()
    }

    private func apply() {
        backgroundColor = isSelected ? theme.colors.accent : theme.colors.surface
        label.textColor = isSelected ? theme.colors.onAccent : theme.colors.textPrimary
        layer.borderColor = (isSelected ? theme.colors.accent : theme.colors.border).cgColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        apply()
    }
}

/// Lays chips out left to right, wrapping onto new rows, optionally centered.
///
/// Sizing is manual: the view reports its height from the chips and the
/// width it was given, which is why a width must be known before layout —
/// through ``preferredLayoutWidth`` in a cell, or from `bounds` elsewhere.
final class TalqynChipsFlowView: UIView {
    var centersRows = false {
        didSet { setNeedsLayout() }
    }

    var preferredLayoutWidth: CGFloat = 0 {
        didSet {
            guard preferredLayoutWidth != oldValue else { return }
            recalculateHeight()
        }
    }

    private let horizontalSpacing: CGFloat = 8
    private let verticalSpacing: CGFloat = 8

    private var chips: [UIView] = []
    private var cachedHeight: CGFloat = 0

    func setChips(_ views: [UIView]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = views
        views.forEach { addSubview($0) }
        recalculateHeight()
        setNeedsLayout()
    }

    private func recalculateHeight() {
        guard preferredLayoutWidth > 0 else { return }
        let height = layoutChips(width: preferredLayoutWidth, apply: false)
        guard height != cachedHeight else { return }
        cachedHeight = height
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: cachedHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = layoutChips(width: bounds.width, apply: true)
        guard height != cachedHeight else { return }
        cachedHeight = height
        invalidateIntrinsicContentSize()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: layoutChips(width: size.width, apply: false))
    }

    @discardableResult
    private func layoutChips(width: CGFloat, apply: Bool) -> CGFloat {
        guard width > 0 else { return 0 }

        var rows: [[(chip: UIView, size: CGSize)]] = [[]]
        var rowWidth: CGFloat = 0
        for chip in chips {
            (chip as? TalqynChipView)?.maxWidth = width
            var size = chip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            if size.width > width {
                size = chip.systemLayoutSizeFitting(
                    CGSize(width: width, height: 0),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                )
                size.width = width
            }
            if rowWidth > 0, rowWidth + size.width > width {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append((chip, size))
            rowWidth += size.width + horizontalSpacing
        }

        var y: CGFloat = 0
        for row in rows where !row.isEmpty {
            let contentWidth = row.reduce(0) { $0 + $1.size.width } + horizontalSpacing * CGFloat(row.count - 1)
            var x = centersRows ? max(0, (width - contentWidth) / 2) : 0
            let rowHeight = row.map(\.size.height).max() ?? 0
            for item in row {
                if apply {
                    item.chip.frame = CGRect(origin: CGPoint(x: x, y: y), size: item.size)
                }
                x += item.size.width + horizontalSpacing
            }
            y += rowHeight + verticalSpacing
        }
        return max(0, y - verticalSpacing)
    }
}
#endif
