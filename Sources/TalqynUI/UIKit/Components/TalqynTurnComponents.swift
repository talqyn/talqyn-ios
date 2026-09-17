#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import UIKit

/// The shopper's message, right-aligned in an accent bubble with a square
/// bottom-trailing corner. A long press copies it, or puts it back into the
/// composer to be asked differently.
final class TalqynUserBubbleView: UIView, UIContextMenuInteractionDelegate {
    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let bubble = UIView()
    private let label = UILabel()
    private var onEdit: ((String) -> Void)?

    init(theme: TalqynTheme, strings: TalqynUIStrings) {
        self.theme = theme
        self.strings = strings
        super.init(frame: .zero)
        bubble.backgroundColor = theme.colors.bubble
        bubble.talqynRound(
            theme.metrics.bubbleRadius,
            corners: [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner]
        )
        label.font = theme.fonts.body
        label.adjustsFontForContentSizeCategory = true
        label.textColor = theme.colors.onBubble
        label.numberOfLines = 0

        addSubview(bubble)
        bubble.talqynPin(label, insets: UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        bubble.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.78),
        ])
        bubble.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// - Parameter onEdit: Puts the text back into the composer; `nil` offers
    ///   copying only.
    func configure(text: String, onEdit: ((String) -> Void)?) {
        label.text = text
        self.onEdit = onEdit
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let text = label.text ?? ""
        guard !text.isEmpty else { return nil }
        let strings = self.strings
        let icons = theme.icons
        let onEdit = self.onEdit
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var actions = [
                UIAction(title: strings.copyQuestion, image: icons.copyAnswer) { _ in
                    UIPasteboard.general.string = text
                },
            ]
            if let onEdit {
                actions.append(UIAction(title: strings.editQuestion, image: icons.editQuestion) { _ in
                    onEdit(text)
                })
            }
            return UIMenu(children: actions)
        }
    }

    /// The bubble lifts, not the full-width row it sits in.
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: bubble.bounds, cornerRadius: theme.metrics.bubbleRadius)
        return UITargetedPreview(view: bubble, parameters: parameters)
    }
}

/// A spinner and what the consultant is doing.
final class TalqynStatusLineView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let strings: TalqynUIStrings

    init(theme: TalqynTheme, strings: TalqynUIStrings) {
        self.strings = strings
        super.init(frame: .zero)
        spinner.color = theme.colors.textSecondary
        spinner.hidesWhenStopped = true
        label.font = theme.fonts.callout
        label.adjustsFontForContentSizeCategory = true
        label.textColor = theme.colors.textSecondary

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        spinner.talqynSize(16)
        talqynPin(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHidden: Bool {
        didSet { isHidden ? spinner.stopAnimating() : spinner.startAnimating() }
    }

    func configure(stage: TalqynConsultantStage) {
        switch stage {
        case .searching: label.text = strings.searching
        case .composing: label.text = strings.composing
        default: label.text = strings.thinking
        }
    }
}

/// Three dots that pulse in turn while text is arriving.
final class TalqynTypingIndicatorView: UIView {
    private let dotSize: CGFloat = 6
    private let idleAlpha: CGFloat = 0.25
    private var dots: [UIView] = []
    private var isAnimating = false

    init(theme: TalqynTheme) {
        super.init(frame: .zero)
        dots = (0..<3).map { _ in
            let dot = UIView()
            dot.backgroundColor = theme.colors.textTertiary
            dot.layer.cornerRadius = dotSize / 2
            dot.alpha = idleAlpha
            dot.talqynSize(dotSize)
            return dot
        }
        let stack = UIStackView(arrangedSubviews: dots)
        stack.axis = .horizontal
        stack.spacing = 5
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        talqynHeight(14)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setActive(_ active: Bool) {
        talqynSetHidden(!active)
        active ? startAnimating() : stopAnimating()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, isAnimating else { return }
        isAnimating = false
        startAnimating()
    }

    private func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        // The dots are the only thing on screen saying the answer is coming,
        // so under reduce motion they stay lit rather than stop existing.
        guard !TalqynMotion.isReduced else {
            dots.forEach { $0.alpha = 1 }
            return
        }
        for (index, dot) in dots.enumerated() {
            UIView.animate(
                withDuration: 0.45,
                delay: Double(index) * 0.15,
                options: [.repeat, .autoreverse, .curveEaseInOut, .allowUserInteraction],
                animations: { dot.alpha = 1 }
            )
        }
    }

    private func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        for dot in dots {
            dot.layer.removeAllAnimations()
            dot.alpha = idleAlpha
        }
    }
}

/// A notice under a turn: stopped, failed, or degraded — with a retry when
/// the turn is the latest one.
final class TalqynNoticeView: UIView {
    enum Tone {
        case warning, error, neutral
    }

    private let theme: TalqynTheme
    private let dot = UIView()
    private let textLabel = UILabel()
    private let retryButton = TalqynHitAreaButton(type: .system)
    private var onRetry: (() -> Void)?

    init(theme: TalqynTheme, strings: TalqynUIStrings) {
        self.theme = theme
        super.init(frame: .zero)
        backgroundColor = theme.colors.surfaceSecondary
        talqynRound(theme.cornerRadius)
        // The retry's taps reach past its label, and the notice must not clip
        // them away.
        clipsToBounds = false

        dot.layer.cornerRadius = 3
        dot.talqynSize(6)
        textLabel.font = theme.fonts.footnote
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.textColor = theme.colors.textSecondary
        textLabel.numberOfLines = 0
        retryButton.setTitle(strings.retry, for: .normal)
        retryButton.setTitleColor(theme.colors.accent, for: .normal)
        retryButton.titleLabel?.font = theme.fonts.label
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.contentHorizontalAlignment = .leading
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let dotWrapper = UIView()
        dotWrapper.addSubview(dot)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.topAnchor.constraint(equalTo: dotWrapper.topAnchor, constant: 6),
            dot.leadingAnchor.constraint(equalTo: dotWrapper.leadingAnchor),
            dot.trailingAnchor.constraint(equalTo: dotWrapper.trailingAnchor),
            dot.bottomAnchor.constraint(lessThanOrEqualTo: dotWrapper.bottomAnchor),
        ])
        let dotRow = UIStackView(arrangedSubviews: [dotWrapper, textLabel])
        dotRow.axis = .horizontal
        dotRow.spacing = 8
        dotRow.alignment = .top

        let stack = UIStackView.talqynVertical([dotRow, retryButton], spacing: 8)
        talqynPin(stack, insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(tone: Tone, text: String, showsRetry: Bool, onRetry: @escaping () -> Void) {
        dot.backgroundColor = tint(tone)
        textLabel.text = text
        retryButton.talqynSetHidden(!showsRetry)
        self.onRetry = onRetry
    }

    private func tint(_ tone: Tone) -> UIColor {
        switch tone {
        case .warning: return theme.colors.warning
        case .error: return theme.colors.error
        case .neutral: return theme.colors.textSecondary
        }
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}

/// "This looks like a search" and a button to open the results.
final class TalqynRedirectNoticeView: UIView {
    private let openButton: TalqynPillButton
    private var onOpen: (() -> Void)?

    init(theme: TalqynTheme, strings: TalqynUIStrings) {
        openButton = TalqynPillButton(theme: theme, style: .accent, title: strings.openSearch)
        super.init(frame: .zero)
        backgroundColor = theme.colors.surfaceSecondary
        talqynRound(theme.cornerRadius)

        let label = UILabel()
        label.font = theme.fonts.footnote
        label.adjustsFontForContentSizeCategory = true
        label.textColor = theme.colors.textSecondary
        label.numberOfLines = 0
        label.text = strings.redirectNotice
        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)

        let stack = UIStackView.talqynVertical([label, openButton], spacing: 10)
        stack.alignment = .leading
        talqynPin(stack, insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
    }

    @objc private func openTapped() {
        onOpen?()
    }
}

/// Under a settled turn: was it helpful, why not, and a button that copies
/// the answer.
///
/// The verdict is a toggle — tapping the chosen thumb again takes it back.
/// A thumb down opens the reasons as chips: picking one is the cheapest way
/// for a shopper to say what to fix, and each pick is saved as it is made.
/// Copying swaps the icon for a checkmark for a moment and says so to
/// VoiceOver.
final class TalqynAnswerToolbarView: UIView {
    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let helpfulButton = TalqynHitAreaButton(type: .system)
    private let notHelpfulButton = TalqynHitAreaButton(type: .system)
    private let copyButton = TalqynHitAreaButton(type: .system)
    private let divider = UIView()
    private let reasonsTitleLabel = UILabel()
    private let reasonsChips = TalqynChipsFlowView()
    private lazy var reasonsGroup = UIStackView.talqynVertical([reasonsTitleLabel, reasonsChips], spacing: 8)
    private let symbolSize: CGFloat = 15

    private var rating: TalqynAnswerRating?
    private var offeredReasons: [TalqynFeedbackReason] = []
    private var selectedReasons: [TalqynFeedbackReason] = []
    private var copyText: String?
    private var onRate: ((TalqynAnswerRating?, [TalqynFeedbackReason]) -> Void)?
    private var copiedReset: DispatchWorkItem?

    init(theme: TalqynTheme, strings: TalqynUIStrings) {
        self.theme = theme
        self.strings = strings
        super.init(frame: .zero)

        for button in [helpfulButton, notHelpfulButton, copyButton] {
            button.talqynSize(CGSize(width: 36, height: 32))
            button.accessibilityTraits = .button
        }
        helpfulButton.accessibilityLabel = strings.rateHelpful
        notHelpfulButton.accessibilityLabel = strings.rateNotHelpful
        helpfulButton.addTarget(self, action: #selector(helpfulTapped), for: .touchUpInside)
        notHelpfulButton.addTarget(self, action: #selector(notHelpfulTapped), for: .touchUpInside)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)

        divider.backgroundColor = theme.colors.border
        divider.talqynSize(CGSize(width: 1, height: 16))
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [helpfulButton, notHelpfulButton, divider, copyButton, spacer])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 2
        row.setCustomSpacing(6, after: notHelpfulButton)
        row.setCustomSpacing(6, after: divider)

        reasonsTitleLabel.font = theme.fonts.captionBold
        reasonsTitleLabel.adjustsFontForContentSizeCategory = true
        reasonsTitleLabel.textColor = theme.colors.textSecondary
        reasonsTitleLabel.numberOfLines = 0
        reasonsTitleLabel.text = strings.feedbackReasonsTitle
        reasonsGroup.isHidden = true

        talqynPin(UIStackView.talqynVertical([row, reasonsGroup], spacing: 6))
        applyRating()
        resetCopyButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// - Parameters:
    ///   - offeredReasons: The reasons to offer under a thumb down; empty
    ///     offers none.
    ///   - copyText: The answer as plain text; `nil` hides the copy button.
    ///   - availableWidth: The width the reasons wrap in.
    func configure(
        rating: TalqynAnswerRating?,
        offeredReasons: [TalqynFeedbackReason],
        selectedReasons: [TalqynFeedbackReason],
        copyText: String?,
        availableWidth: CGFloat,
        onRate: @escaping (TalqynAnswerRating?, [TalqynFeedbackReason]) -> Void
    ) {
        self.rating = rating
        self.offeredReasons = offeredReasons
        self.selectedReasons = selectedReasons
        self.onRate = onRate
        reasonsChips.preferredLayoutWidth = availableWidth
        copyButton.talqynSetHidden(copyText == nil)
        divider.talqynSetHidden(copyText == nil)
        // A reconfigure — the rating landed, the text size changed — must
        // not cut short the checkmark of a copy that just happened.
        if copyText != self.copyText {
            self.copyText = copyText
            resetCopyButton()
        }
        applyRating()
        applyReasons()
    }

    /// Back to the idle state, for a reused cell.
    func reset() {
        onRate = nil
        copyText = nil
        rating = nil
        offeredReasons = []
        selectedReasons = []
        applyRating()
        applyReasons()
        resetCopyButton()
    }

    private func applyRating() {
        let helpful = rating == .helpful
        let notHelpful = rating == .notHelpful
        apply(helpfulButton, icon: helpful ? theme.icons.rateHelpfulOn : theme.icons.rateHelpful, isOn: helpful)
        apply(
            notHelpfulButton,
            icon: notHelpful ? theme.icons.rateNotHelpfulOn : theme.icons.rateNotHelpful,
            isOn: notHelpful
        )
    }

    private func applyReasons() {
        let reasons = offeredReasons.compactMap { reason in
            strings.feedbackReasonText(for: reason).map { (reason, $0) }
        }
        let isVisible = rating == .notHelpful && !reasons.isEmpty
        reasonsGroup.talqynSetHidden(!isVisible)
        guard isVisible else {
            reasonsChips.setChips([])
            return
        }
        reasonsChips.setChips(reasons.map { reason, title in
            let chip = TalqynChipView(theme: theme, title: title, isSelected: selectedReasons.contains(reason))
            chip.onTap = { [weak self] in self?.toggleReason(reason) }
            return chip
        })
    }

    private func apply(_ button: UIButton, icon: UIImage?, isOn: Bool) {
        button.setImage(icon?.talqynSized(symbolSize), for: .normal)
        button.tintColor = isOn ? theme.colors.accent : theme.colors.textTertiary
        button.accessibilityTraits = isOn ? [.button, .selected] : .button
    }

    private func resetCopyButton() {
        copiedReset?.cancel()
        copiedReset = nil
        copyButton.setImage(theme.icons.copyAnswer?.talqynSized(symbolSize), for: .normal)
        copyButton.tintColor = theme.colors.textTertiary
        copyButton.accessibilityLabel = strings.copyAnswer
    }

    @objc private func helpfulTapped() { toggle(.helpful) }
    @objc private func notHelpfulTapped() { toggle(.notHelpful) }

    private func toggle(_ value: TalqynAnswerRating) {
        TalqynHaptics.tap(theme)
        rating = rating == value ? nil : value
        selectedReasons = []
        applyRating()
        applyReasons()
        onRate?(rating, [])
    }

    private func toggleReason(_ reason: TalqynFeedbackReason) {
        if let index = selectedReasons.firstIndex(of: reason) {
            selectedReasons.remove(at: index)
        } else {
            selectedReasons.append(reason)
        }
        applyReasons()
        onRate?(.notHelpful, selectedReasons)
    }

    @objc private func copyTapped() {
        guard let copyText, !copyText.isEmpty else { return }
        UIPasteboard.general.string = copyText
        TalqynHaptics.tap(theme)
        copyButton.setImage(theme.icons.checkmark?.talqynSized(symbolSize), for: .normal)
        copyButton.tintColor = theme.colors.accent
        copyButton.accessibilityLabel = strings.copied
        UIAccessibility.post(notification: .announcement, argument: strings.copied)

        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.resetCopyButton() }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
    }
}

/// A proposed action: apply filters, open a comparison.
final class TalqynActionChipView: TalqynTappableView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()

    init(theme: TalqynTheme) {
        super.init(frame: .zero)
        backgroundColor = theme.colors.surfaceSecondary
        talqynRound(theme.cornerRadius)
        isAccessibilityElement = true
        accessibilityTraits = .button

        iconView.tintColor = theme.colors.accent
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        iconView.talqynSize(16)
        titleLabel.font = theme.fonts.label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = theme.colors.accent
        summaryLabel.font = theme.fonts.caption
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.textColor = theme.colors.textSecondary
        summaryLabel.numberOfLines = 2

        let textStack = UIStackView.talqynVertical([titleLabel, summaryLabel], spacing: 2)
        let row = UIStackView(arrangedSubviews: [iconView, textStack])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        talqynPin(row, insets: UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(icon: UIImage?, title: String, summary: String, onTap: @escaping () -> Void) {
        iconView.image = icon
        iconView.talqynSetHidden(icon == nil)
        titleLabel.text = title
        summaryLabel.text = summary
        summaryLabel.talqynSetHidden(summary.isEmpty)
        accessibilityLabel = summary.isEmpty ? title : "\(title), \(summary)"
        self.onTap = onTap
    }
}

extension TalqynActionFilters {
    /// The filters in a line, in the screen's copy: the price bound, "with a
    /// discount", the values — `from 100 000 ₸ · with a discount · Apple`.
    ///
    /// The bounds are filled by replacement, not `String(format:)`: the copy
    /// is the app's to change, and a bare `%` in it must stay a percent sign.
    func summary(strings: TalqynUIStrings, price: TalqynPriceFormatter) -> String {
        var parts: [String] = []
        if let priceMin, let priceMax {
            parts.append("\(price.format(priceMin)) – \(price.format(priceMax))")
        } else if let priceMax {
            parts.append(strings.filled(strings.filterUpTo, with: price.format(priceMax)))
        } else if let priceMin {
            parts.append(strings.filled(strings.filterFrom, with: price.format(priceMin)))
        }
        if hasDiscount { parts.append(strings.filterDiscount) }
        // The structured form first; the flat legacy form for turns that
        // carry only it.
        let values = filters.isEmpty ? Array(attributes.values) : filters.values.flatMap { $0 }
        parts.append(contentsOf: values.sorted())
        return parts.joined(separator: " · ")
    }
}

extension TalqynComparisonTable {
    /// A table needs two columns and a row to be worth a screen.
    var isRenderable: Bool { talqynIDs.count >= 2 && !rows.isEmpty }
}
#endif
