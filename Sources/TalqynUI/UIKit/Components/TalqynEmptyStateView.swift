#if os(iOS)
import TalqynConsultantCore
import UIKit

/// The screen before the first question: a title, a line about what the
/// consultant does, and example questions to tap.
final class TalqynEmptyStateView: UIView {
    /// Who built the consultant. Not copy: the mark reads the same in every
    /// locale and in every storefront, and an app that does not want it turns
    /// it off rather than rewrites it.
    static let poweredBy = "Powered by Talqyn"

    private let chipsView = TalqynChipsFlowView()

    init(
        theme: TalqynTheme,
        strings: TalqynUIStrings,
        showsPoweredBy: Bool,
        onExampleTap: @escaping (String) -> Void
    ) {
        super.init(frame: .zero)

        let iconView = UIImageView(image: theme.icons.emptyState?.talqynSized(34))
        iconView.tintColor = theme.colors.accent
        iconView.contentMode = .scaleAspectFit
        iconView.talqynSize(40)
        iconView.talqynSetHidden(theme.icons.emptyState == nil)

        let titleLabel = UILabel()
        titleLabel.font = theme.fonts.title
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.text = strings.title
        titleLabel.textAlignment = .center

        let subtitleLabel = UILabel()
        subtitleLabel.font = theme.fonts.callout
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = theme.colors.textSecondary
        subtitleLabel.text = strings.introSubtitle
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        chipsView.centersRows = true
        chipsView.setChips(strings.exampleQuestions.map { example in
            let chip = TalqynChipView(theme: theme, title: example)
            chip.onTap = { onExampleTap(example) }
            return chip
        })
        // An app with no examples of its own gets no gap where they were: the
        // flow view is empty, not zero-height inside the stack's spacing.
        chipsView.isHidden = strings.exampleQuestions.isEmpty

        // The mark is shown once, where the screen introduces itself, and
        // nowhere else: the shopper reads it before the first question and is
        // not reminded of it under every answer.
        let poweredByLabel = UILabel()
        poweredByLabel.font = theme.fonts.micro
        poweredByLabel.adjustsFontForContentSizeCategory = true
        poweredByLabel.textColor = theme.colors.textTertiary
        poweredByLabel.textAlignment = .center
        poweredByLabel.text = Self.poweredBy
        poweredByLabel.isHidden = !showsPoweredBy

        let stack = UIStackView.talqynVertical(
            [iconView, titleLabel, subtitleLabel, chipsView, poweredByLabel], spacing: 16
        )
        stack.alignment = .center
        stack.setCustomSpacing(24, after: subtitleLabel)
        stack.setCustomSpacing(28, after: chipsView)

        let topSpacer = UIView()
        let bottomSpacer = UIView()
        [topSpacer, stack, bottomSpacer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        let margin = theme.metrics.horizontalMargin
        NSLayoutConstraint.activate([
            topSpacer.topAnchor.constraint(equalTo: topAnchor),
            topSpacer.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSpacer.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topSpacer.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSpacer.topAnchor.constraint(equalTo: stack.bottomAnchor),
            bottomSpacer.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomSpacer.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSpacer.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomSpacer.heightAnchor.constraint(equalTo: topSpacer.heightAnchor, multiplier: 2),
            subtitleLabel.widthAnchor.constraint(equalTo: widthAnchor, constant: -margin * 4),
            chipsView.widthAnchor.constraint(equalTo: widthAnchor, constant: -margin * 2),
        ])
        chipsMargin = margin
    }

    private var chipsMargin: CGFloat = 16

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        chipsView.preferredLayoutWidth = bounds.width - chipsMargin * 2
    }
}

/// The screen's own bar: the way out of the consultant on the left, the title,
/// then history and a new chat.
///
/// The way out depends on how the screen was shown: a back arrow when it was
/// pushed, a cross when it was presented, nothing when it is a root — a tab of
/// its own. History stands in the leading slot when there is no way out to
/// put there.
final class TalqynHeaderView: UIView {
    /// How the screen is left.
    enum LeadingAction: Equatable {
        case back
        case close
    }

    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let titleLabel = UILabel()
    private let leadingButton = TalqynHitAreaButton(type: .system)
    private let historyButton = TalqynHitAreaButton(type: .system)
    private let newChatButton = TalqynHitAreaButton(type: .system)
    private let leadingStack = UIStackView()
    private let trailingStack = UIStackView()
    private var leadingAction: LeadingAction?
    private var onNewChat: (() -> Void)?
    private var onHistory: (() -> Void)?
    private var onLeading: ((LeadingAction) -> Void)?

    init(theme: TalqynTheme, strings: TalqynUIStrings) {
        self.theme = theme
        self.strings = strings
        super.init(frame: .zero)
        backgroundColor = theme.colors.surface

        titleLabel.font = theme.fonts.headline
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.textAlignment = .center
        titleLabel.text = strings.title
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        leadingButton.tintColor = theme.colors.textPrimary
        leadingButton.addTarget(self, action: #selector(leadingTapped), for: .touchUpInside)
        leadingButton.isHidden = true
        historyButton.setImage(theme.icons.history?.talqynSized(18, .medium), for: .normal)
        historyButton.tintColor = theme.colors.textPrimary
        historyButton.accessibilityLabel = strings.historyTitle
        historyButton.addTarget(self, action: #selector(historyTapped), for: .touchUpInside)
        newChatButton.setImage(theme.icons.newChat?.talqynSized(18, .medium), for: .normal)
        newChatButton.tintColor = theme.colors.accent
        newChatButton.accessibilityLabel = strings.newChat
        newChatButton.addTarget(self, action: #selector(newChatTapped), for: .touchUpInside)
        newChatButton.isHidden = true
        for button in [leadingButton, historyButton, newChatButton] {
            button.talqynSize(44)
        }

        for stack in [leadingStack, trailingStack] {
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 0
        }
        leadingStack.addArrangedSubview(leadingButton)
        leadingStack.addArrangedSubview(historyButton)
        trailingStack.addArrangedSubview(newChatButton)

        let content = UIView()
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, leadingStack, trailingStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        let divider = TalqynDividerView(theme: theme, thickness: 0.5)
        addSubview(divider)
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.heightAnchor.constraint(equalToConstant: 56),
            leadingStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            leadingStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            trailingStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            trailingStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingStack.trailingAnchor, constant: 4),
            trailingStack.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        onNewChat: @escaping () -> Void,
        onHistory: @escaping () -> Void,
        onLeading: @escaping (LeadingAction) -> Void
    ) {
        self.onNewChat = onNewChat
        self.onHistory = onHistory
        self.onLeading = onLeading
    }

    /// Shows the way out of the screen, or none. With one, history moves to
    /// the trailing side, next to a new chat.
    func setLeadingAction(_ action: LeadingAction?) {
        guard action != leadingAction || leadingButton.isHidden == (action != nil) else { return }
        leadingAction = action
        switch action {
        case .back:
            leadingButton.setImage(theme.icons.back?.talqynSized(18, .semibold), for: .normal)
            leadingButton.accessibilityLabel = strings.back
        case .close:
            leadingButton.setImage(theme.icons.close?.talqynSized(16, .semibold), for: .normal)
            leadingButton.accessibilityLabel = strings.close
        case nil:
            break
        }
        leadingButton.talqynSetHidden(action == nil)
        historyButton.removeFromSuperview()
        if action == nil {
            leadingStack.addArrangedSubview(historyButton)
        } else {
            trailingStack.insertArrangedSubview(historyButton, at: 0)
        }
    }

    func setNewChatVisible(_ visible: Bool) {
        newChatButton.talqynSetHidden(!visible)
    }

    func setActionsEnabled(_ enabled: Bool) {
        for button in [newChatButton, historyButton] {
            button.isEnabled = enabled
            button.alpha = enabled ? 1 : 0.4
        }
    }

    @objc private func newChatTapped() { onNewChat?() }
    @objc private func historyTapped() { onHistory?() }
    @objc private func leadingTapped() {
        guard let leadingAction else { return }
        onLeading?(leadingAction)
    }
}
#endif
