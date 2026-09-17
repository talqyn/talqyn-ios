#if os(iOS)
import UIKit

/// Auto Layout without a dependency: the handful of shapes the screens use.
extension UIView {
    /// Adds `subview` and pins its edges to this view's edges.
    func talqynPin(_ subview: UIView, insets: UIEdgeInsets = .zero, to guide: UILayoutGuide? = nil) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subview)
        let top = guide?.topAnchor ?? topAnchor
        let bottom = guide?.bottomAnchor ?? bottomAnchor
        let leading = guide?.leadingAnchor ?? leadingAnchor
        let trailing = guide?.trailingAnchor ?? trailingAnchor
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: top, constant: insets.top),
            subview.leadingAnchor.constraint(equalTo: leading, constant: insets.left),
            trailing.constraint(equalTo: subview.trailingAnchor, constant: insets.right),
            bottom.constraint(equalTo: subview.bottomAnchor, constant: insets.bottom),
        ])
    }

    /// Fixes the size.
    func talqynSize(_ size: CGSize) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
    }

    /// Fixes the size to a square.
    func talqynSize(_ side: CGFloat) {
        talqynSize(CGSize(width: side, height: side))
    }

    /// Fixes the height.
    @discardableResult
    func talqynHeight(_ height: CGFloat) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        let constraint = heightAnchor.constraint(equalToConstant: height)
        constraint.isActive = true
        return constraint
    }

    /// Hides or shows without re-triggering a stack view layout when nothing
    /// changes: `UIStackView` reacts to every write of `isHidden`.
    func talqynSetHidden(_ hidden: Bool) {
        guard isHidden != hidden else { return }
        isHidden = hidden
    }

    /// Rounds the corners; `continuous` for the softer, iOS-native curve.
    func talqynRound(_ radius: CGFloat, corners: CACornerMask? = nil) {
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        if let corners { layer.maskedCorners = corners }
        clipsToBounds = true
    }
}

extension UIStackView {
    /// A vertical stack with padding on the sides, the way the original laid
    /// out the text of a turn.
    static func talqynVertical(_ views: [UIView] = [], spacing: CGFloat, horizontalMargin: CGFloat = 0) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = spacing
        if horizontalMargin > 0 {
            stack.isLayoutMarginsRelativeArrangement = true
            stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 0, leading: horizontalMargin, bottom: 0, trailing: horizontalMargin
            )
        }
        return stack
    }

    func talqynRemoveAllArranged() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

/// Haptics for taps that mean something: a chip picked, a question sent.
enum TalqynHaptics {
    /// A light knock, unless the theme turned haptics off.
    @MainActor static func tap(_ theme: TalqynTheme) {
        guard theme.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

extension UIImage {
    /// The icon at a size, when it is an SF Symbol. An app's own artwork has
    /// no symbol configuration to apply and comes back untouched.
    ///
    /// - Parameters:
    ///   - pointSize: The symbol's point size.
    ///   - weight: The symbol's weight.
    func talqynSized(_ pointSize: CGFloat, _ weight: UIImage.SymbolWeight = .regular) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return applyingSymbolConfiguration(configuration) ?? self
    }
}

/// How long an animation runs, or none at all when the shopper asked the
/// system for less movement.
@MainActor
enum TalqynMotion {
    static var isReduced: Bool { UIAccessibility.isReduceMotionEnabled }

    /// The duration to animate for: zero under reduce motion, so the change
    /// still happens — just without the travel.
    static func duration(_ seconds: TimeInterval) -> TimeInterval {
        isReduced ? 0 : seconds
    }

    /// Whether a transition or a scroll should animate at all.
    static func animates(_ animated: Bool = true) -> Bool {
        animated && !isReduced
    }
}

/// A view that dims and shrinks while pressed, like the original's tappable
/// cards and chips.
class TalqynTappableView: UIView {
    var onTap: (() -> Void)?

    private let pressedAlpha: CGFloat = 0.6

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func handleTap() {
        onTap?()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        setPressed(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        setPressed(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        setPressed(false)
    }

    private func setPressed(_ pressed: Bool) {
        UIView.animate(
            withDuration: TalqynMotion.duration(pressed ? 0.08 : 0.2),
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.alpha = pressed ? self.pressedAlpha : 1
            // The shrink is travel, which is what reduce motion asks about;
            // the dim is feedback, and it stays.
            let scale = TalqynMotion.isReduced ? 1 : 0.98
            self.transform = pressed ? CGAffineTransform(scaleX: scale, y: scale) : .identity
        }
    }
}

/// A filled or outlined pill button: "continue", "open results", "add to cart"
/// in the original's design system, without the design system.
final class TalqynPillButton: UIControl {
    enum Style {
        case accent
        case outline
    }

    private let label = UILabel()
    private let theme: TalqynTheme
    private var style: Style

    init(theme: TalqynTheme, style: Style, title: String, height: CGFloat = 40) {
        self.theme = theme
        self.style = style
        super.init(frame: .zero)
        label.text = title
        label.font = theme.fonts.label
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        talqynPin(label, insets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
        talqynHeight(height)
        layer.cornerRadius = height / 2
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var title: String? {
        get { label.text }
        set { label.text = newValue; accessibilityLabel = newValue }
    }

    func setStyle(_ style: Style) {
        self.style = style
        apply()
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : (isEnabled ? 1 : 0.4) }
    }

    private func apply() {
        switch style {
        case .accent:
            backgroundColor = theme.colors.accent
            label.textColor = theme.colors.onAccent
            layer.borderColor = theme.colors.accent.cgColor
        case .outline:
            backgroundColor = theme.colors.surface
            label.textColor = theme.colors.textPrimary
            layer.borderColor = theme.colors.border.cgColor
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        apply()
    }
}

/// The smallest target a finger is expected to hit, per the Human Interface
/// Guidelines.
enum TalqynHitArea {
    static let minimum: CGFloat = 44

    /// Whether `point` falls inside `bounds` grown to the minimum target,
    /// evenly on both sides — the drawn control stays as designed.
    static func contains(_ point: CGPoint, in bounds: CGRect) -> Bool {
        let dx = max(0, (minimum - bounds.width) / 2)
        let dy = max(0, (minimum - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

/// A button drawn at its design size that takes taps across at least 44 by 44
/// points: the thumbs under an answer are 32 high, a finger is not.
final class TalqynHitAreaButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isHidden, isUserInteractionEnabled, alpha > 0.01 else { return false }
        return TalqynHitArea.contains(point, in: bounds)
    }
}

/// A hairline separator in the theme's border color.
final class TalqynDividerView: UIView {
    init(theme: TalqynTheme, thickness: CGFloat = 0.5) {
        super.init(frame: .zero)
        backgroundColor = theme.colors.border
        talqynHeight(thickness)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
#endif
