#if os(iOS)
import SwiftUI
import TalqynConsultantCore
import TalqynSDK
import UIKit

/// The consultant screen in a SwiftUI hierarchy.
///
/// The same screen as ``TalqynConsultantViewController``, with the delegate's
/// calls as closures. The conversation is the view's to own — keep it in a
/// `@StateObject`, so the transcript survives the view being rebuilt:
///
/// ```swift
/// struct ConsultantScreen: View {
///     @StateObject private var conversation = TalqynConversation(talqyn: .shared)
///     @EnvironmentObject private var router: Router
///
///     var body: some View {
///         TalqynConsultantView(
///             conversation: conversation,
///             theme: .brand,
///             onOpenProduct: { router.openProduct($0.externalID) },
///             onOpenSearch: { router.openSearch($0) },
///             onApplyFilters: { router.openListing(TalqynFullSearchQuery(criteria: $0)) }
///         )
///         .ignoresSafeArea(.container, edges: .bottom)
///     }
/// }
/// ```
///
/// `Talqyn.shared` above is the app's own static, not something the SDK ships:
/// a client needs a configuration, so there is no global one to hand out. So is
/// `.brand`: a ``TalqynTheme`` the app builds once. ``TalqynTheme/default``
/// is the one that needs no setup.
///
/// The screen draws its own bar. Inside a `NavigationStack`, either hide the
/// stack's bar for this destination or pass `showsHeader: false` and put
/// history and a new chat into your toolbar.
public struct TalqynConsultantView: UIViewControllerRepresentable {
    /// The app's own card for a product, or `nil` for the SDK's; see
    /// ``TalqynConsultantDelegate/consultant(_:cardViewFor:layout:)``.
    public typealias CardProvider = @MainActor (TalqynProduct, TalqynProductCardLayout) -> UIView?

    /// A rating the shopper gave; see
    /// ``TalqynConsultantDelegate/consultant(_:didRate:reasons:for:)``.
    public typealias RatingHandler = @MainActor (TalqynAnswerRating?, [TalqynFeedbackReason], TalqynAssistantTurn) -> Void

    private let conversation: TalqynConversation
    private let theme: TalqynTheme
    private let title: String?
    private let exampleQuestions: [String]?
    private let strings: TalqynUIStrings?
    private let priceFormatter: TalqynPriceFormatter
    private let imageLoader: TalqynImageLoading
    private let showsHeader: Bool
    private let showsPoweredBy: Bool
    fileprivate let onOpenProduct: @MainActor (TalqynProduct) -> Void
    fileprivate let onOpenSearch: @MainActor (String) -> Void
    fileprivate let onApplyFilters: @MainActor (TalqynFilterCriteria) -> Void
    fileprivate let onRate: RatingHandler?
    fileprivate let cardView: CardProvider?

    /// Creates the screen.
    ///
    /// - Parameters:
    ///   - conversation: The conversation to show. Own it with `@StateObject`.
    ///   - theme: Colors, fonts, icons, and metrics.
    ///   - title: What the screen calls itself. `nil` keeps the copy's name.
    ///   - exampleQuestions: The chips on an empty screen. `nil` keeps the
    ///     copy's own; an empty array shows none.
    ///   - strings: Copy. `nil` follows the client's locale.
    ///   - priceFormatter: How prices are written.
    ///   - imageLoader: Loads product images. Defaults to
    ///     ``TalqynURLImageLoader/shared``, whose cache every screen shares.
    ///   - showsHeader: Whether the screen draws its own bar.
    ///   - showsPoweredBy: Whether the empty screen carries "Powered by Talqyn".
    ///   - onOpenProduct: A product card or a product's name was tapped.
    ///   - onOpenSearch: The consultant sent the question to search.
    ///   - onApplyFilters: The consultant proposed a filtered listing.
    ///   - onRate: The shopper rated a turn — for the app's own analytics.
    ///   - cardView: The app's own product card.
    public init(
        conversation: TalqynConversation,
        theme: TalqynTheme = .default,
        title: String? = nil,
        exampleQuestions: [String]? = nil,
        strings: TalqynUIStrings? = nil,
        priceFormatter: TalqynPriceFormatter = .tenge,
        imageLoader: TalqynImageLoading = TalqynURLImageLoader.shared,
        showsHeader: Bool = true,
        showsPoweredBy: Bool = true,
        onOpenProduct: @escaping @MainActor (TalqynProduct) -> Void,
        onOpenSearch: @escaping @MainActor (String) -> Void,
        onApplyFilters: @escaping @MainActor (TalqynFilterCriteria) -> Void,
        onRate: RatingHandler? = nil,
        cardView: CardProvider? = nil
    ) {
        self.conversation = conversation
        self.theme = theme
        self.title = title
        self.exampleQuestions = exampleQuestions
        self.strings = strings
        self.priceFormatter = priceFormatter
        self.imageLoader = imageLoader
        self.showsHeader = showsHeader
        self.showsPoweredBy = showsPoweredBy
        self.onOpenProduct = onOpenProduct
        self.onOpenSearch = onOpenSearch
        self.onApplyFilters = onApplyFilters
        self.onRate = onRate
        self.cardView = cardView
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeUIViewController(context: Context) -> TalqynConsultantViewController {
        let controller = TalqynConsultantViewController(
            conversation: conversation,
            theme: theme,
            title: title,
            exampleQuestions: exampleQuestions,
            strings: strings,
            priceFormatter: priceFormatter,
            imageLoader: imageLoader,
            showsHeader: showsHeader,
            showsPoweredBy: showsPoweredBy
        )
        controller.delegate = context.coordinator
        return controller
    }

    /// The screen is built once; a rebuilt view hands the coordinator its
    /// fresh closures, which is what a SwiftUI parent changes between renders.
    public func updateUIViewController(_ controller: TalqynConsultantViewController, context: Context) {
        context.coordinator.view = self
    }

    /// Forwards the screen's delegate calls to the view's closures.
    @MainActor
    public final class Coordinator: TalqynConsultantDelegate {
        fileprivate var view: TalqynConsultantView

        fileprivate init(_ view: TalqynConsultantView) {
            self.view = view
        }

        public func consultant(_ controller: TalqynConsultantViewController, openProduct product: TalqynProduct) {
            view.onOpenProduct(product)
        }

        public func consultant(_ controller: TalqynConsultantViewController, openSearch query: String) {
            view.onOpenSearch(query)
        }

        public func consultant(_ controller: TalqynConsultantViewController, applyFilters criteria: TalqynFilterCriteria) {
            view.onApplyFilters(criteria)
        }

        public func consultant(
            _ controller: TalqynConsultantViewController,
            cardViewFor product: TalqynProduct,
            layout: TalqynProductCardLayout
        ) -> UIView? {
            view.cardView?(product, layout)
        }

        public func consultant(
            _ controller: TalqynConsultantViewController,
            didRate rating: TalqynAnswerRating?,
            reasons: [TalqynFeedbackReason],
            for turn: TalqynAssistantTurn
        ) {
            view.onRate?(rating, reasons, turn)
        }
    }
}
#endif
