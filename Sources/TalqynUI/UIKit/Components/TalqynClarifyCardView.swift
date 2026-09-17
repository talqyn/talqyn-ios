#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import UIKit

/// The clarifying questions as chips, a free-text field, skip and submit —
/// inline in the transcript.
final class TalqynClarifyCardView: UIView {
    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let messageLabel = UILabel()
    private let questionsStack = UIStackView.talqynVertical(spacing: 12)
    private let customField = UITextField()
    private let skipButton = TalqynHitAreaButton(type: .system)
    private let submitButton: TalqynPillButton
    private let contentInset: CGFloat = 12

    private var clarify: TalqynClarify?
    private var draft = TalqynClarifyDraft()
    private var chipsWidth: CGFloat = 0
    private var onDraftChange: ((TalqynClarifyDraft) -> Void)?
    private var onSubmit: ((String) -> Void)?

    init(theme: TalqynTheme, strings: TalqynUIStrings) {
        self.theme = theme
        self.strings = strings
        submitButton = TalqynPillButton(theme: theme, style: .accent, title: strings.clarifySubmit)
        super.init(frame: .zero)
        configureUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The field's outline is a `CGColor`, which does not follow the
    /// appearance on its own: it is resolved again when the appearance changes.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyFieldBorder()
        }
    }

    private func applyFieldBorder() {
        customField.layer.borderColor = theme.colors.border.resolvedColor(with: traitCollection).cgColor
    }

    func configure(
        clarify: TalqynClarify,
        draft: TalqynClarifyDraft,
        isInteractive: Bool,
        availableWidth: CGFloat,
        onDraftChange: @escaping (TalqynClarifyDraft) -> Void,
        onSubmit: @escaping (String) -> Void
    ) {
        self.clarify = clarify
        self.draft = draft
        chipsWidth = availableWidth - contentInset * 2
        self.onDraftChange = onDraftChange
        self.onSubmit = onSubmit

        messageLabel.talqynSetHidden(clarify.message.isEmpty)
        messageLabel.text = clarify.message
        if customField.text != draft.custom { customField.text = draft.custom }
        isUserInteractionEnabled = isInteractive
        alpha = isInteractive ? 1 : 0.5
        rebuildQuestions()
    }

    private func rebuildQuestions() {
        guard let clarify else { return }
        questionsStack.talqynRemoveAllArranged()
        for question in clarify.questions {
            questionsStack.addArrangedSubview(makeQuestionSection(question))
        }
        submitButton.isEnabled = !draft.answer(for: clarify.questions).isEmpty
    }

    private func makeQuestionSection(_ question: TalqynClarify.Question) -> UIView {
        let label = UILabel()
        label.font = theme.fonts.label
        label.adjustsFontForContentSizeCategory = true
        label.textColor = theme.colors.textPrimary
        label.numberOfLines = 0
        label.text = question.label

        let chipsView = TalqynChipsFlowView()
        chipsView.preferredLayoutWidth = chipsWidth
        chipsView.setChips(question.options.map { option in
            let chip = TalqynChipView(theme: theme, title: option, isSelected: draft.isSelected(option, in: question))
            chip.onTap = { [weak self] in self?.toggle(option, in: question) }
            return chip
        })
        return UIStackView.talqynVertical([label, chipsView], spacing: 8)
    }

    private func toggle(_ option: String, in question: TalqynClarify.Question) {
        draft.toggle(option, in: question)
        onDraftChange?(draft)
        rebuildQuestions()
    }

    @objc private func customChanged() {
        let text = String((customField.text ?? "").prefix(TalqynConversationLimits.maxClarifyCustomLength))
        if customField.text != text { customField.text = text }
        draft.custom = text
        onDraftChange?(draft)
        if let clarify { submitButton.isEnabled = !draft.answer(for: clarify.questions).isEmpty }
    }

    @objc private func skipTapped() {
        onSubmit?(strings.clarifySkipValue)
    }

    @objc private func submitTapped() {
        guard let clarify else { return }
        onSubmit?(draft.answer(for: clarify.questions))
    }

    private func configureUI() {
        backgroundColor = theme.colors.surfaceSecondary
        talqynRound(theme.cornerRadius)

        messageLabel.font = theme.fonts.callout
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = theme.colors.textPrimary
        messageLabel.numberOfLines = 0

        customField.font = theme.fonts.callout
        customField.adjustsFontForContentSizeCategory = true
        customField.textColor = theme.colors.textPrimary
        customField.attributedPlaceholder = NSAttributedString(
            string: strings.clarifyCustomPlaceholder,
            attributes: [.foregroundColor: theme.colors.textTertiary, .font: theme.fonts.callout]
        )
        customField.backgroundColor = theme.colors.surface
        // A field inside the card rounds a little less than the card around it.
        customField.layer.cornerRadius = max(4, theme.cornerRadius - 2)
        customField.layer.cornerCurve = .continuous
        customField.layer.borderWidth = 1
        applyFieldBorder()
        customField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        customField.leftViewMode = .always
        customField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        customField.rightViewMode = .always
        customField.returnKeyType = .done
        customField.talqynHeight(44)
        customField.addTarget(self, action: #selector(customChanged), for: .editingChanged)
        customField.addTarget(customField, action: #selector(resignFirstResponder), for: .editingDidEndOnExit)

        skipButton.setTitle(strings.clarifySkip, for: .normal)
        skipButton.setTitleColor(theme.colors.textSecondary, for: .normal)
        skipButton.titleLabel?.font = theme.fonts.label
        skipButton.titleLabel?.adjustsFontForContentSizeCategory = true
        skipButton.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        submitButton.isEnabled = false

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        let bottomRow = UIStackView(arrangedSubviews: [skipButton, spacer, submitButton])
        bottomRow.axis = .horizontal
        bottomRow.alignment = .center

        let content = UIStackView.talqynVertical([messageLabel, questionsStack, customField, bottomRow], spacing: 12)
        talqynPin(content, insets: UIEdgeInsets(top: contentInset, left: contentInset, bottom: contentInset, right: contentInset))
    }
}

/// What the shopper answered to a clarification.
final class TalqynClarifyAnsweredView: UIView {
    private let answerLabel = UILabel()

    init(theme: TalqynTheme, strings: TalqynUIStrings) {
        super.init(frame: .zero)
        backgroundColor = theme.colors.surfaceSecondary
        talqynRound(theme.cornerRadius)
        let title = UILabel()
        title.font = theme.fonts.captionBold
        title.adjustsFontForContentSizeCategory = true
        title.textColor = theme.colors.textTertiary
        title.text = strings.clarifyAnsweredLabel
        answerLabel.font = theme.fonts.callout
        answerLabel.adjustsFontForContentSizeCategory = true
        answerLabel.textColor = theme.colors.textPrimary
        answerLabel.numberOfLines = 0
        let stack = UIStackView.talqynVertical([title, answerLabel], spacing: 4)
        talqynPin(stack, insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(answer: String) {
        answerLabel.text = answer
    }
}
#endif
