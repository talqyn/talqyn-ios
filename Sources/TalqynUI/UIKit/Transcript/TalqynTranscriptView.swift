#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import UIKit

/// The scrolling conversation.
///
/// A new question is pinned to the top of the viewport and stays there while
/// the answer grows underneath — the shopper reads from the start of the
/// answer, not from its end. Room is reserved below the transcript (as a
/// bottom content inset) so the pin holds even while the answer is short. The
/// pin lets go the moment the shopper drags.
///
/// The collection view spans the screen, so it scrolls from anywhere; its
/// content is one column, no wider than the theme's `maxContentWidth` and
/// centered in it.
final class TalqynTranscriptView: UIView {
    weak var turnDelegate: TalqynTurnViewDelegate?
    var onPinnedToBottomChange: ((Bool) -> Void)?

    /// How much of the transcript's own bottom is covered by the composer
    /// floating over it. The transcript runs the full height of the screen —
    /// content passes under the glass — so the last row needs this much space
    /// below it to be readable, and the pin's reserve never falls under it.
    ///
    /// It changes with the composer — a second line of a question — and with
    /// the keyboard, which the composer rides. A shopper at the end of the
    /// transcript stays at its end: the last answer moves up with the keyboard
    /// rather than disappearing under it, and comes back down with it. One
    /// reading somewhere above is left where they are, and a pinned question
    /// keeps its place at the top.
    var bottomReserve: CGFloat = 0 {
        didSet {
            guard bottomReserve != oldValue else { return }
            collectionView.verticalScrollIndicatorInsets.bottom = bottomReserve
            let pinRoom = max(0, collectionView.contentInset.bottom - oldValue)
            let wasAtEnd = anchoredRowID == nil && !rows.isEmpty
                && contentBottomOffsetY(reserve: oldValue) - collectionView.contentOffset.y <= bottomProximity
            if wasAtEnd {
                collectionView.contentInset.bottom = bottomReserve
                let target = contentBottomOffsetY
                if abs(collectionView.contentOffset.y - target) > 0.5 {
                    collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
                }
            } else {
                collectionView.contentInset.bottom = bottomReserve + pinRoom
                applyAnchor()
                trimReserveIfPossible()
            }
            refreshPinnedState()
        }
    }

    private(set) var isPinnedToBottom = true

    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let price: TalqynPriceFormatter
    private let loader: TalqynImageLoading

    private enum RowID: Hashable {
        case turn(UUID)
        case suggestions
    }

    private var rows: [TalqynTranscriptRow] = []
    private var rowsByID: [UUID: TalqynTranscriptRow] = [:]
    private var suggestions: [String] = []
    private var dataSource: UICollectionViewDiffableDataSource<Int, RowID>!

    private var isScrollingProgrammatically = false
    private var anchoredRowID: RowID?
    private var laidOutWidth: CGFloat = 0
    private let bottomProximity: CGFloat = 32
    private let anchorTopGap: CGFloat = 8

    /// What stands between the last row and the pill of the composer over it
    /// once the transcript is at its end. The composer's own padding above the
    /// pill is part of it; the section carries the rest.
    static let composerGap: CGFloat = 32

    /// What the list takes a row's height to be before it has drawn it, the
    /// space between two rows, and the space above the first.
    private static let estimatedRowHeight: CGFloat = 80
    private static let rowSpacing: CGFloat = 20
    private static let firstRowTop: CGFloat = 16

    /// The width of the conversation column.
    private var contentWidth: CGFloat {
        min(collectionView.bounds.width, theme.metrics.maxContentWidth)
    }

    private lazy var collectionView: UICollectionView = {
        let maxContentWidth = theme.metrics.maxContentWidth
        let layout = UICollectionViewCompositionalLayout { _, environment in
            let size = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .estimated(Self.estimatedRowHeight)
            )
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            let side = max(0, floor((environment.container.effectiveContentSize.width - maxContentWidth) / 2))
            section.contentInsets = NSDirectionalEdgeInsets(
                top: Self.firstRowTop, leading: side,
                bottom: Self.composerGap - TalqynComposerView.topInset, trailing: side
            )
            section.interGroupSpacing = Self.rowSpacing
            return section
        }
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.allowsSelection = false
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        // The transcript reaches the bottom edge of the screen, so UIKit would
        // add the home indicator's inset under it — on top of `bottomReserve`,
        // which already covers everything below the composer's top, safe area
        // included. The room under the transcript is this view's to decide.
        view.contentInsetAdjustmentBehavior = .never
        return view
    }()

    init(theme: TalqynTheme, strings: TalqynUIStrings, price: TalqynPriceFormatter, loader: TalqynImageLoading) {
        self.theme = theme
        self.strings = strings
        self.price = price
        self.loader = loader
        super.init(frame: .zero)
        talqynPin(collectionView)
        configureDataSource()
        collectionView.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The cells lay chips and clarify options out for a width they were
    /// handed at configuration. A rotation, or an iPad window resized, hands
    /// them a new one.
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = collectionView.bounds.width
        guard width > 0, width != laidOutWidth else { return }
        let isFirstLayout = laidOutWidth == 0
        laidOutWidth = width
        if let anchor = pendingAnchor {
            pendingAnchor = nil
            applyRows(anchor: anchor)
            return
        }
        guard !isFirstLayout, dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        guard !snapshot.itemIdentifiers.isEmpty else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func reload(rows allRows: [TalqynTranscriptRow], anchor: TalqynTranscriptAnchor) {
        var turnRows = allRows
        suggestions = []
        if case let .suggestions(questions)? = allRows.last {
            suggestions = questions
            turnRows.removeLast()
        }
        rows = turnRows
        rowsByID = Dictionary(uniqueKeysWithValues: turnRows.compactMap { row in
            switch row {
            case let .user(id, _): return (id, row)
            case let .assistant(turn): return (turn.turnID, row)
            case .suggestions: return nil
            }
        })

        guard collectionView.bounds.width > 0 else {
            if anchor != .keep || pendingAnchor == nil { pendingAnchor = anchor }
            return
        }
        pendingAnchor = nil
        applyRows(anchor: anchor)
    }

    /// Where the rows that wait for the first layout are headed.
    private var pendingAnchor: TalqynTranscriptAnchor?

    /// Hands the rows to the list and puts the transcript where `anchor` says.
    private func applyRows(anchor: TalqynTranscriptAnchor) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, RowID>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.compactMap { row in rowIdentifier(row).map(RowID.turn) })
        if !rows.isEmpty, !suggestions.isEmpty {
            snapshot.appendItems([.suggestions])
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carriedOver = snapshot.itemIdentifiers.filter { existing.contains($0) }
        if !carriedOver.isEmpty {
            snapshot.reconfigureItems(carriedOver)
        }
        let followUpsAppeared = anchor == .keep && !carriedOver.isEmpty
            && !suggestions.isEmpty && !existing.contains(.suggestions)

        if carriedOver.isEmpty { jumpAhead(anchor, rowIDs: snapshot.itemIdentifiers) }

        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()
            if followUpsAppeared, let indexPath = self.dataSource.indexPath(for: .suggestions) {
                self.collectionView.cellForItem(at: indexPath)?.contentView.talqynFadeIn()
            }
            if self.rows.isEmpty {
                self.anchoredRowID = nil
                self.collectionView.contentInset.bottom = self.bottomReserve
            } else {
                switch anchor {
                case .newestTurn:
                    self.anchorNewestTurn()
                case .bottom:
                    self.collectionView.contentInset.bottom = self.bottomReserve
                    self.scrollToBottom(animated: false)
                case .keep:
                    self.applyAnchor()
                    self.trimReserveIfPossible()
                }
            }
            self.refreshPinnedState()
        }
    }

    /// Goes to about where a reload is headed before the list lays anything
    /// out, so that it lays out that place and not the one it is leaving.
    ///
    /// A turn is dear to draw. A chat opened from history, or a screen put up
    /// over a long conversation, would otherwise draw the turns at the top
    /// first — where the list happens to stand — only to leave them for the
    /// end a moment later. The place is worked out the way the list itself
    /// will work it out, from its guess at a row it has not drawn; that holds
    /// only for a transcript none of whose rows it has drawn yet. The
    /// anchoring that follows the layout puts the transcript exactly.
    private func jumpAhead(_ anchor: TalqynTranscriptAnchor, rowIDs: [RowID]) {
        let index: Int
        switch anchor {
        case .keep:
            return
        case .bottom:
            index = rowIDs.count - 1
        case .newestTurn:
            guard let id = newestTurnRowID, let item = rowIDs.firstIndex(of: id) else { return }
            index = item
        }
        guard index > 0 else { return }
        let guess = Self.firstRowTop + CGFloat(index) * (Self.estimatedRowHeight + Self.rowSpacing) - anchorTopGap
        collectionView.contentInset.bottom = max(collectionView.contentInset.bottom, collectionView.bounds.height)
        collectionView.contentOffset.y = guess
    }

    /// Updates one turn in place — the streaming one, many times a second.
    func updateRow(_ row: TalqynTranscriptRow) {
        let id: RowID
        switch row {
        case let .user(userID, _): id = .turn(userID)
        case let .assistant(turn): id = .turn(turn.turnID)
        case .suggestions: return
        }
        guard case let .turn(uuid) = id, rowsByID[uuid] != nil else { return }
        rowsByID[uuid] = row
        if let index = rows.firstIndex(where: { rowIdentifier($0) == uuid }) { rows[index] = row }

        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(id) else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()
            self.applyAnchor()
            self.trimReserveIfPossible()
            self.refreshPinnedState()
        }
    }

    private func rowIdentifier(_ row: TalqynTranscriptRow) -> UUID? {
        switch row {
        case let .user(id, _): return id
        case let .assistant(turn): return turn.turnID
        case .suggestions: return nil
        }
    }

    // MARK: - Scrolling

    /// The row a new question is pinned by: the question itself, or the turn
    /// that came without one.
    private var newestTurnRowID: RowID? {
        guard let last = rows.indices.last else { return nil }
        var index = last
        if index > 0, case .user = rows[index - 1] { index -= 1 }
        return rowIdentifier(rows[index]).map(RowID.turn)
    }

    private func anchorNewestTurn() {
        guard let id = newestTurnRowID else { return }
        anchoredRowID = id
        applyAnchor()
    }

    private func applyAnchor() {
        guard let anchoredRowID,
              let indexPath = dataSource.indexPath(for: anchoredRowID),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }

        updateBottomReserve(anchorMinY: frame.minY)
        let target = min(max(frame.minY - anchorTopGap, -collectionView.adjustedContentInset.top), maxContentOffsetY)
        guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
    }

    private func updateBottomReserve(anchorMinY: CGFloat) {
        let tailHeight = collectionView.contentSize.height - anchorMinY + anchorTopGap
        collectionView.contentInset.bottom = max(bottomReserve, collectionView.bounds.height - tailHeight)
    }

    /// The reserve is empty space under the transcript, there so the pinned
    /// question can sit at the top. Once the pin is gone and the shopper has
    /// come to rest inside that space, it is just a hole over the composer:
    /// drop it and let the scroll view settle onto the last row, ``composerGap``
    /// above the pill. Only at rest — the space must not move under a finger.
    private func settleAtBottomIfNeeded() {
        guard anchoredRowID == nil,
              collectionView.contentInset.bottom > bottomReserve,
              collectionView.contentOffset.y > contentBottomOffsetY - bottomProximity
        else { return }
        collectionView.contentInset.bottom = bottomReserve
        guard collectionView.contentOffset.y > contentBottomOffsetY else { return }
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: contentBottomOffsetY),
            animated: TalqynMotion.animates()
        )
    }

    /// The reserve exists for the pin. Once the pin is gone it must not
    /// outlive it as empty space under the transcript: shrink it to what the
    /// current position still needs — never less, so nothing moves under the
    /// shopper's finger — and it reaches zero as they scroll back up.
    private func trimReserveIfPossible() {
        guard anchoredRowID == nil, collectionView.contentInset.bottom > bottomReserve else { return }
        let needed = max(bottomReserve, collectionView.contentOffset.y - contentBottomOffsetY + bottomReserve)
        if collectionView.contentInset.bottom > needed {
            collectionView.contentInset.bottom = needed
        }
    }

    func scrollToBottom(animated: Bool) {
        anchoredRowID = nil
        layoutIfNeeded()
        guard animated else { return settleAtBottom() }
        let target = contentBottomOffsetY
        guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
        isScrollingProgrammatically = true
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: true)
    }

    /// Goes to the end in one step, and stays on it as the end moves.
    ///
    /// The height of a row that has not been on screen is a guess, and a turn
    /// is many times taller than it: the end worked out from guesses lies
    /// somewhere in the middle of a chat opened from history. Getting there
    /// lays the rows of that place out, their real heights move the end, and
    /// the step is taken again until it stops moving.
    private func settleAtBottom() {
        for _ in 0..<12 {
            let target = contentBottomOffsetY
            guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
            collectionView.layoutIfNeeded()
        }
    }

    func refreshPinnedState() {
        guard !isScrollingProgrammatically else { return }
        setPinnedToBottom(contentBottomOffsetY - collectionView.contentOffset.y <= bottomProximity)
    }

    private var contentBottomOffsetY: CGFloat { contentBottomOffsetY(reserve: bottomReserve) }

    /// Where the transcript rests at its end, for a given room under it.
    private func contentBottomOffsetY(reserve: CGFloat) -> CGFloat {
        max(
            -collectionView.adjustedContentInset.top,
            collectionView.contentSize.height - collectionView.bounds.height + reserve
        )
    }

    private var maxContentOffsetY: CGFloat {
        let inset = collectionView.adjustedContentInset
        return max(-inset.top, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
    }

    private func setPinnedToBottom(_ pinned: Bool) {
        guard isPinnedToBottom != pinned else { return }
        isPinnedToBottom = pinned
        onPinnedToBottomChange?(pinned)
    }

    // MARK: - Cells

    private func configureDataSource() {
        let theme = self.theme
        let strings = self.strings
        let price = self.price
        let loader = self.loader

        let turnCell = UICollectionView.CellRegistration<TalqynAssistantTurnCell, TalqynTurnRow> { [weak self] cell, _, row in
            cell.configure(
                row: row,
                delegate: self?.turnDelegate,
                availableWidth: self?.contentWidth ?? 0,
                theme: theme, strings: strings, price: price, loader: loader
            )
        }
        let userCell = UICollectionView.CellRegistration<TalqynUserBubbleCell, String> { [weak self] cell, _, text in
            cell.configure(text: text, theme: theme, strings: strings) { question in
                self?.turnDelegate?.turnDidRequestEdit(question: question)
            }
        }
        let suggestionsCell = UICollectionView.CellRegistration<TalqynSuggestionsCell, [String]> { [weak self] cell, _, questions in
            cell.configure(questions: questions, theme: theme, availableWidth: self?.contentWidth ?? 0) { question in
                self?.turnDelegate?.turnDidTapSuggestion(question)
            }
        }

        dataSource = UICollectionViewDiffableDataSource<Int, RowID>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            guard let self else { return UICollectionViewCell() }
            switch id {
            case .suggestions:
                return collectionView.dequeueConfiguredReusableCell(using: suggestionsCell, for: indexPath, item: self.suggestions)
            case let .turn(uuid):
                switch self.rowsByID[uuid] {
                case let .user(_, text)?:
                    return collectionView.dequeueConfiguredReusableCell(using: userCell, for: indexPath, item: text)
                case let .assistant(row)?:
                    return collectionView.dequeueConfiguredReusableCell(using: turnCell, for: indexPath, item: row)
                default:
                    return UICollectionViewCell()
                }
            }
        }
    }
}

// MARK: - UICollectionViewDelegate

extension TalqynTranscriptView: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isScrollingProgrammatically else { return }
        trimReserveIfPossible()
        refreshPinnedState()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isScrollingProgrammatically = false
        trimReserveIfPossible()
        refreshPinnedState()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleAtBottomIfNeeded()
        trimReserveIfPossible()
        refreshPinnedState()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        guard !willDecelerate else { return }
        settleAtBottomIfNeeded()
        trimReserveIfPossible()
        refreshPinnedState()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isScrollingProgrammatically = false
        anchoredRowID = nil
        if collectionView.contentOffset.y <= contentBottomOffsetY {
            collectionView.contentInset.bottom = bottomReserve
        }
    }
}

// MARK: - Cells

final class TalqynUserBubbleCell: UICollectionViewCell {
    private var bubbleView: TalqynUserBubbleView?

    func configure(
        text: String,
        theme: TalqynTheme,
        strings: TalqynUIStrings,
        onEdit: @escaping (String) -> Void
    ) {
        if bubbleView == nil {
            let view = TalqynUserBubbleView(theme: theme, strings: strings)
            let margin = theme.metrics.horizontalMargin
            contentView.talqynPin(view, insets: UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin))
            bubbleView = view
        }
        bubbleView?.configure(text: text, onEdit: onEdit)
    }
}

final class TalqynAssistantTurnCell: UICollectionViewCell {
    private var turnContentView: TalqynTurnContentView?

    override func prepareForReuse() {
        super.prepareForReuse()
        turnContentView?.prepareForReuse()
    }

    func configure(
        row: TalqynTurnRow,
        delegate: TalqynTurnViewDelegate?,
        availableWidth: CGFloat,
        theme: TalqynTheme,
        strings: TalqynUIStrings,
        price: TalqynPriceFormatter,
        loader: TalqynImageLoading
    ) {
        if turnContentView == nil {
            let view = TalqynTurnContentView(theme: theme, strings: strings, price: price, loader: loader)
            contentView.talqynPin(view)
            turnContentView = view
        }
        turnContentView?.update(row: row, delegate: delegate, availableWidth: availableWidth)
    }
}

/// The prompts under an answer, as chips.
final class TalqynSuggestionsCell: UICollectionViewCell {
    private let chipsView = TalqynChipsFlowView()
    private var isConfigured = false

    func configure(questions: [String], theme: TalqynTheme, availableWidth: CGFloat, onTap: @escaping (String) -> Void) {
        if !isConfigured {
            contentView.talqynPin(chipsView, insets: UIEdgeInsets(
                top: 0, left: TalqynTurnContentView.horizontalMargin(theme),
                bottom: 0, right: TalqynTurnContentView.horizontalMargin(theme)
            ))
            isConfigured = true
        }
        chipsView.preferredLayoutWidth = availableWidth - TalqynTurnContentView.horizontalMargin(theme) * 2
        chipsView.setChips(questions.map { question in
            let chip = TalqynChipView(theme: theme, title: question)
            chip.onTap = { onTap(question) }
            return chip
        })
    }
}
#endif
