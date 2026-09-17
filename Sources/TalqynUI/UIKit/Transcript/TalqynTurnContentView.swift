#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import UIKit

/// One assistant turn: status, the answer with inline product cards, the
/// products carousel, proposed actions, the clarify card, notices, and the
/// rate-and-copy toolbar once the turn has settled.
///
/// Updated in place while streaming: text views keep their identity and only
/// the text changes, so the shopper's selection and the scroll position hold.
final class TalqynTurnContentView: UIView, UITextViewDelegate {
    /// The margin down both sides of a turn. The theme's, kept here so the
    /// cell that lays chips out reaches the same number.
    static func horizontalMargin(_ theme: TalqynTheme) -> CGFloat { theme.metrics.horizontalMargin }

    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let price: TalqynPriceFormatter
    private let loader: TalqynImageLoading

    private let statusLineView: TalqynStatusLineView
    private let blocksStack = UIStackView.talqynVertical(spacing: 12)
    private let typingIndicatorView: TalqynTypingIndicatorView
    private let productListView: TalqynProductListView
    private let actionsStack = UIStackView.talqynVertical(spacing: 12)
    private let clarifyCardView: TalqynClarifyCardView
    private let clarifyAnsweredView: TalqynClarifyAnsweredView
    private let redirectNoticeView: TalqynRedirectNoticeView
    private let noticeView: TalqynNoticeView
    private let toolbarView: TalqynAnswerToolbarView

    private lazy var answerGroup = UIStackView.talqynVertical(
        [statusLineView, blocksStack, typingIndicatorView], spacing: 12,
        horizontalMargin: Self.horizontalMargin(theme)
    )
    private lazy var followUpGroup = UIStackView.talqynVertical(
        [actionsStack, clarifyCardView, clarifyAnsweredView, redirectNoticeView, noticeView, toolbarView],
        spacing: 12, horizontalMargin: Self.horizontalMargin(theme)
    )

    private var lastTextByID: [Int: String] = [:]
    private var lastProductIDsByID: [Int: [Int]] = [:]
    private var availableWidth: CGFloat = 0
    private var turnID: UUID?
    private var catalog: [Int: TalqynProduct] = [:]
    private weak var delegate: TalqynTurnViewDelegate?

    init(theme: TalqynTheme, strings: TalqynUIStrings, price: TalqynPriceFormatter, loader: TalqynImageLoading) {
        self.theme = theme
        self.strings = strings
        self.price = price
        self.loader = loader
        statusLineView = TalqynStatusLineView(theme: theme, strings: strings)
        typingIndicatorView = TalqynTypingIndicatorView(theme: theme)
        productListView = TalqynProductListView(theme: theme)
        clarifyCardView = TalqynClarifyCardView(theme: theme, strings: strings)
        clarifyAnsweredView = TalqynClarifyAnsweredView(theme: theme, strings: strings)
        redirectNoticeView = TalqynRedirectNoticeView(theme: theme, strings: strings)
        noticeView = TalqynNoticeView(theme: theme, strings: strings)
        toolbarView = TalqynAnswerToolbarView(theme: theme, strings: strings)
        super.init(frame: .zero)
        configureUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func prepareForReuse() {
        delegate = nil
        turnID = nil
        catalog = [:]
        lastTextByID = [:]
        lastProductIDsByID = [:]
        blocksStack.talqynRemoveAllArranged()
        actionsStack.talqynRemoveAllArranged()
        statusLineView.talqynSetHidden(true)
        typingIndicatorView.setActive(false)
        toolbarView.reset()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // A new text size means new fonts in the attributed text: forget what
        // was set so the next update writes it again.
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            lastTextByID = [:]
        }
    }

    func update(row: TalqynTurnRow, delegate: TalqynTurnViewDelegate?, availableWidth: CGFloat) {
        self.delegate = delegate
        self.availableWidth = availableWidth - Self.horizontalMargin(theme) * 2
        turnID = row.turnID
        catalog = row.catalog

        if let stage = row.stage {
            statusLineView.talqynSetHidden(false)
            statusLineView.configure(stage: stage)
        } else {
            statusLineView.talqynSetHidden(true)
        }

        reconcileBlocks(row.blocks, turnID: row.turnID)
        blocksStack.talqynSetHidden(row.blocks.isEmpty)
        typingIndicatorView.setActive(row.isStreaming && !row.blocks.isEmpty)

        productListView.configure(
            sections: row.productSections,
            cards: cardFactory,
            onTap: { [weak delegate] product in delegate?.turnDidTapProduct(product, turnID: row.turnID) }
        )

        updateActions(row)
        updateClarify(row)

        redirectNoticeView.talqynSetHidden(row.redirectQuery == nil)
        if let query = row.redirectQuery {
            redirectNoticeView.configure { [weak delegate] in delegate?.turnDidTapRedirect(query: query) }
        }

        if let notice = row.notice {
            noticeView.talqynSetHidden(false)
            noticeView.configure(tone: notice.tone, text: notice.text, showsRetry: notice.showsRetry) { [weak delegate] in
                delegate?.turnDidTapRetry(turnID: row.turnID)
            }
        } else {
            noticeView.talqynSetHidden(true)
        }

        toolbarView.talqynSetHidden(row.toolbar == nil)
        if let toolbar = row.toolbar {
            toolbarView.configure(
                rating: toolbar.rating,
                offeredReasons: toolbar.offeredReasons,
                selectedReasons: toolbar.selectedReasons,
                copyText: toolbar.copyText,
                availableWidth: self.availableWidth
            ) { [weak delegate] rating, reasons in
                delegate?.turnDidRate(rating, reasons: reasons, turnID: row.turnID)
            }
        }

        answerGroup.talqynSetHidden(statusLineView.isHidden && blocksStack.isHidden && typingIndicatorView.isHidden)
        followUpGroup.talqynSetHidden(
            actionsStack.isHidden && clarifyCardView.isHidden && clarifyAnsweredView.isHidden
                && redirectNoticeView.isHidden && noticeView.isHidden && toolbarView.isHidden
        )
    }

    /// Cards for this update: the app's where its delegate draws them,
    /// otherwise the SDK's.
    private var cardFactory: TalqynProductCardFactory {
        TalqynProductCardFactory(
            theme: theme, strings: strings, price: price, loader: loader,
            appCard: { [weak delegate] in delegate?.turnCardView(for: $0, layout: $1) }
        )
    }

    // MARK: - Product links

    /// A product's name in the text opens the product, the way its card does —
    /// the click is reported the same way too. Other links, and the menu a
    /// long press would bring up for a link, do nothing: the names are the
    /// only links the text carries.
    func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        guard interaction == .invokeDefaultAction,
              let id = TalqynAnswerText.productID(from: URL),
              let product = catalog[id],
              let turnID else { return false }
        TalqynHaptics.tap(theme)
        delegate?.turnDidTapProduct(product, turnID: turnID)
        return false
    }

    // MARK: - Slots

    private func updateActions(_ row: TalqynTurnRow) {
        actionsStack.talqynRemoveAllArranged()
        for action in row.actions {
            switch action {
            case let .filters(filters, summary):
                let view = TalqynActionChipView(theme: theme)
                view.configure(icon: theme.icons.filters, title: strings.applyFilters, summary: summary) { [weak self] in
                    self?.delegate?.turnDidTapFilters(filters, question: row.question)
                }
                actionsStack.addArrangedSubview(view)
            case let .comparison(table, summary):
                let view = TalqynActionChipView(theme: theme)
                view.configure(icon: theme.icons.comparison, title: strings.openComparison, summary: summary) { [weak self] in
                    self?.delegate?.turnDidTapComparison(table)
                }
                actionsStack.addArrangedSubview(view)
            }
        }
        actionsStack.talqynSetHidden(actionsStack.arrangedSubviews.isEmpty)
    }

    private func updateClarify(_ row: TalqynTurnRow) {
        switch row.clarify {
        case let .pending(clarify, draft, isInteractive):
            clarifyCardView.talqynSetHidden(false)
            clarifyAnsweredView.talqynSetHidden(true)
            clarifyCardView.configure(
                clarify: clarify,
                draft: draft,
                isInteractive: isInteractive,
                availableWidth: availableWidth,
                onDraftChange: { [weak self] draft in
                    self?.delegate?.turnDidUpdateClarifyDraft(draft, turnID: row.turnID)
                },
                onSubmit: { [weak self] answer in
                    self?.delegate?.turnDidSubmitClarify(answer: answer, turnID: row.turnID)
                }
            )
        case let .answered(answer):
            clarifyCardView.talqynSetHidden(true)
            clarifyAnsweredView.talqynSetHidden(false)
            clarifyAnsweredView.configure(answer: answer)
        case nil:
            clarifyCardView.talqynSetHidden(true)
            clarifyAnsweredView.talqynSetHidden(true)
        }
    }

    // MARK: - Block reconciliation

    /// Merges the new blocks into the existing views by id: a text view whose
    /// text did not change is left alone, a new block is inserted where it
    /// belongs, a vanished one is removed.
    private func reconcileBlocks(_ blocks: [TalqynTurnRow.Block], turnID: UUID) {
        let existing = blocksStack.arrangedSubviews
        var i = 0
        var j = 0
        var insertionIndex = 0

        while i < existing.count || j < blocks.count {
            let existingID = i < existing.count ? existing[i].tag : Int.max
            if j < blocks.count, existingID == blocks[j].id {
                updateBlockView(existing[i], block: blocks[j], turnID: turnID)
                i += 1; j += 1; insertionIndex += 1
            } else if j < blocks.count, existingID > blocks[j].id {
                blocksStack.insertArrangedSubview(makeBlockView(blocks[j], turnID: turnID), at: insertionIndex)
                j += 1; insertionIndex += 1
            } else {
                let view = existing[i]
                blocksStack.removeArrangedSubview(view)
                view.removeFromSuperview()
                lastTextByID[view.tag] = nil
                lastProductIDsByID[view.tag] = nil
                i += 1
            }
        }
    }

    private func makeBlockView(_ block: TalqynTurnRow.Block, turnID: UUID) -> UIView {
        switch block {
        case let .text(id, content, plain):
            let textView = TalqynAnswerText.makeTextView(theme: theme)
            textView.delegate = self
            textView.tag = id
            textView.attributedText = content
            lastTextByID[id] = plain
            return textView
        case let .products(id, items):
            let stack = UIStackView.talqynVertical(spacing: 8)
            stack.tag = id
            fillCards(stack, items: items, turnID: turnID)
            lastProductIDsByID[id] = items.map(\.talqynID)
            return stack
        }
    }

    private func updateBlockView(_ view: UIView, block: TalqynTurnRow.Block, turnID: UUID) {
        switch block {
        case let .text(id, content, plain):
            guard let textView = view as? UITextView, lastTextByID[id] != plain else { return }
            textView.attributedText = content
            lastTextByID[id] = plain
        case let .products(id, items):
            guard let stack = view as? UIStackView else { return }
            let ids = items.map(\.talqynID)
            guard lastProductIDsByID[id] != ids else { return }
            fillCards(stack, items: items, turnID: turnID)
            lastProductIDsByID[id] = ids
        }
    }

    /// Cards cited by one sentence. Two products — a comparison, most of the
    /// time — sit side by side as tiles, so the paragraph is not split by a
    /// column of rows; one, or three and more, stack as rows.
    private func fillCards(_ stack: UIStackView, items: [TalqynProduct], turnID: UUID) {
        var reusable: [Int: TalqynProductCard] = [:]
        for view in stack.arrangedSubviews {
            for case let card as TalqynProductCard in [view] + ((view as? UIStackView)?.arrangedSubviews ?? []) {
                if let id = card.product?.talqynID { reusable[id] = card }
            }
        }
        stack.talqynRemoveAllArranged()

        let factory = cardFactory
        let layout: TalqynProductCardView.Layout = items.count == 2 ? .tile : .row
        let cards = items.map { item -> UIView in
            let card = factory.card(for: item, layout: layout, reusing: reusable[item.talqynID])
            card.onTap = { [weak self] in self?.delegate?.turnDidTapProduct(item, turnID: turnID) }
            return card
        }
        if layout == .tile {
            let pair = UIStackView(arrangedSubviews: cards)
            pair.axis = .horizontal
            pair.spacing = 8
            pair.distribution = .fillEqually
            stack.addArrangedSubview(pair)
        } else {
            cards.forEach { stack.addArrangedSubview($0) }
        }
    }

    private func configureUI() {
        let content = UIStackView.talqynVertical([answerGroup, productListView, followUpGroup], spacing: 12)
        talqynPin(content)
        statusLineView.isHidden = true
        typingIndicatorView.isHidden = true
        productListView.isHidden = true
        actionsStack.isHidden = true
        clarifyCardView.isHidden = true
        clarifyAnsweredView.isHidden = true
        redirectNoticeView.isHidden = true
        noticeView.isHidden = true
        toolbarView.isHidden = true
    }
}
#endif
