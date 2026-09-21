import Foundation

/// Where a shopper's action took place.
public enum TalqynEventSource: String, Sendable, Codable {
    /// The search field's dropdown.
    case instant
    /// A listing page.
    case full
    /// The consultant's results. Not valid for
    /// ``TalqynSearchSubmitEvent/source``.
    case consultant = "cip"
    /// The start screen of an empty search field — ``TalqynSearchAPI/start(_:)``.
    /// Not valid for ``TalqynSearchSubmitEvent/source``: the screen has no query
    /// to submit.
    ///
    /// A tap here is counted apart from the rest on purpose. The screen's own
    /// products come from the most-clicked list, so feeding these clicks back
    /// would let it rank itself; they stay out of search ranking entirely.
    case start
}

/// A shopper tapped a product card.
public struct TalqynProductClickEvent: Sendable, Equatable {
    /// The impression the click belongs to — ``TalqynSearchResponse/searchID``,
    /// ``TalqynFullSearchResponse/searchID``, ``TalqynStartResponse/searchID``,
    /// or ``TalqynConsultantProducts/searchID``.
    ///
    /// Without it a click has no denominator and click-through cannot be
    /// computed. A click from deep pagination legitimately arrives without one,
    /// since only the first page carries an id.
    public var searchID: String?

    /// Talqyn's internal product id — ``TalqynProduct/talqynID``, not your SKU.
    public var talqynID: Int

    /// The zero-based position in the results.
    ///
    /// For the consultant this is the index in the turn's flattened product
    /// list, exactly as the storefront rendered it.
    public var position: Int

    /// Where the click happened.
    public var source: TalqynEventSource

    /// The storefront's A/B bucket. Filled from the client default when `nil`.
    public var variant: String?

    /// Creates a product-click event.
    ///
    /// - Parameters:
    ///   - searchID: The impression the click belongs to.
    ///   - talqynID: Talqyn's internal product id.
    ///   - position: The zero-based position in the results.
    ///   - source: Where the click happened.
    ///   - variant: The storefront's A/B bucket.
    public init(
        searchID: String?,
        talqynID: Int,
        position: Int,
        source: TalqynEventSource,
        variant: String? = nil
    ) {
        self.searchID = searchID
        self.talqynID = talqynID
        self.position = position
        self.source = source
        self.variant = variant
    }
}

extension TalqynProductClickEvent: Encodable {
    private enum CodingKeys: String, CodingKey {
        case searchID = "search_id"
        case talqynID = "talqyn_id"
        case position, source, variant
    }

    /// Encodes the event, omitting every field left unset.
    ///
    /// - Parameter encoder: The encoder to write into.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(searchID, forKey: .searchID)
        try container.encode(talqynID, forKey: .talqynID)
        try container.encode(position, forKey: .position)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(variant, forKey: .variant)
    }
}

/// A shopper submitted a search query.
///
/// Not optional analytics: the `history` blocks of instant search and of the
/// start screen are assembled from these rows. A storefront running on a device
/// token has to report them itself — by definition there is no backend of yours
/// in the chain to do it.
public struct TalqynSearchSubmitEvent: Sendable, Equatable {
    /// The query as submitted. 1–500 characters.
    public var query: String

    /// Where it was submitted from. Only ``TalqynEventSource/instant`` and
    /// ``TalqynEventSource/full`` are accepted: a query picked on the start
    /// screen takes the source of the results it opens.
    public var source: TalqynEventSource

    /// The language searched in. Filled from the client default when `nil`.
    public var locale: TalqynLocale?

    /// How many results came back, if known.
    public var resultsCount: Int?

    /// The storefront's A/B bucket. Filled from the client default when `nil`.
    public var variant: String?

    /// Creates a search-submit event.
    ///
    /// - Parameters:
    ///   - query: The query as submitted.
    ///   - source: Where it was submitted from.
    ///   - locale: The language searched in.
    ///   - resultsCount: How many results came back.
    ///   - variant: The storefront's A/B bucket.
    public init(
        query: String,
        source: TalqynEventSource,
        locale: TalqynLocale? = nil,
        resultsCount: Int? = nil,
        variant: String? = nil
    ) {
        self.query = query
        self.source = source
        self.locale = locale
        self.resultsCount = resultsCount
        self.variant = variant
    }
}

extension TalqynSearchSubmitEvent: Encodable {
    private enum CodingKeys: String, CodingKey {
        case query, source, locale, variant
        case resultsCount = "results_count"
    }

    /// Encodes the event, omitting every field left unset.
    ///
    /// - Parameter encoder: The encoder to write into.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(query, forKey: .query)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encodeIfPresent(resultsCount, forKey: .resultsCount)
        try container.encodeIfPresent(variant, forKey: .variant)
    }
}

/// A shopper tapped a category — in a search response's navigation block or on
/// the start screen.
public struct TalqynCategoryClickEvent: Sendable, Equatable {
    /// The category tapped — ``TalqynCategory/id``.
    public var categoryID: Int

    /// The query whose results the category appeared in. `nil` on the start
    /// screen, which has no query.
    public var query: String?

    /// The storefront's A/B bucket. Filled from the client default when `nil`.
    public var variant: String?

    /// Creates a category-click event.
    ///
    /// - Parameters:
    ///   - categoryID: The category tapped.
    ///   - query: The query whose results it appeared in.
    ///   - variant: The storefront's A/B bucket.
    public init(categoryID: Int, query: String? = nil, variant: String? = nil) {
        self.categoryID = categoryID
        self.query = query
        self.variant = variant
    }
}

extension TalqynCategoryClickEvent: Encodable {
    private enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case query, variant
    }

    /// Encodes the event, omitting every field left unset.
    ///
    /// - Parameter encoder: The encoder to write into.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encodeIfPresent(query, forKey: .query)
        try container.encodeIfPresent(variant, forKey: .variant)
    }
}
