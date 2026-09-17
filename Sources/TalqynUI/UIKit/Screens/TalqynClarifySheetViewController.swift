#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import UIKit

/// The clarifying questions as a sheet: the first time a turn asks, the
/// questions come up over the transcript; dismissed, they stay as a card in it.
final class TalqynClarifySheetViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let clarify: TalqynClarify
    private var draft: TalqynClarifyDraft
    private let onDraftChange: (TalqynClarifyDraft) -> Void
    private let onSubmit: (String) -> Void
    var onUserDismiss: (() -> Void)?

    private let titleLabel = UILabel()
    private let questionsStack = UIStackView.talqynVertical(spacing: 20)
    private let customField = UITextField()
    private let submitButton: TalqynPillButton
    private let skipButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let actionsContainer = UIView()
    private var lastDetentHeight: CGFloat = 0
    private let contentTopInset: CGFloat = 24

    init(
        theme: TalqynTheme,
        strings: TalqynUIStrings,
        clarify: TalqynClarify,
        draft: TalqynClarifyDraft,
        onDraftChange: @escaping (TalqynClarifyDraft) -> Void,
        onSubmit: @escaping (String) -> Void
    ) {
        self.theme = theme
        self.strings = strings
        self.clarify = clarify
        self.draft = draft
        self.onDraftChange = onDraftChange
        self.onSubmit = onSubmit
        submitButton = TalqynPillButton(theme: theme, style: .accent, title: strings.clarifySubmit, height: 52)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        presentationController?.delegate = self
        sheetPresentationController?.detents = [.medium(), .large()]
        sheetPresentationController?.prefersGrabberVisible = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        titleLabel.talqynSetHidden(clarify.message.isEmpty)
        titleLabel.text = clarify.message
        customField.text = draft.custom
        rebuildQuestions()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateContentDetent()
    }

    /// Sizes the sheet to its content when that is less than the medium
    /// detent: two questions do not need half a screen.
    private func updateContentDetent() {
        guard #available(iOS 16, *) else { return }
        let height = contentTopInset + scrollView.contentSize.height + actionsContainer.bounds.height + view.safeAreaInsets.bottom
        guard height > 0, abs(height - lastDetentHeight) > 1 else { return }
        lastDetentHeight = height
        sheetPresentationController?.animateChanges {
            sheetPresentationController?.detents = [
                .custom(identifier: .init("talqyn.clarify")) { context in min(height, context.maximumDetentValue) },
                .large(),
            ]
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onUserDismiss?()
    }

    private func rebuildQuestions() {
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
        label.textColor = theme.colors.textSecondary
        label.numberOfLines = 0
        label.text = question.label

        let chipsView = TalqynChipsFlowView()
        chipsView.preferredLayoutWidth = max(0, view.bounds.width - 40)
        chipsView.setChips(question.options.map { option in
            let chip = TalqynChipView(theme: theme, title: option, isSelected: draft.isSelected(option, in: question))
            chip.onTap = { [weak self] in self?.toggle(option, in: question) }
            return chip
        })
        return UIStackView.talqynVertical([label, chipsView], spacing: 10)
    }

    private func toggle(_ option: String, in question: TalqynClarify.Question) {
        draft.toggle(option, in: question)
        onDraftChange(draft)
        rebuildQuestions()
    }

    @objc private func customChanged() {
        let text = String((customField.text ?? "").prefix(TalqynConversationLimits.maxClarifyCustomLength))
        if customField.text != text { customField.text = text }
        draft.custom = text
        onDraftChange(draft)
        submitButton.isEnabled = !draft.answer(for: clarify.questions).isEmpty
    }

    @objc private func skipTapped() {
        onSubmit(strings.clarifySkipValue)
    }

    @objc private func submitTapped() {
        onSubmit(draft.answer(for: clarify.questions))
    }

    private func configureUI() {
        overrideUserInterfaceStyle = theme.appearance.interfaceStyle
        view.backgroundColor = theme.colors.surface

        titleLabel.font = theme.fonts.title
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.numberOfLines = 0

        customField.font = theme.fonts.callout
        customField.adjustsFontForContentSizeCategory = true
        customField.textColor = theme.colors.textPrimary
        customField.attributedPlaceholder = NSAttributedString(
            string: strings.clarifyCustomPlaceholder,
            attributes: [.foregroundColor: theme.colors.textTertiary, .font: theme.fonts.callout]
        )
        customField.backgroundColor = theme.colors.surfaceSecondary
        customField.layer.cornerRadius = theme.cornerRadius
        customField.layer.cornerCurve = .continuous
        customField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        customField.leftViewMode = .always
        customField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        customField.rightViewMode = .always
        customField.returnKeyType = .done
        customField.talqynHeight(52)
        customField.addTarget(self, action: #selector(customChanged), for: .editingChanged)
        customField.addTarget(customField, action: #selector(resignFirstResponder), for: .editingDidEndOnExit)

        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        submitButton.isEnabled = false
        skipButton.setTitle(strings.clarifySkip, for: .normal)
        skipButton.setTitleColor(theme.colors.textSecondary, for: .normal)
        skipButton.titleLabel?.font = theme.fonts.label
        skipButton.titleLabel?.adjustsFontForContentSizeCategory = true
        skipButton.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)
        skipButton.talqynHeight(44)

        scrollView.showsVerticalScrollIndicator = false
        scrollView.keyboardDismissMode = .interactive
        actionsContainer.backgroundColor = theme.colors.surface

        let content = UIStackView.talqynVertical([titleLabel, questionsStack, customField], spacing: 24)
        content.setCustomSpacing(28, after: questionsStack)
        let actions = UIStackView.talqynVertical([submitButton, skipButton], spacing: 4)

        view.addSubview(scrollView)
        view.addSubview(actionsContainer)
        actionsContainer.talqynPin(actions, insets: UIEdgeInsets(top: 12, left: 20, bottom: 8, right: 20))
        let divider = TalqynDividerView(theme: theme, thickness: 0.5)
        actionsContainer.addSubview(divider)
        scrollView.addSubview(content)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        actionsContainer.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            actionsContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionsContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionsContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            divider.topAnchor.constraint(equalTo: actionsContainer.topAnchor),
            divider.leadingAnchor.constraint(equalTo: actionsContainer.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: actionsContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: contentTopInset),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: actionsContainer.topAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            scrollView.contentLayoutGuide.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 20),
            scrollView.contentLayoutGuide.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: 24),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
        ])
    }
}
#endif
