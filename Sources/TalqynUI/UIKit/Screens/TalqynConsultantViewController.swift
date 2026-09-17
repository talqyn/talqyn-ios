#if os(iOS)
import Combine
import TalqynConsultantCore
import TalqynSDK
import UIKit

/// What the consultant screen hands back to the app: the navigation it cannot
/// perform itself and the product cards it does not own.
///
/// Every screen the SDK can draw on its own — comparison, history, clarify —
/// it draws. What leads out of the consultant — a product page, the search
/// results — belongs to the app. So does the product card, if the app wants
/// it: by default the SDK draws its own.
@MainActor
public protocol TalqynConsultantDelegate: AnyObject {
    /// A product card was tapped. The click is already reported to Talqyn.
    func consultant(_ controller: TalqynConsultantViewController, openProduct product: TalqynProduct)

    /// The consultant decided the request was a search: open results for the
    /// query.
    func consultant(_ controller: TalqynConsultantViewController, openSearch query: String)

    /// The consultant proposed filters: open a listing for the criteria,
    /// already combined with the question that produced them.
    func consultant(_ controller: TalqynConsultantViewController, applyFilters criteria: TalqynFilterCriteria)

    /// The product card itself, drawn by the app in place of the SDK's: its
    /// own image loading, price, badges, and controls. Called once per card
    /// shown; return `nil` for the SDK's card — the default, and the choice
    /// may differ by product or by layout. A horizontal card stands for a
    /// product cited in the text, at the full width of the transcript; a
    /// vertical card is a tile in the carousel under the answer, or one of a
    /// pair cited by one sentence.
    ///
    /// The SDK sets the width — the transcript's for a horizontal card, its
    /// own tile's for a vertical one unless the view fixes its own — and takes
    /// the height from the view; the two cards of a pair are stretched to the
    /// same height. The SDK also handles the tap on the card: it reports the
    /// click to Talqyn and calls ``consultant(_:openProduct:)``, so the view
    /// must not open the product itself. Buttons inside the view keep working
    /// as usual.
    func consultant(
        _ controller: TalqynConsultantViewController,
        cardViewFor product: TalqynProduct,
        layout: TalqynProductCardLayout
    ) -> UIView?

    /// The shopper rated a turn, or picked a reason under a thumb down.
    ///
    /// The rating is already on its way to Talqyn; this is for the app's own
    /// analytics. Optional.
    ///
    /// - Parameters:
    ///   - rating: The verdict, or `nil` when it was taken back.
    ///   - reasons: Why the answer did not help, as picked so far.
    ///   - turn: The turn rated.
    func consultant(
        _ controller: TalqynConsultantViewController,
        didRate rating: TalqynAnswerRating?,
        reasons: [TalqynFeedbackReason],
        for turn: TalqynAssistantTurn
    )
}

public extension TalqynConsultantDelegate {
    func consultant(
        _ controller: TalqynConsultantViewController,
        cardViewFor product: TalqynProduct,
        layout: TalqynProductCardLayout
    ) -> UIView? { nil }

    func consultant(
        _ controller: TalqynConsultantViewController,
        didRate rating: TalqynAnswerRating?,
        reasons: [TalqynFeedbackReason],
        for turn: TalqynAssistantTurn
    ) {}
}

/// The consultant screen, drawn by the SDK.
///
/// Give it a client, a theme, and a delegate for the three things only the app
/// can do — open a product, open search results, open a filtered listing —
/// and it handles the rest: the conversation, streaming, clarifications,
/// product cards and comparison, ratings, chat history, click events. The
/// delegate may also draw the product cards itself.
///
/// ```swift
/// let screen = TalqynConsultantViewController(talqyn: talqyn, theme: theme)
/// screen.delegate = self
/// navigationController?.pushViewController(screen, animated: true)
/// ```
///
/// Copy follows the client's locale unless `strings` is passed. The screen
/// draws its own bar with the way out — a back arrow when pushed, a cross when
/// presented — the title, history, and a new chat, and hides the navigation
/// controller's bar while it is on screen; the swipe back keeps working. Pass
/// `showsHeader: false` to keep your bar, and wire
/// `TalqynChatHistoryViewController` and ``TalqynConversation/reset()`` into
/// it.
public final class TalqynConsultantViewController: UIViewController {
    /// The conversation behind the screen. Set ``TalqynConversation/draft`` to
    /// prefill the composer; keep the object to survive the screen closing.
    public let conversation: TalqynConversation

    /// Where the screen sends the shopper when they leave the consultant.
    public weak var delegate: TalqynConsultantDelegate?

    /// The screen's colors and fonts — readable here so a card view from the
    /// delegate can match the screen it sits in.
    public let theme: TalqynTheme

    /// The copy the screen shows, with `title` and `exampleQuestions` from the
    /// initializer already applied. Fixed at creation: a later
    /// `Talqyn.setLocale(_:)` does not change it.
    public let strings: TalqynUIStrings

    /// How the screen writes prices, for a card of the app's own to write
    /// them the same way.
    public let priceFormatter: TalqynPriceFormatter

    /// What loads the screen's product images, for a card of the app's own to
    /// share its cache.
    public let imageLoader: TalqynImageLoading

    /// Whether the screen draws its own bar in place of the navigation
    /// controller's.
    public let showsHeader: Bool

    /// Whether the empty screen carries "Powered by Talqyn" under the examples.
    public let showsPoweredBy: Bool

    private let rowBuilder: TalqynTranscriptRowBuilder
    private let clarifyPresentation = TalqynClarifyPresentation()
    private var cancellables: Set<AnyCancellable> = []

    private lazy var headerView = TalqynHeaderView(theme: theme, strings: strings)
    private lazy var emptyStateView = TalqynEmptyStateView(
        theme: theme, strings: strings, showsPoweredBy: showsPoweredBy
    ) { [weak self] example in
        self?.conversation.send(example)
    }
    private lazy var transcriptView = TalqynTranscriptView(
        theme: theme, strings: strings, price: priceFormatter, loader: imageLoader
    )
    private lazy var composerView = TalqynComposerView(theme: theme, strings: strings)
    private lazy var composerBarView = TalqynGlassBarView()
    private lazy var restoreOverlay: UIView = {
        let view = UIView()
        view.backgroundColor = theme.colors.background
        view.isHidden = true
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.color = theme.colors.textSecondary
        indicator.startAnimating()
        view.addSubview(indicator)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }()
    private lazy var scrollToBottomButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(
            theme.icons.scrollToBottom?.talqynSized(14, .semibold), for: .normal
        )
        button.tintColor = theme.colors.textPrimary
        button.backgroundColor = theme.colors.surface
        button.layer.cornerRadius = 18
        button.layer.shadowRadius = 8
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.accessibilityLabel = strings.scrollToBottom
        button.alpha = 0
        button.addTarget(self, action: #selector(scrollToBottomTapped), for: .touchUpInside)
        return button
    }()

    private weak var clarifySheet: TalqynClarifySheetViewController?
    /// A clarifying question settled while the screen was out of sight; it is
    /// asked when the screen appears.
    private var isClarifyWaitingForAppearance = false

    private var renderedTurnIDs: [UUID] = []
    private var renderedAssistantTurns: [UUID: TalqynAssistantTurn] = [:]
    private var renderedDrafts: [UUID: TalqynClarifyDraft] = [:]
    private var renderedCatalogCount = 0
    private var wasStreaming = false
    private var wasRestoring = false
    private var isRenderScheduled = false
    private var navigationBarWasHidden: Bool?
    private var popGestureDelegate: TalqynPopGestureDelegate?
    private weak var replacedPopGestureDelegate: UIGestureRecognizerDelegate?

    /// Creates the screen over a client.
    ///
    /// - Parameters:
    ///   - talqyn: The client to talk through.
    ///   - theme: Colors and fonts.
    ///   - title: What the screen calls itself, in its own bar and over the
    ///     examples on an empty screen. `nil` keeps the copy's own name.
    ///   - exampleQuestions: The questions offered as chips on an empty screen,
    ///     and again under the first answer where the shopper has not asked
    ///     them yet. `nil` keeps the copy's own; an empty array shows none.
    ///   - strings: Copy. `nil` follows the client's locale.
    ///   - priceFormatter: How prices are written. Defaults to tenge.
    ///   - imageLoader: Loads product images. Defaults to
    ///     ``TalqynURLImageLoader/shared``: `URLSession` and one memory cache
    ///     for every screen.
    ///   - showsHeader: Whether to draw the screen's own bar.
    ///   - showsPoweredBy: Whether the empty screen carries "Powered by
    ///     Talqyn" under the examples. The wording is fixed, in every locale;
    ///     this is the switch.
    ///   - maxFollowUps: How many follow-up prompts to offer under an answer.
    ///     Defaults to three; `0` shows none. Only on this initializer — a
    ///     conversation the app builds carries its own.
    public convenience init(
        talqyn: Talqyn,
        theme: TalqynTheme = .default,
        title: String? = nil,
        exampleQuestions: [String]? = nil,
        strings: TalqynUIStrings? = nil,
        priceFormatter: TalqynPriceFormatter = .tenge,
        imageLoader: TalqynImageLoading = TalqynURLImageLoader.shared,
        showsHeader: Bool = true,
        showsPoweredBy: Bool = true,
        maxFollowUps: Int = TalqynConversationLimits.maxFollowUps
    ) {
        self.init(
            conversation: TalqynConversation(talqyn: talqyn, maxFollowUps: maxFollowUps),
            theme: theme, title: title, exampleQuestions: exampleQuestions, strings: strings,
            priceFormatter: priceFormatter, imageLoader: imageLoader, showsHeader: showsHeader,
            showsPoweredBy: showsPoweredBy
        )
    }

    /// Creates the screen over a conversation the app owns.
    public init(
        conversation: TalqynConversation,
        theme: TalqynTheme = .default,
        title: String? = nil,
        exampleQuestions: [String]? = nil,
        strings: TalqynUIStrings? = nil,
        priceFormatter: TalqynPriceFormatter = .tenge,
        imageLoader: TalqynImageLoading = TalqynURLImageLoader.shared,
        showsHeader: Bool = true,
        showsPoweredBy: Bool = true
    ) {
        self.conversation = conversation
        self.theme = theme
        // A name and a set of examples given here beat the ones in the copy, so
        // an app can change either without carrying a whole string set.
        var copy = strings ?? .forLocale(conversation.talqyn.currentLocale)
        if let title { copy.title = title }
        if let exampleQuestions { copy.exampleQuestions = exampleQuestions }
        self.strings = copy
        self.priceFormatter = priceFormatter
        self.imageLoader = imageLoader
        self.showsHeader = showsHeader
        self.showsPoweredBy = showsPoweredBy
        rowBuilder = TalqynTranscriptRowBuilder(theme: theme, strings: copy, price: priceFormatter)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Lifecycle

    override public func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        conversation.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRender() }
            .store(in: &cancellables)
        conversation.$draft
            .receive(on: DispatchQueue.main)
            .sink { [weak self] draft in self?.composerView.setText(draft) }
            .store(in: &cancellables)
        render()
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateComposerReserve()
    }

    /// How much of the transcript the composer covers — its own height plus
    /// whatever is under it, the keyboard included, since it rides the
    /// keyboard's layout guide.
    private func updateComposerReserve() {
        transcriptView.bottomReserve = max(0, view.bounds.height - composerView.frame.minY)
    }

    /// A `CGColor` does not follow the appearance, so the palette's shadow is
    /// resolved against the current one — here and on every change of it.
    private func applyShadow(to view: UIView) {
        let resolved = theme.colors.shadow.resolvedColor(with: traitCollection)
        view.layer.shadowColor = resolved.cgColor
        view.layer.shadowOpacity = Float(resolved.cgColor.alpha)
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if showsHeader, let navigationController {
            navigationBarWasHidden = navigationController.isNavigationBarHidden
            navigationController.setNavigationBarHidden(true, animated: false)
        }
        headerView.setLeadingAction(leadingAction)
        Task { await conversation.refreshIdentity() }
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installPopGesture()
        // A question that settled while the screen was out of sight is asked
        // now that the shopper is back.
        if isClarifyWaitingForAppearance, !conversation.isStreaming {
            presentClarifyIfNeeded(hasAppeared: true)
        }
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        restorePopGesture()
        if let navigationBarWasHidden, let navigationController {
            navigationController.setNavigationBarHidden(navigationBarWasHidden, animated: animated)
        }
        // Going away for good, as opposed to being covered by a product card or
        // put aside on another tab: an answer nobody will come back to is still
        // an LLM call being paid for.
        if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true {
            conversation.stop()
        }
    }

    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyShadow(to: scrollToBottomButton)
        }
        // The fonts follow the text size, and the rendered answers cache the
        // fonts they were set in: render them again at the new size.
        guard isViewLoaded,
              previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
        else { return }
        rowBuilder.forgetAll()
        transcriptView.reload(rows: rows(), anchor: .keep)
    }

    // MARK: - The way out

    /// A back arrow when the screen was pushed onto a navigation stack, a
    /// cross when it was presented, nothing when it is a root of its own —
    /// a tab, say, where there is nowhere to go back to.
    private var leadingAction: TalqynHeaderView.LeadingAction? {
        if let navigationController, navigationController.viewControllers.first !== stackEntry(in: navigationController) {
            return .back
        }
        return presentingViewController == nil ? nil : .close
    }

    /// What stands for the screen on a navigation stack: the screen itself,
    /// or the container that was pushed with the screen inside — a SwiftUI
    /// host — so the stack is searched for its ancestor.
    private func stackEntry(in navigationController: UINavigationController) -> UIViewController {
        var node: UIViewController = self
        while let parent = node.parent, parent !== navigationController { node = parent }
        return node
    }

    /// Whether the shopper sees the screen: in a window, at the top of its
    /// navigation stack, and not in the middle of a transition.
    private var isOnScreen: Bool {
        guard isViewLoaded, view.window != nil, transitionCoordinator == nil else { return false }
        guard let navigationController else { return true }
        return navigationController.topViewController === stackEntry(in: navigationController)
    }

    private func leave(_ action: TalqynHeaderView.LeadingAction) {
        view.endEditing(true)
        switch action {
        case .back:
            navigationController?.popViewController(animated: true)
        case .close:
            dismiss(animated: true)
        }
    }

    /// The swipe from the edge is how a pushed screen is left on iOS, and a
    /// hidden navigation bar can take it away with the bar. While the screen
    /// is on top, the gesture answers to the stack alone; the delegate it had
    /// comes back as soon as the screen starts to leave.
    private func installPopGesture() {
        guard showsHeader, popGestureDelegate == nil,
              let navigationController, navigationController.viewControllers.count > 1,
              let gesture = navigationController.interactivePopGestureRecognizer else { return }
        let proxy = TalqynPopGestureDelegate(navigationController: navigationController)
        replacedPopGestureDelegate = gesture.delegate
        popGestureDelegate = proxy
        gesture.delegate = proxy
    }

    private func restorePopGesture() {
        guard let proxy = popGestureDelegate else { return }
        popGestureDelegate = nil
        if let gesture = navigationController?.interactivePopGestureRecognizer, gesture.delegate === proxy {
            gesture.delegate = replacedPopGestureDelegate
        }
        replacedPopGestureDelegate = nil
    }

    // MARK: - Rendering

    private func scheduleRender() {
        guard !isRenderScheduled else { return }
        isRenderScheduled = true
        // objectWillChange fires before the change; the next runloop turn
        // sees the state after it, and coalesces a burst of changes into one
        // pass.
        DispatchQueue.main.async { [weak self] in
            self?.isRenderScheduled = false
            self?.render()
        }
    }

    private func render() {
        let turnIDs = conversation.turns.map(\.id)
        let isStreaming = conversation.isStreaming
        let isRestoring = conversation.isRestoring
        let structural = turnIDs != renderedTurnIDs
        let streamingEnded = wasStreaming && !isStreaming
        let restoreEnded = wasRestoring && !isRestoring

        setEmptyStateVisible(conversation.isEmpty)
        headerView.setActionsEnabled(!isStreaming && !isRestoring)
        composerView.setStreaming(isStreaming)
        restoreOverlay.talqynSetHidden(!isRestoring)
        if isRestoring { scrollToBottomButton.alpha = 0 }

        if structural {
            let removed = renderedTurnIDs.filter { !turnIDs.contains($0) }
            rowBuilder.forget(turnIDs: removed)
            clarifyPresentation.forget(turnIDs: removed)
            let newUserTurn = conversation.turns.contains { turn in
                if case .user = turn { return !renderedTurnIDs.contains(turn.id) }
                return false
            }
            if newUserTurn { clarifyPresentation.beginRequest() }
            let anchor: TalqynTranscriptAnchor = restoreEnded ? .bottom : (newUserTurn ? .newestTurn : .keep)
            if restoreEnded || conversation.isEmpty {
                rowBuilder.forgetAll()
                clarifyPresentation.forgetAll()
            }
            transcriptView.reload(rows: rows(), anchor: anchor)
        } else if streamingEnded {
            // Suggestions appear under the answer once it is complete.
            transcriptView.reload(rows: rows(), anchor: .keep)
        } else {
            // Whatever turn changed is redrawn — the streaming one many times
            // a second, an older one when its rating lands or is put back.
            // The drafts and the catalog feed the latest turn only.
            let feedsLatest = conversation.clarifyDrafts != renderedDrafts
                || conversation.productsByID.count != renderedCatalogCount
            let latestID = conversation.turns.last?.id
            for case let .assistant(turn) in conversation.turns
            where turn != renderedAssistantTurns[turn.id] || (feedsLatest && turn.id == latestID) {
                transcriptView.updateRow(.assistant(rowBuilder.turnRow(
                    turn, conversation: conversation, dismissedClarifyTurns: clarifyPresentation.inlineTurns
                )))
            }
        }

        if streamingEnded {
            presentClarifyIfNeeded()
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: strings.answerReady)
            }
        }
        if let failure = conversation.restoreFailure {
            conversation.restoreFailure = nil
            if case .notFound = failure {
                showError(strings.historyGone)
            } else {
                showError(strings.historyError)
            }
        }

        renderedTurnIDs = turnIDs
        renderedAssistantTurns = conversation.turns.reduce(into: [:]) { rendered, turn in
            if let assistant = turn.assistant { rendered[assistant.id] = assistant }
        }
        renderedDrafts = conversation.clarifyDrafts
        renderedCatalogCount = conversation.productsByID.count
        wasStreaming = isStreaming
        wasRestoring = isRestoring
        updateScrollToBottomVisibility()
    }

    private func rows() -> [TalqynTranscriptRow] {
        rowBuilder.rows(for: conversation, dismissedClarifyTurns: clarifyPresentation.inlineTurns)
    }

    private func setEmptyStateVisible(_ isVisible: Bool) {
        headerView.setNewChatVisible(!isVisible)
        guard emptyStateView.isHidden == isVisible else { return }
        let appearing: UIView = isVisible ? emptyStateView : transcriptView
        let disappearing: UIView = isVisible ? transcriptView : emptyStateView
        appearing.alpha = 0
        appearing.isHidden = false
        UIView.animate(withDuration: TalqynMotion.duration(0.2)) {
            appearing.alpha = 1
            disappearing.alpha = 0
        } completion: { _ in
            disappearing.isHidden = true
            disappearing.alpha = 1
        }
    }

    private func updateScrollToBottomVisibility() {
        let isVisible = !transcriptView.isHidden && !transcriptView.isPinnedToBottom && !conversation.isRestoring
        guard (scrollToBottomButton.alpha > 0) != isVisible else { return }
        UIView.animate(withDuration: TalqynMotion.duration(0.2)) {
            self.scrollToBottomButton.alpha = isVisible ? 1 : 0
        }
    }

    // MARK: - Clarify

    /// Asks the latest turn's clarifying question once its answer has settled.
    ///
    /// Only a screen the shopper sees can ask. One out of sight — under a
    /// product page pushed over it, on another tab, in the middle of a
    /// transition — gets its sheet refused by UIKit, or presented from what
    /// UIKit calls a detached controller, over whatever the shopper is looking
    /// at. So the decision waits for the screen to appear. A screen on show
    /// that has presented something is another matter: the question goes into
    /// the transcript as a card, and waits there under the modal.
    ///
    /// - Parameter hasAppeared: Whether the screen has just appeared, and is
    ///   on show whatever transition is still winding down around it.
    private func presentClarifyIfNeeded(hasAppeared: Bool = false) {
        isClarifyWaitingForAppearance = false
        guard let turn = conversation.turns.last?.assistant, let clarify = turn.clarify else { return }
        guard hasAppeared || presentedViewController != nil || isOnScreen else {
            isClarifyWaitingForAppearance = true
            return
        }
        switch clarifyPresentation.decide(for: turn, canPresent: presentedViewController == nil) {
        case .none:
            return
        case .inline:
            transcriptView.reload(rows: rows(), anchor: .keep)
        case .sheet:
            let sheet = TalqynClarifySheetViewController(
                theme: theme,
                strings: strings,
                clarify: clarify,
                draft: conversation.clarifyDrafts[turn.id] ?? TalqynClarifyDraft(),
                onDraftChange: { [weak self] draft in self?.conversation.clarifyDrafts[turn.id] = draft },
                onSubmit: { [weak self] answer in
                    guard let self else { return }
                    self.clarifySheet = nil
                    self.dismiss(animated: true)
                    self.conversation.submitClarify(turnID: turn.id, answer: answer)
                }
            )
            sheet.onUserDismiss = { [weak self] in
                guard let self else { return }
                self.clarifySheet = nil
                self.clarifyPresentation.sheetDismissed(turnID: turn.id)
                self.transcriptView.reload(rows: self.rows(), anchor: .keep)
            }
            clarifySheet = sheet
            present(sheet, animated: true)
        }
    }

    // MARK: - Actions

    @objc private func scrollToBottomTapped() {
        transcriptView.scrollToBottom(animated: TalqynMotion.animates())
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func confirmReset() {
        let alert = UIAlertController(title: strings.newChat, message: strings.newChatConfirm, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: strings.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: strings.newChat, style: .default) { [weak self] _ in
            self?.view.endEditing(true)
            self?.conversation.reset()
        })
        present(alert, animated: true)
    }

    private func openHistory() {
        guard !conversation.isStreaming else { return }
        view.endEditing(true)
        let history = TalqynChatHistoryViewController(
            talqyn: conversation.talqyn,
            theme: theme,
            strings: strings,
            onSelect: { [weak self] sessionID in self?.conversation.restore(sessionID: sessionID) },
            onDelete: { [weak self] sessionID in self?.conversation.discardIfOpen(sessionID: sessionID) }
        )
        present(history, animated: true)
    }

    private func showError(_ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: strings.ok, style: .default))
        present(alert, animated: true)
    }

    // MARK: - Setup

    private func configureUI() {
        // The theme decides the appearance, not the device, when it says so:
        // this is what makes a dynamic palette resolve to the right half — and
        // the material behind the composer along with it.
        overrideUserInterfaceStyle = theme.appearance.interfaceStyle
        view.backgroundColor = theme.colors.background
        applyShadow(to: scrollToBottomButton)

        [
            headerView, emptyStateView, transcriptView, composerBarView, composerView,
            scrollToBottomButton, restoreOverlay,
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        headerView.isHidden = !showsHeader
        transcriptView.isHidden = true
        transcriptView.turnDelegate = self
        transcriptView.onPinnedToBottomChange = { [weak self] _ in self?.updateScrollToBottomVisibility() }

        let contentTop = showsHeader ? headerView.bottomAnchor : view.safeAreaLayoutGuide.topAnchor
        let safeArea = view.safeAreaLayoutGuide
        let maxContentWidth = theme.metrics.maxContentWidth
        // On a phone the composer and the empty screen span the width; on an
        // iPad they keep to the column the transcript reads in.
        let composerWidth = composerView.widthAnchor.constraint(equalTo: safeArea.widthAnchor)
        composerWidth.priority = UILayoutPriority(rawValue: 999)
        let emptyStateWidth = emptyStateView.widthAnchor.constraint(equalTo: safeArea.widthAnchor)
        emptyStateWidth.priority = UILayoutPriority(rawValue: 999)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            composerView.widthAnchor.constraint(lessThanOrEqualToConstant: maxContentWidth),
            composerView.widthAnchor.constraint(lessThanOrEqualTo: safeArea.widthAnchor),
            composerWidth,
            composerView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            // The bar runs to the bottom edge, not to the composer's: the
            // keyboard's guide stops at the safe area, and bare transcript
            // must not show in the strip under it.
            composerBarView.topAnchor.constraint(equalTo: composerView.topAnchor),
            composerBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyStateView.topAnchor.constraint(equalTo: contentTop),
            emptyStateView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            emptyStateView.widthAnchor.constraint(lessThanOrEqualToConstant: maxContentWidth),
            emptyStateView.widthAnchor.constraint(lessThanOrEqualTo: safeArea.widthAnchor),
            emptyStateWidth,
            emptyStateView.bottomAnchor.constraint(equalTo: composerView.topAnchor),
            // The transcript runs to the bottom of the screen and the composer
            // floats over it on glass; the room the last row needs to clear it
            // is a content inset, kept in `updateComposerReserve`.
            transcriptView.topAnchor.constraint(equalTo: contentTop),
            transcriptView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcriptView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcriptView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            restoreOverlay.topAnchor.constraint(equalTo: contentTop),
            restoreOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            restoreOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            restoreOverlay.bottomAnchor.constraint(equalTo: composerView.topAnchor),
            scrollToBottomButton.trailingAnchor.constraint(
                equalTo: composerView.trailingAnchor, constant: -theme.metrics.horizontalMargin
            ),
            scrollToBottomButton.bottomAnchor.constraint(equalTo: composerView.topAnchor, constant: -4),
            scrollToBottomButton.widthAnchor.constraint(equalToConstant: 36),
            scrollToBottomButton.heightAnchor.constraint(equalToConstant: 36),
        ])
        if !showsHeader {
            headerView.heightAnchor.constraint(equalToConstant: 0).isActive = true
        }

        for target in [transcriptView, emptyStateView] as [UIView] {
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            tap.cancelsTouchesInView = false
            target.addGestureRecognizer(tap)
        }

        headerView.configure(
            onNewChat: { [weak self] in self?.confirmReset() },
            onHistory: { [weak self] in self?.openHistory() },
            onLeading: { [weak self] action in self?.leave(action) }
        )
        composerView.configure(
            onSend: { [weak self] in
                guard let self else { return }
                self.conversation.send(self.composerView.text)
            },
            onStop: { [weak self] in self?.conversation.stop() }
        )
        composerView.onTextChange = { [weak self] text in
            guard let self, self.conversation.draft != text else { return }
            self.conversation.draft = text
        }
        composerView.onHeightChange = { [weak self] in
            UIView.animate(withDuration: TalqynMotion.duration(0.15)) { self?.view.layoutIfNeeded() }
        }
    }
}

// MARK: - TalqynTurnViewDelegate

extension TalqynConsultantViewController: TalqynTurnViewDelegate {
    func turnDidTapProduct(_ product: TalqynProduct, turnID: UUID) {
        if let turn = conversation.turns.first(where: { $0.id == turnID })?.assistant {
            conversation.trackProductTap(product, in: turn)
        }
        delegate?.consultant(self, openProduct: product)
    }

    func turnCardView(for product: TalqynProduct, layout: TalqynProductCardLayout) -> UIView? {
        delegate?.consultant(self, cardViewFor: product, layout: layout)
    }

    func turnDidTapRetry(turnID: UUID) {
        conversation.retry(turnID: turnID)
    }

    func turnDidTapRedirect(query: String) {
        delegate?.consultant(self, openSearch: query)
    }

    func turnDidTapFilters(_ filters: TalqynActionFilters, question: String) {
        delegate?.consultant(self, applyFilters: filters.criteria(query: question))
    }

    func turnDidTapComparison(_ table: TalqynComparisonTable) {
        let comparison = TalqynComparisonViewController(
            table: table,
            products: conversation.productsByID,
            theme: theme,
            strings: strings,
            priceFormatter: priceFormatter,
            imageLoader: imageLoader
        ) { [weak self] product in
            guard let self else { return }
            self.delegate?.consultant(self, openProduct: product)
        }
        present(comparison, animated: true)
    }

    func turnDidSubmitClarify(answer: String, turnID: UUID) {
        conversation.submitClarify(turnID: turnID, answer: answer)
    }

    func turnDidUpdateClarifyDraft(_ draft: TalqynClarifyDraft, turnID: UUID) {
        conversation.clarifyDrafts[turnID] = draft
    }

    func turnDidTapSuggestion(_ text: String) {
        conversation.send(text)
    }

    func turnDidRate(_ rating: TalqynAnswerRating?, reasons: [TalqynFeedbackReason], turnID: UUID) {
        // The turn is redrawn by the render pass the change triggers — and
        // again if Talqyn does not take the rating and it is put back.
        conversation.rate(turnID: turnID, rating, reasons: reasons)
        guard let turn = conversation.turns.first(where: { $0.id == turnID })?.assistant else { return }
        delegate?.consultant(self, didRate: rating, reasons: reasons, for: turn)
    }

    func turnDidRequestEdit(question: String) {
        conversation.draft = question
        composerView.focus()
    }
}

/// Lets the edge swipe pop a stack whose bar is hidden, and nothing else: not
/// the root, and not in the middle of a transition.
@MainActor
private final class TalqynPopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    private weak var navigationController: UINavigationController?

    init(navigationController: UINavigationController) {
        self.navigationController = navigationController
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigationController else { return false }
        return navigationController.viewControllers.count > 1 && navigationController.transitionCoordinator == nil
    }
}
#endif
