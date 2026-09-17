#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import UIKit

/// How a product card is laid out where it is shown — what the app is told
/// when it draws the card itself.
public enum TalqynProductCardLayout: Sendable {
    /// Image on the left, details on the right, the full width of the
    /// transcript: a product cited in the text.
    case horizontal
    /// Image over the details: a tile in the carousel under the answer, or
    /// one of a pair of products cited by one sentence.
    case vertical
}

/// The score, the stars, and the review count — or "no reviews".
final class TalqynRatingView: UIView {
    private let scoreLabel = UILabel()
    private let starsStack = UIStackView()
    private let reviewsLabel = UILabel()
    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let scoreFormatter: NumberFormatter
    private var stars: [UIImageView] = []
    private var heightConstraint: NSLayoutConstraint?

    init(theme: TalqynTheme, strings: TalqynUIStrings) {
        self.theme = theme
        self.strings = strings
        // The score is written the way the copy's language writes a number:
        // `4,8` on a Russian screen, whatever the phone is set to.
        scoreFormatter = NumberFormatter()
        scoreFormatter.numberStyle = .decimal
        scoreFormatter.locale = strings.locale
        scoreFormatter.minimumFractionDigits = 1
        scoreFormatter.maximumFractionDigits = 1
        super.init(frame: .zero)
        scoreLabel.font = theme.fonts.captionBold
        scoreLabel.textColor = theme.colors.textSecondary
        scoreLabel.adjustsFontForContentSizeCategory = true
        reviewsLabel.font = theme.fonts.caption
        reviewsLabel.textColor = theme.colors.textTertiary
        reviewsLabel.adjustsFontForContentSizeCategory = true

        stars = (0..<5).map { _ in
            let view = UIImageView()
            view.tintColor = theme.colors.rating
            view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            view.contentMode = .scaleAspectFit
            view.talqynSize(CGSize(width: 11, height: 12))
            return view
        }
        starsStack.axis = .horizontal
        starsStack.spacing = 1
        stars.forEach { starsStack.addArrangedSubview($0) }

        let stack = UIStackView(arrangedSubviews: [scoreLabel, starsStack, reviewsLabel])
        stack.spacing = 4
        stack.alignment = .center
        stack.setCustomSpacing(6, after: starsStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        heightConstraint = talqynHeight(rowHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Tall enough for the stars at the design size, and for the text when
    /// the type is larger.
    private var rowHeight: CGFloat {
        max(18, ceil(theme.fonts.captionBold.lineHeight))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            heightConstraint?.constant = rowHeight
        }
    }

    func configure(rating: Double?, reviews: Int) {
        let hasRating = (rating ?? 0) > 0 && reviews > 0
        scoreLabel.text = scoreFormatter.string(from: NSNumber(value: rating ?? 0))
        scoreLabel.talqynSetHidden(!hasRating)
        starsStack.talqynSetHidden(!hasRating)
        let filled = Int((rating ?? 0).rounded())
        for (index, star) in stars.enumerated() {
            star.image = index < filled ? theme.icons.ratingStarFilled : theme.icons.ratingStar
        }
        reviewsLabel.text = hasRating ? "(\(reviews))" : strings.noReviews
    }
}

/// A product card: a horizontal row for a citation, a compact tile for the
/// carousel under a turn, a flexible tile for a pair of cited products side
/// by side.
///
/// A product the response marked as out of stock is dimmed and says so
/// under the price; a product the response said nothing about is shown as
/// usual.
final class TalqynProductCardView: TalqynTappableView, TalqynProductCard {
    enum Layout {
        /// Image on the left, details on the right. Full width.
        case row
        /// Image over details, at the carousel's fixed width.
        case compact
        /// Image over details, as wide as its container allows.
        case tile

        /// What the app is told: the carousel tile and the tile of a pair
        /// are both vertical.
        var orientation: TalqynProductCardLayout {
            self == .row ? .horizontal : .vertical
        }
    }

    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let price: TalqynPriceFormatter
    let layout: Layout

    private let imageView = TalqynRemoteImageView()
    private let titleLabel = UILabel()
    private let ratingView: TalqynRatingView
    private let priceLabel = UILabel()
    private let oldPriceLabel = UILabel()
    private let priceRow = UIStackView()
    private let priceSpacer = UIView()
    private let stockLabel = UILabel()
    private var compactWidth: NSLayoutConstraint?

    private(set) var product: TalqynProduct?

    init(theme: TalqynTheme, strings: TalqynUIStrings, price: TalqynPriceFormatter, layout: Layout) {
        self.theme = theme
        self.strings = strings
        self.price = price
        self.layout = layout
        ratingView = TalqynRatingView(theme: theme, strings: strings)
        super.init(frame: .zero)
        configureUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            layoutPriceRow()
            compactWidth?.constant = Self.compactWidth(theme)
        }
    }

    /// The carousel tile grows with the type, so a title keeps about as
    /// many words per line as it has at the design size.
    static func compactWidth(_ theme: TalqynTheme) -> CGFloat {
        ceil(theme.metrics.compactCardWidth * theme.fonts.currentScale)
    }

    /// The old price sits next to the price, and under it in a narrow tile
    /// once the type is large enough that the two no longer fit — a price
    /// must never be cut short.
    private func layoutPriceRow() {
        let stacked = layout != .row && theme.fonts.currentScale >= 1.3
        priceRow.axis = stacked ? .vertical : .horizontal
        priceRow.alignment = stacked ? .leading : .firstBaseline
        priceRow.spacing = stacked ? 0 : 6
        priceSpacer.isHidden = stacked
    }

    func configure(product: TalqynProduct, loader: TalqynImageLoading) {
        self.product = product
        imageView.setImage(url: product.imageURL, loader: loader)
        titleLabel.text = product.title
        ratingView.configure(rating: product.rating, reviews: product.reviewsCount)

        let hasPrice = (product.price ?? 0) > 0
        priceLabel.talqynSetHidden(!hasPrice)
        priceLabel.text = product.price.map(price.format)

        let hasOldPrice = product.hasDiscount
        oldPriceLabel.talqynSetHidden(!hasOldPrice)
        if hasOldPrice, let before = product.priceBefore {
            oldPriceLabel.attributedText = NSAttributedString(
                string: price.format(before),
                attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
            )
        }

        let isOutOfStock = product.inStock == false
        stockLabel.talqynSetHidden(!isOutOfStock)
        imageView.alpha = isOutOfStock ? 0.45 : 1
        titleLabel.textColor = isOutOfStock ? theme.colors.textTertiary : theme.colors.textSecondary
        priceLabel.textColor = isOutOfStock ? theme.colors.textTertiary : theme.colors.textPrimary

        isAccessibilityElement = true
        accessibilityTraits = .button
        var parts = [product.title]
        if hasPrice, let current = product.price { parts.append(price.format(current)) }
        if isOutOfStock { parts.append(strings.outOfStock) }
        accessibilityLabel = parts.joined(separator: ", ")
    }

    private func configureUI() {
        backgroundColor = theme.colors.surface
        talqynRound(theme.metrics.cardRadius)

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = theme.colors.surfaceSecondary
        imageView.talqynRound(theme.metrics.cardRadius)
        imageView.setPlaceholder(theme.icons.imagePlaceholder, tint: theme.colors.textTertiary)

        let isRow = layout == .row
        titleLabel.font = isRow ? theme.fonts.callout : theme.fonts.caption
        titleLabel.textColor = theme.colors.textSecondary
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        priceLabel.font = isRow ? theme.fonts.headline : theme.fonts.label
        priceLabel.textColor = theme.colors.textPrimary
        priceLabel.adjustsFontForContentSizeCategory = true
        oldPriceLabel.font = isRow ? theme.fonts.footnote : theme.fonts.caption
        oldPriceLabel.textColor = theme.colors.textTertiary
        oldPriceLabel.adjustsFontForContentSizeCategory = true
        stockLabel.font = theme.fonts.captionBold
        stockLabel.textColor = theme.colors.textSecondary
        stockLabel.text = strings.outOfStock
        stockLabel.numberOfLines = 0
        stockLabel.adjustsFontForContentSizeCategory = true
        stockLabel.isHidden = true

        priceSpacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        [priceLabel, oldPriceLabel, priceSpacer].forEach { priceRow.addArrangedSubview($0) }
        layoutPriceRow()

        let details = UIStackView.talqynVertical(
            [titleLabel, ratingView, priceRow, stockLabel], spacing: isRow ? 4 : 6
        )

        let content = UIStackView(arrangedSubviews: [imageView, details])
        switch layout {
        case .row:
            content.axis = .horizontal
            content.spacing = 10
            content.alignment = .top
            imageView.talqynSize(theme.metrics.rowCardImageSize)
        case .compact:
            content.axis = .vertical
            content.spacing = 6
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor).isActive = true
            translatesAutoresizingMaskIntoConstraints = false
            let width = widthAnchor.constraint(equalToConstant: Self.compactWidth(theme))
            width.isActive = true
            compactWidth = width
        case .tile:
            content.axis = .vertical
            content.spacing = 6
            // Two tiles side by side must not cost more height than two
            // rows: the image is a row's image, not a full-width square.
            // Tiles in a pair are stretched to one height; the slack goes
            // between the price and the app's controls, so titles line up
            // at the top and the buttons at the bottom.
            imageView.talqynHeight(96)
            let slack = UIView()
            slack.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
            details.insertArrangedSubview(slack, at: details.arrangedSubviews.count - 1)
        }
        talqynPin(content, insets: UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))
    }
}

/// A product's card in the transcript, whichever side drew it: the SDK's own
/// card, or the app's view in the SDK's tappable frame. The transcript
/// treats both the same — keyed by product for reuse, told apart by layout,
/// opened by ``onTap``.
@MainActor
protocol TalqynProductCard: UIView {
    var product: TalqynProduct? { get }
    var layout: TalqynProductCardView.Layout { get }
    var onTap: (() -> Void)? { get set }
}

/// The app's card in the SDK's frame. Tappable like the SDK's own card, so
/// the click is reported and the product opened the same way; sized by the
/// transcript, so the app's view only has to fill it.
///
/// The frame draws nothing — no background, no rounding, no clipping — so
/// the view's own corners and shadow are what the shopper sees. The view is
/// also what VoiceOver sees: the frame is not an accessibility element.
final class TalqynAppProductCardView: TalqynTappableView, TalqynProductCard {
    let layout: TalqynProductCardView.Layout
    private(set) var product: TalqynProduct?
    private let theme: TalqynTheme
    private var compactWidth: NSLayoutConstraint?

    init(theme: TalqynTheme, layout: TalqynProductCardView.Layout) {
        self.theme = theme
        self.layout = layout
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if layout == .compact {
            // The SDK's tile width, unless the app's view fixes its own: a
            // required width of theirs wins over this one without a fight.
            let width = widthAnchor.constraint(equalToConstant: TalqynProductCardView.compactWidth(theme))
            width.priority = UILayoutPriority(rawValue: 999)
            width.isActive = true
            compactWidth = width
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            compactWidth?.constant = TalqynProductCardView.compactWidth(theme)
        }
    }

    /// Puts the app's view for `product` in the frame, replacing the one
    /// there.
    func configure(product: TalqynProduct, view: UIView) {
        self.product = product
        guard view.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        talqynPin(view)
    }
}

/// Where a product's card comes from: the app, when its delegate draws one
/// for the product, otherwise the SDK. A product's previous card is reused
/// when it is of the same kind and layout; the app's view is asked for
/// again each time, so it never shows stale state.
@MainActor
struct TalqynProductCardFactory {
    let theme: TalqynTheme
    let strings: TalqynUIStrings
    let price: TalqynPriceFormatter
    let loader: TalqynImageLoading
    /// The app's card for a product, or `nil` for the SDK's.
    let appCard: (TalqynProduct, TalqynProductCardLayout) -> UIView?

    /// - Parameter previous: The card the product had, if any; reused when
    ///   it fits.
    func card(
        for product: TalqynProduct, layout: TalqynProductCardView.Layout, reusing previous: TalqynProductCard?
    ) -> TalqynProductCard {
        let previous = previous?.layout == layout ? previous : nil
        if let view = appCard(product, layout.orientation) {
            let host = (previous as? TalqynAppProductCardView) ?? TalqynAppProductCardView(theme: theme, layout: layout)
            host.configure(product: product, view: view)
            return host
        }
        let card = (previous as? TalqynProductCardView)
            ?? TalqynProductCardView(theme: theme, strings: strings, price: price, layout: layout)
        card.configure(product: product, loader: loader)
        return card
    }
}

/// A horizontally scrolling row of compact cards, starting at the transcript's
/// margin so the first card lines up with the text above it.
final class TalqynCompactProductRowView: UIView {
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var cards: [(view: TalqynProductCard, id: Int)] = []

    init(theme: TalqynTheme) {
        super.init(frame: .zero)
        let margin = theme.metrics.horizontalMargin
        scrollView.showsHorizontalScrollIndicator = false
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .top
        talqynPin(scrollView)
        scrollView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: margin),
            scrollView.contentLayoutGuide.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: margin),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        products: [TalqynProduct],
        cards factory: TalqynProductCardFactory,
        onTap: @escaping (TalqynProduct) -> Void
    ) {
        var reusable: [Int: TalqynProductCard] = [:]
        for card in cards { reusable[card.id] = card.view }
        stack.talqynRemoveAllArranged()
        cards = products.map { product in
            let card = factory.card(for: product, layout: .compact, reusing: reusable[product.talqynID])
            card.onTap = { onTap(product) }
            return (card, product.talqynID)
        }
        cards.forEach { stack.addArrangedSubview($0.view) }
    }
}

/// Titled carousels: the products a turn found beyond the ones cited inline,
/// one carousel per group of a multi-step plan.
final class TalqynProductListView: UIView {
    struct Section {
        var title: String
        var products: [TalqynProduct]
    }

    private let theme: TalqynTheme
    private let stack = UIStackView.talqynVertical(spacing: 16)
    private var sectionViews: [(header: UILabel, row: TalqynCompactProductRowView)] = []

    init(theme: TalqynTheme) {
        self.theme = theme
        super.init(frame: .zero)
        talqynPin(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        sections: [Section],
        cards: TalqynProductCardFactory,
        onTap: @escaping (TalqynProduct) -> Void
    ) {
        talqynSetHidden(sections.isEmpty)
        guard !sections.isEmpty else {
            reset()
            return
        }
        if sectionViews.count != sections.count {
            reset()
            sections.forEach { _ in addSection() }
        }
        for (index, section) in sections.enumerated() {
            sectionViews[index].header.text = section.title
            sectionViews[index].row.configure(products: section.products, cards: cards, onTap: onTap)
        }
    }

    private func reset() {
        stack.talqynRemoveAllArranged()
        sectionViews = []
    }

    private func addSection() {
        let header = UILabel()
        header.font = theme.fonts.captionBold
        header.textColor = theme.colors.textSecondary
        header.numberOfLines = 0
        header.adjustsFontForContentSizeCategory = true
        let headerContainer = UIStackView.talqynVertical(
            [header], spacing: 0, horizontalMargin: theme.metrics.horizontalMargin
        )
        let row = TalqynCompactProductRowView(theme: theme)
        let container = UIStackView.talqynVertical([headerContainer, row], spacing: 8)
        stack.addArrangedSubview(container)
        sectionViews.append((header, row))
    }
}
#endif
