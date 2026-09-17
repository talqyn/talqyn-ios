#if os(iOS)
import Combine
import TalqynConsultantCore
import TalqynSDK
import UIKit

/// The shopper's conversations, newest first: tap to reopen, swipe to delete,
/// pull to refresh, more pages as the list is scrolled.
public final class TalqynChatHistoryViewController: UIViewController {
    private enum Section {
        case chats
    }

    private struct Row: Hashable {
        let sessionID: String
        let title: String
        let subtitle: String
    }

    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let history: TalqynChatHistory
    private let onSelect: (String) -> Void
    private let onDelete: (String) -> Void
    private var cancellable: AnyCancellable?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let placeholderLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let placeholderStack = UIStackView.talqynVertical(spacing: 12)
    private let loadMoreIndicator = UIActivityIndicatorView(style: .medium)
    private var dataSource: UITableViewDiffableDataSource<Section, Row>!

    /// Creates the screen.
    ///
    /// - Parameters:
    ///   - talqyn: The client to load through.
    ///   - theme: Colors and fonts.
    ///   - strings: Copy. `nil` follows the client's locale, as the consultant
    ///     screen does.
    ///   - onSelect: A conversation was chosen; the screen dismisses itself first.
    ///   - onDelete: A conversation was deleted.
    public init(
        talqyn: Talqyn,
        theme: TalqynTheme = .default,
        strings: TalqynUIStrings? = nil,
        onSelect: @escaping (String) -> Void,
        onDelete: @escaping (String) -> Void
    ) {
        self.theme = theme
        self.strings = strings ?? .forLocale(talqyn.currentLocale)
        history = TalqynChatHistory(talqyn: talqyn)
        self.onSelect = onSelect
        self.onDelete = onDelete
        super.init(nibName: nil, bundle: nil)
        // History replaces the consultant rather than sliding a card over it:
        // it is a screen of its own, with its own bar and close button, and a
        // sheet's drag-to-dismiss would fight the list's scroll. It fades in
        // where the consultant was.
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        configureDataSource()
        cancellable = history.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(state) }
        history.load()
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func refreshTriggered() {
        history.load()
    }

    // MARK: - Rendering

    private func render(_ state: TalqynChatHistory.State) {
        switch state {
        case .loading:
            apply(rows: [])
            setLoadingMore(false)
            loadingIndicator.startAnimating()
            placeholderStack.isHidden = true
        case .empty:
            apply(rows: [])
            loadingIndicator.stopAnimating()
            showPlaceholder(strings.historyEmpty, showsRetry: false)
        case let .failed(error):
            apply(rows: [])
            loadingIndicator.stopAnimating()
            if case .forbidden = error {
                showPlaceholder(strings.historyUnavailable, showsRetry: true)
            } else {
                showPlaceholder(strings.historyError, showsRetry: true)
            }
        case let .loaded(chats, isLoadingMore):
            loadingIndicator.stopAnimating()
            placeholderStack.isHidden = true
            apply(rows: chats.map(makeRow))
            setLoadingMore(isLoadingMore)
        }
        let isLoading: Bool
        switch state {
        case .loading: isLoading = true
        case let .loaded(_, more): isLoading = more
        case .empty, .failed: isLoading = false
        }
        if refreshControl.isRefreshing, !isLoading {
            refreshControl.endRefreshing()
        }
    }

    private func makeRow(_ chat: TalqynChatSummary) -> Row {
        let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Row(
            sessionID: chat.sessionID,
            title: title.isEmpty ? strings.historyUntitled : title,
            subtitle: TalqynChatHistory.subtitle(
                for: chat.lastMessageAt, strings: strings, locale: strings.locale
            )
        )
    }

    private func apply(rows: [Row]) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.chats])
        snapshot.appendItems(rows)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func setLoadingMore(_ isLoading: Bool) {
        guard (tableView.tableFooterView === loadMoreIndicator) != isLoading else { return }
        if isLoading {
            loadMoreIndicator.startAnimating()
            tableView.tableFooterView = loadMoreIndicator
        } else {
            loadMoreIndicator.stopAnimating()
            tableView.tableFooterView = UIView()
        }
    }

    private func showPlaceholder(_ text: String, showsRetry: Bool) {
        placeholderLabel.text = text
        retryButton.talqynSetHidden(!showsRetry)
        placeholderStack.isHidden = false
        setLoadingMore(false)
    }

    private func confirmDelete(_ row: Row, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: strings.historyDeleteTitle, message: strings.historyDeleteConfirm, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: strings.cancel, style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: strings.historyDelete, style: .destructive) { [weak self] _ in
            completion(true)
            self?.history.delete(sessionID: row.sessionID)
            self?.onDelete(row.sessionID)
        })
        present(alert, animated: true)
    }

    // MARK: - Setup

    private func configureDataSource() {
        let theme = self.theme
        dataSource = DataSource(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: TalqynHistoryCell.reuseIdentifier, for: indexPath)
            (cell as? TalqynHistoryCell)?.configure(title: row.title, subtitle: row.subtitle, theme: theme)
            return cell
        }
    }

    private final class DataSource: UITableViewDiffableDataSource<Section, Row> {
        override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { true }
    }

    private func configureUI() {
        overrideUserInterfaceStyle = theme.appearance.interfaceStyle
        view.backgroundColor = theme.colors.surface

        let titleLabel = UILabel()
        titleLabel.font = theme.fonts.headline
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.textAlignment = .center
        titleLabel.text = strings.historyTitle

        let closeButton = UIButton(type: .system)
        closeButton.setImage(
            theme.icons.close?.talqynSized(16, .semibold), for: .normal
        )
        closeButton.tintColor = theme.colors.textPrimary
        closeButton.accessibilityLabel = strings.close
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .singleLine
        tableView.separatorColor = theme.colors.border
        let margin = theme.metrics.horizontalMargin
        tableView.separatorInset = UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.tableFooterView = UIView()
        tableView.register(TalqynHistoryCell.self, forCellReuseIdentifier: TalqynHistoryCell.reuseIdentifier)
        tableView.delegate = self
        refreshControl.addTarget(self, action: #selector(refreshTriggered), for: .valueChanged)
        tableView.refreshControl = refreshControl

        loadingIndicator.color = theme.colors.textSecondary
        loadingIndicator.hidesWhenStopped = true
        loadMoreIndicator.color = theme.colors.textSecondary
        loadMoreIndicator.frame = CGRect(x: 0, y: 0, width: 0, height: 44)

        placeholderLabel.font = theme.fonts.callout
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = theme.colors.textSecondary
        placeholderLabel.textAlignment = .center
        placeholderLabel.numberOfLines = 0
        retryButton.titleLabel?.font = theme.fonts.label
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.setTitleColor(theme.colors.accent, for: .normal)
        retryButton.setTitle(strings.retry, for: .normal)
        retryButton.addTarget(self, action: #selector(refreshTriggered), for: .touchUpInside)
        placeholderStack.addArrangedSubview(placeholderLabel)
        placeholderStack.addArrangedSubview(retryButton)
        placeholderStack.alignment = .center
        placeholderStack.isHidden = true

        let header = UIView()
        header.backgroundColor = theme.colors.surface
        let headerContent = UIView()
        let divider = TalqynDividerView(theme: theme, thickness: 0.5)
        [header, tableView, loadingIndicator, placeholderStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        [headerContent, divider].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview($0)
        }
        [titleLabel, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            headerContent.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerContent.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerContent.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerContent.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerContent.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerContent.heightAnchor.constraint(equalToConstant: 56),
            titleLabel.centerXAnchor.constraint(equalTo: headerContent.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: headerContent.centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            closeButton.trailingAnchor.constraint(equalTo: headerContent.trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: headerContent.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingIndicator.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            placeholderStack.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            placeholderStack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -64),
        ])
    }
}

extension TalqynChatHistoryViewController: UITableViewDelegate {
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        dismiss(animated: true) { [onSelect] in onSelect(row.sessionID) }
    }

    public func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard case let .loaded(chats, _) = history.state, indexPath.row < chats.count else { return }
        history.loadMoreIfNeeded(after: chats[indexPath.row])
    }

    public func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: strings.historyDelete) { [weak self] _, _, completion in
            self?.confirmDelete(row, completion: completion)
        }
        delete.image = theme.icons.deleteChat
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

final class TalqynHistoryCell: UITableViewCell {
    static let reuseIdentifier = "TalqynHistoryCell"

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var isConfigured = false

    func configure(title: String, subtitle: String, theme: TalqynTheme) {
        if !isConfigured {
            backgroundColor = theme.colors.surface
            selectionStyle = .default
            accessoryType = .disclosureIndicator
            isAccessibilityElement = true
            accessibilityTraits = .button
            titleLabel.font = theme.fonts.body
            titleLabel.adjustsFontForContentSizeCategory = true
            titleLabel.textColor = theme.colors.textPrimary
            titleLabel.numberOfLines = 2
            subtitleLabel.font = theme.fonts.footnote
            subtitleLabel.adjustsFontForContentSizeCategory = true
            subtitleLabel.textColor = theme.colors.textSecondary
            subtitleLabel.numberOfLines = 1
            let stack = UIStackView.talqynVertical([titleLabel, subtitleLabel], spacing: 4)
            let margin = theme.metrics.horizontalMargin
            contentView.talqynPin(stack, insets: UIEdgeInsets(top: 12, left: margin, bottom: 12, right: margin))
            isConfigured = true
        }
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.talqynSetHidden(subtitle.isEmpty)
        accessibilityLabel = [title, subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
#endif
