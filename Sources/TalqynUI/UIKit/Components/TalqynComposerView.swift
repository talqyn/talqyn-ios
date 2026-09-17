#if os(iOS)
import TalqynConsultantCore
import UIKit

/// A text view with a placeholder that reports its text and its height.
final class TalqynPlaceholderTextView: UITextView, UITextViewDelegate {
    let placeholderLabel = UILabel()
    var onTextChange: ((String) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    private var lastHeight: CGFloat = 0
    private var placeholderLeading: NSLayoutConstraint?
    private var placeholderTop: NSLayoutConstraint?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        delegate = self
        placeholderLabel.numberOfLines = 1
        addSubview(placeholderLabel)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        let leading = placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor)
        let top = placeholderLabel.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            leading, top,
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -textContainerInset.right),
        ])
        placeholderLeading = leading
        placeholderTop = top
        alignPlaceholder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The placeholder sits exactly where the first character goes: the
    /// container inset plus the line fragment padding, on both axes.
    override var textContainerInset: UIEdgeInsets {
        didSet { alignPlaceholder() }
    }

    private func alignPlaceholder() {
        placeholderLeading?.constant = textContainerInset.left + textContainer.lineFragmentPadding
        placeholderTop?.constant = textContainerInset.top
    }

    func setText(_ text: String) {
        self.text = text
        textDidChangeNotify()
    }

    func textViewDidChange(_ textView: UITextView) {
        textDidChangeNotify()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportHeightIfNeeded()
    }

    private func textDidChangeNotify() {
        placeholderLabel.isHidden = !text.isEmpty
        onTextChange?(text)
        reportHeightIfNeeded()
    }

    private func reportHeightIfNeeded() {
        let height = ceil(sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height)
        guard bounds.width > 0, height != lastHeight else { return }
        lastHeight = height
        onHeightChange?(height)
    }
}

/// A view whose shadow follows its own size, so it is right on the pass
/// that resizes it and not one pass later.
private final class TalqynShadowedView: UIView {
    /// The shadow as the palette states it, alpha and all. A `CGColor` does
    /// not follow the appearance on its own, so it is resolved here and again
    /// whenever the appearance changes.
    var shadow: UIColor = .clear {
        didSet { applyShadow() }
    }

    /// How much of the palette's shadow this view takes. The pill floats a
    /// little lighter than a card.
    var shadowStrength: CGFloat = 1 {
        didSet { applyShadow() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyShadow()
        }
    }

    private func applyShadow() {
        let resolved = shadow.resolvedColor(with: traitCollection)
        layer.shadowColor = resolved.cgColor
        layer.shadowOpacity = Float(resolved.cgColor.alpha * shadowStrength)
    }
}

/// The input pill: a growing text view, a counter near the limit, and a
/// button that sends — or stops the answer while one is streaming. Under
/// the pill, a line that the consultant can be wrong.
/// The bar the composer floats on.
///
/// The transcript runs the whole height of the screen and passes under the
/// composer, so what is behind the pill is glass rather than a slab of
/// background: the last rows stay visible and go soft as they slide beneath.
/// The top edge fades in over `fade` points, so the blur meets the transcript
/// without a seam across it.
final class TalqynGlassBarView: UIView {
    private let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let gradientMask = CAGradientLayer()
    private let fade: CGFloat = 24

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        gradientMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        gradientMask.startPoint = CGPoint(x: 0.5, y: 0)
        gradientMask.endPoint = CGPoint(x: 0.5, y: 1)
        effectView.layer.mask = gradientMask
        talqynPin(effectView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The mask is a layer, so it would animate its own way through every
        // keyboard and composer height change if left to itself.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientMask.frame = effectView.bounds
        gradientMask.locations = [0, NSNumber(value: Double(min(1, fade / max(1, bounds.height))))]
        CATransaction.commit()
    }
}

final class TalqynComposerView: UIView {
    /// The gap above the pill, inside the composer's own bounds. The
    /// transcript counts on it when it measures its distance to the pill.
    static let topInset: CGFloat = 8

    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let counterThreshold = 100

    private let textView = TalqynPlaceholderTextView()
    private let pillView = TalqynShadowedView()
    private let counterLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private let disclaimerLabel = UILabel()
    private var inputHeight: NSLayoutConstraint?

    private var isStreaming = false
    private var onSend: (() -> Void)?
    private var onStop: (() -> Void)?

    var onHeightChange: (() -> Void)?
    var onTextChange: ((String) -> Void)?

    var text: String { textView.text ?? "" }

    init(theme: TalqynTheme, strings: TalqynUIStrings) {
        self.theme = theme
        self.strings = strings
        super.init(frame: .zero)
        configureUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// One line of the body font with the insets, never under the 44 of the
    /// design; four lines before the text starts to scroll.
    private var minHeight: CGFloat { max(44, ceil(theme.fonts.body.lineHeight) + 24) }
    private var maxHeight: CGFloat { max(100, ceil(theme.fonts.body.lineHeight * 4) + 24) }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            inputHeight?.constant = max(inputHeight?.constant ?? 0, minHeight)
            textView.setNeedsLayout()
        }
    }

    func configure(onSend: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onSend = onSend
        self.onStop = onStop
    }

    func setText(_ text: String) {
        guard textView.text != text else { return }
        textView.setText(text)
        updateSendButton()
    }

    func setStreaming(_ streaming: Bool) {
        isStreaming = streaming
        updateSendButton()
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        textView.resignFirstResponder()
    }

    /// Puts the cursor in the field, at the end of what is there.
    func focus() {
        textView.becomeFirstResponder()
        let end = textView.endOfDocument
        textView.selectedTextRange = textView.textRange(from: end, to: end)
    }

    @objc private func sendOrStopTapped() {
        TalqynHaptics.tap(theme)
        isStreaming ? onStop?() : onSend?()
    }

    private func updateSendButton() {
        let isBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isStreaming {
            sendButton.setImage(theme.icons.stop?.talqynSized(28), for: .normal)
            sendButton.tintColor = theme.colors.error
            sendButton.isEnabled = true
            sendButton.accessibilityLabel = strings.stop
        } else {
            sendButton.setImage(theme.icons.send?.talqynSized(28), for: .normal)
            sendButton.tintColor = isBlank ? theme.colors.textTertiary : theme.colors.accent
            sendButton.isEnabled = !isBlank
            sendButton.accessibilityLabel = strings.send
        }
        updateCounter()
    }

    private func updateCounter() {
        let count = text.count
        let limit = TalqynConversationLimits.maxInputLength
        let isNearLimit = count >= limit - counterThreshold
        counterLabel.talqynSetHidden(!isNearLimit)
        guard isNearLimit else { return }
        counterLabel.text = "\(count)/\(limit)"
        counterLabel.textColor = count >= limit ? theme.colors.error : theme.colors.textTertiary
    }

    private func configureUI() {
        // The bar behind the composer is drawn by the screen, not here: it has
        // to reach past the safe area to the bottom edge, and the composer
        // stops at the keyboard's guide. See `TalqynGlassBarView`.
        backgroundColor = .clear

        textView.font = theme.fonts.body
        textView.textColor = theme.colors.textPrimary
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.placeholderLabel.text = strings.placeholder
        textView.placeholderLabel.font = theme.fonts.body
        textView.placeholderLabel.textColor = theme.colors.textTertiary
        textView.placeholderLabel.adjustsFontForContentSizeCategory = true

        pillView.backgroundColor = theme.colors.surface
        pillView.layer.cornerRadius = theme.metrics.composerRadius
        pillView.layer.cornerCurve = .continuous
        pillView.shadowStrength = 0.67
        pillView.shadow = theme.colors.shadow
        pillView.layer.shadowRadius = 12
        pillView.layer.shadowOffset = CGSize(width: 0, height: 4)

        counterLabel.font = theme.fonts.micro
        counterLabel.textColor = theme.colors.textTertiary
        counterLabel.adjustsFontForContentSizeCategory = true
        counterLabel.isHidden = true
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        sendButton.addTarget(self, action: #selector(sendOrStopTapped), for: .touchUpInside)
        sendButton.talqynSize(44)

        // The answers are a model's: say so where every answer is read from,
        // in the shopper's language, small and out of the way. An app that
        // says it elsewhere blanks the string.
        disclaimerLabel.font = theme.fonts.micro
        disclaimerLabel.textColor = theme.colors.textTertiary
        disclaimerLabel.adjustsFontForContentSizeCategory = true
        disclaimerLabel.textAlignment = .center
        disclaimerLabel.numberOfLines = 0
        disclaimerLabel.text = strings.filled(strings.disclaimer, with: strings.title)
        disclaimerLabel.isHidden = strings.disclaimer.isEmpty

        let inputContainer = UIView()
        inputContainer.talqynPin(textView)
        inputHeight = inputContainer.talqynHeight(minHeight)

        let row = UIStackView(arrangedSubviews: [inputContainer, counterLabel, sendButton])
        row.axis = .horizontal
        row.spacing = 4
        row.alignment = .center

        let column = UIStackView.talqynVertical([pillView, disclaimerLabel], spacing: 6)
        let margin = theme.metrics.horizontalMargin
        talqynPin(column, insets: UIEdgeInsets(top: Self.topInset, left: margin, bottom: 8, right: margin))
        pillView.talqynPin(row, insets: UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 4))

        textView.onHeightChange = { [weak self] height in
            guard let self else { return }
            let clamped = min(max(height, self.minHeight), self.maxHeight)
            self.textView.isScrollEnabled = height > self.maxHeight
            guard self.inputHeight?.constant != clamped else { return }
            self.inputHeight?.constant = clamped
            DispatchQueue.main.async { [weak self] in self?.onHeightChange?() }
        }
        textView.onTextChange = { [weak self] text in
            guard let self else { return }
            if text.count > TalqynConversationLimits.maxInputLength {
                self.textView.setText(String(text.prefix(TalqynConversationLimits.maxInputLength)))
                return
            }
            self.updateSendButton()
            self.onTextChange?(text)
        }
        updateSendButton()
    }
}
#endif
