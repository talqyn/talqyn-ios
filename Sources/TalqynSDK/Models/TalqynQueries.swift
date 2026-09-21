import Foundation

/// A request for instant search (`POST /v1/search/`).
///
/// Fields left `nil` are filled from ``TalqynConfiguration`` — locale, place,
/// and A/B bucket. A value set here always wins.
public struct TalqynSearchQuery: Sendable, Equatable {
    /// What the shopper typed. 1–500 characters, non-empty after trimming.
    public var query: String

    /// The language to search in. `nil` uses the client default.
    public var locale: TalqynLocale?

    /// How many products to return. 1–50.
    public var limit: Int

    /// Restricts results to one category.
    public var categoryID: Int?

    /// Restricts results to one brand.
    public var brandID: Int?

    /// The lower price bound. Must not exceed ``priceMax``.
    public var priceMin: Double?

    /// The upper price bound.
    public var priceMax: Double?

    /// Whether to drop out-of-stock products.
    public var inStockOnly: Bool

    /// The shopper's city — the `id` of an option in the `city` group of
    /// ``TalqynSearchAPI/filters(_:)``.
    ///
    /// An unknown id is not an error: results quietly narrow to "available
    /// everywhere".
    public var cityID: String?

    /// The shopper's store — the `id` of an option in the `location` group.
    /// Takes precedence over ``cityID``.
    public var locationID: String?

    /// The storefront's A/B bucket: echoed into analytics, no effect on results.
    public var variant: String?

    /// Creates an instant-search request.
    ///
    /// - Parameters:
    ///   - query: What the shopper typed.
    ///   - locale: The language to search in. `nil` uses the client default.
    ///   - limit: How many products to return, 1–50.
    ///   - categoryID: Restricts results to one category.
    ///   - brandID: Restricts results to one brand.
    ///   - priceMin: The lower price bound.
    ///   - priceMax: The upper price bound.
    ///   - inStockOnly: Whether to drop out-of-stock products.
    ///   - cityID: The shopper's city, in your catalog's numbering.
    ///   - locationID: The shopper's store, in your catalog's numbering.
    ///   - variant: The storefront's A/B bucket.
    public init(
        query: String,
        locale: TalqynLocale? = nil,
        limit: Int = 20,
        categoryID: Int? = nil,
        brandID: Int? = nil,
        priceMin: Double? = nil,
        priceMax: Double? = nil,
        inStockOnly: Bool = false,
        cityID: String? = nil,
        locationID: String? = nil,
        variant: String? = nil
    ) {
        self.query = query
        self.locale = locale
        self.limit = limit
        self.categoryID = categoryID
        self.brandID = brandID
        self.priceMin = priceMin
        self.priceMax = priceMax
        self.inStockOnly = inStockOnly
        self.cityID = cityID
        self.locationID = locationID
        self.variant = variant
    }
}

extension TalqynSearchQuery: Encodable {
    private enum CodingKeys: String, CodingKey {
        case query, locale, limit
        case categoryID = "category_id"
        case brandID = "brand_id"
        case priceMin = "price_min"
        case priceMax = "price_max"
        case inStockOnly = "in_stock_only"
        case cityID = "city_id"
        case locationID = "location_id"
        case variant
    }

    /// Encodes the request, omitting every field left unset.
    ///
    /// - Parameter encoder: The encoder to write into.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(query, forKey: .query)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encode(limit, forKey: .limit)
        try container.encodeIfPresent(categoryID, forKey: .categoryID)
        try container.encodeIfPresent(brandID, forKey: .brandID)
        try container.encodeIfPresent(priceMin, forKey: .priceMin)
        try container.encodeIfPresent(priceMax, forKey: .priceMax)
        try container.encode(inStockOnly, forKey: .inStockOnly)
        try container.encodeIfPresent(cityID, forKey: .cityID)
        try container.encodeIfPresent(locationID, forKey: .locationID)
        try container.encodeIfPresent(variant, forKey: .variant)
    }
}

/// A request for the start screen (`POST /v1/search/start`): what to show under
/// an **empty** search field.
///
/// There is no `query` property, and that is the point — an empty query is not a
/// query. It has neither a vector nor a prefix, so ranking, completions, and
/// correction are all off, and the response carries popularity rather than
/// relevance. Hence its own endpoint and its own request.
///
/// Fields left `nil` are filled from ``TalqynConfiguration`` — locale, place, and
/// A/B bucket.
public struct TalqynStartQuery: Sendable, Equatable {
    /// The language to build the screen in. `nil` uses the client default.
    public var locale: TalqynLocale?

    /// How many products to return. 1–50.
    ///
    /// Applies to ``TalqynStartResponse/products`` only: the other blocks are
    /// fixed in size by the server — 5 past queries, 8 popular ones, 8
    /// categories.
    public var limit: Int

    /// The shopper's city — the `id` of an option in the `city` group of
    /// ``TalqynSearchAPI/filters(_:)``.
    ///
    /// Products unavailable there are left out of the block rather than shown as
    /// out of stock.
    public var cityID: String?

    /// The shopper's store — the `id` of an option in the `location` group.
    /// Takes precedence over ``cityID``.
    public var locationID: String?

    /// The storefront's A/B bucket: echoed into analytics, no effect on the
    /// screen.
    public var variant: String?

    /// Creates a start-screen request.
    ///
    /// - Parameters:
    ///   - locale: The language to build the screen in. `nil` uses the client
    ///     default.
    ///   - limit: How many products to return, 1–50.
    ///   - cityID: The shopper's city, in your catalog's numbering.
    ///   - locationID: The shopper's store, in your catalog's numbering.
    ///   - variant: The storefront's A/B bucket.
    public init(
        locale: TalqynLocale? = nil,
        limit: Int = 10,
        cityID: String? = nil,
        locationID: String? = nil,
        variant: String? = nil
    ) {
        self.locale = locale
        self.limit = limit
        self.cityID = cityID
        self.locationID = locationID
        self.variant = variant
    }
}

extension TalqynStartQuery: Encodable {
    private enum CodingKeys: String, CodingKey {
        case locale, limit, variant
        case cityID = "city_id"
        case locationID = "location_id"
    }

    /// Encodes the request, omitting every field left unset.
    ///
    /// - Parameter encoder: The encoder to write into.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encode(limit, forKey: .limit)
        try container.encodeIfPresent(cityID, forKey: .cityID)
        try container.encodeIfPresent(locationID, forKey: .locationID)
        try container.encodeIfPresent(variant, forKey: .variant)
    }
}

/// The selection criteria shared by a listing and its filter panel.
///
/// They are shared on the server too: `/v1/search/full` and `/v1/search/filters`
/// accept one body, and the two must not drift — a panel has to count against
/// the same selection the listing displays.
public struct TalqynFilterCriteria: Sendable, Equatable {
    /// What the shopper typed. 1–500 characters.
    public var query: String

    /// The language to search in. `nil` uses the client default.
    public var locale: TalqynLocale?

    /// Restricts results to one category.
    public var categoryID: Int?

    /// Restricts results to one brand.
    public var brandID: Int?

    /// The lower price bound.
    public var priceMin: Double?

    /// The upper price bound.
    public var priceMax: Double?

    /// Whether to drop out-of-stock products.
    public var inStockOnly: Bool

    /// Whether to keep only discounted products.
    public var hasDiscount: Bool

    /// Structural filters: `[group slug: [value slugs]]`.
    ///
    /// OR within a group, AND across groups. Slugs come from
    /// ``TalqynSearchAPI/filters(_:)``. The contract caps this at 20 keys, 50
    /// values per key, and 100 characters per value.
    public var filters: [String: [String]]

    /// The shopper's city, in your catalog's numbering.
    public var cityID: String?

    /// The shopper's store, in your catalog's numbering. Beats ``cityID``.
    public var locationID: String?

    /// Creates a set of selection criteria.
    ///
    /// - Parameters:
    ///   - query: What the shopper typed.
    ///   - locale: The language to search in. `nil` uses the client default.
    ///   - categoryID: Restricts results to one category.
    ///   - brandID: Restricts results to one brand.
    ///   - priceMin: The lower price bound.
    ///   - priceMax: The upper price bound.
    ///   - inStockOnly: Whether to drop out-of-stock products.
    ///   - hasDiscount: Whether to keep only discounted products.
    ///   - filters: Structural filters keyed by group slug.
    ///   - cityID: The shopper's city, in your catalog's numbering.
    ///   - locationID: The shopper's store, in your catalog's numbering.
    public init(
        query: String,
        locale: TalqynLocale? = nil,
        categoryID: Int? = nil,
        brandID: Int? = nil,
        priceMin: Double? = nil,
        priceMax: Double? = nil,
        inStockOnly: Bool = false,
        hasDiscount: Bool = false,
        filters: [String: [String]] = [:],
        cityID: String? = nil,
        locationID: String? = nil
    ) {
        self.query = query
        self.locale = locale
        self.categoryID = categoryID
        self.brandID = brandID
        self.priceMin = priceMin
        self.priceMax = priceMax
        self.inStockOnly = inStockOnly
        self.hasDiscount = hasDiscount
        self.filters = filters
        self.cityID = cityID
        self.locationID = locationID
    }

    enum CodingKeys: String, CodingKey {
        case query, locale
        case categoryID = "category_id"
        case brandID = "brand_id"
        case priceMin = "price_min"
        case priceMax = "price_max"
        case inStockOnly = "in_stock_only"
        case hasDiscount = "has_discount"
        case filters
        case cityID = "city_id"
        case locationID = "location_id"
    }

    func encode(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(query, forKey: .query)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encodeIfPresent(categoryID, forKey: .categoryID)
        try container.encodeIfPresent(brandID, forKey: .brandID)
        try container.encodeIfPresent(priceMin, forKey: .priceMin)
        try container.encodeIfPresent(priceMax, forKey: .priceMax)
        try container.encode(inStockOnly, forKey: .inStockOnly)
        try container.encode(hasDiscount, forKey: .hasDiscount)
        if !filters.isEmpty {
            try container.encode(filters, forKey: .filters)
        }
        try container.encodeIfPresent(cityID, forKey: .cityID)
        try container.encodeIfPresent(locationID, forKey: .locationID)
    }
}

/// A request for one page of a listing (`POST /v1/search/full`).
public struct TalqynFullSearchQuery: Sendable, Equatable {
    /// What to select.
    public var criteria: TalqynFilterCriteria

    /// The page size. 1–100.
    public var limit: Int

    /// Where the page starts. 0–10000.
    public var offset: Int

    /// How to order the page.
    public var sort: TalqynSort

    /// The storefront's A/B bucket.
    public var variant: String?

    /// Creates a listing request from a prepared set of criteria.
    ///
    /// - Parameters:
    ///   - criteria: What to select.
    ///   - limit: The page size, 1–100.
    ///   - offset: Where the page starts, 0–10000.
    ///   - sort: How to order the page.
    ///   - variant: The storefront's A/B bucket.
    public init(
        criteria: TalqynFilterCriteria,
        limit: Int = 20,
        offset: Int = 0,
        sort: TalqynSort = .relevance,
        variant: String? = nil
    ) {
        self.criteria = criteria
        self.limit = limit
        self.offset = offset
        self.sort = sort
        self.variant = variant
    }

    /// Creates a listing request field by field.
    ///
    /// - Parameters:
    ///   - query: What the shopper typed.
    ///   - locale: The language to search in. `nil` uses the client default.
    ///   - limit: The page size, 1–100.
    ///   - offset: Where the page starts, 0–10000.
    ///   - sort: How to order the page.
    ///   - filters: Structural filters keyed by group slug.
    ///   - categoryID: Restricts results to one category.
    ///   - brandID: Restricts results to one brand.
    ///   - priceMin: The lower price bound.
    ///   - priceMax: The upper price bound.
    ///   - inStockOnly: Whether to drop out-of-stock products.
    ///   - hasDiscount: Whether to keep only discounted products.
    ///   - cityID: The shopper's city, in your catalog's numbering.
    ///   - locationID: The shopper's store, in your catalog's numbering.
    ///   - variant: The storefront's A/B bucket.
    public init(
        query: String,
        locale: TalqynLocale? = nil,
        limit: Int = 20,
        offset: Int = 0,
        sort: TalqynSort = .relevance,
        filters: [String: [String]] = [:],
        categoryID: Int? = nil,
        brandID: Int? = nil,
        priceMin: Double? = nil,
        priceMax: Double? = nil,
        inStockOnly: Bool = false,
        hasDiscount: Bool = false,
        cityID: String? = nil,
        locationID: String? = nil,
        variant: String? = nil
    ) {
        self.init(
            criteria: TalqynFilterCriteria(
                query: query,
                locale: locale,
                categoryID: categoryID,
                brandID: brandID,
                priceMin: priceMin,
                priceMax: priceMax,
                inStockOnly: inStockOnly,
                hasDiscount: hasDiscount,
                filters: filters,
                cityID: cityID,
                locationID: locationID
            ),
            limit: limit,
            offset: offset,
            sort: sort,
            variant: variant
        )
    }

    /// The same selection, shaped as a filter-panel request.
    ///
    /// Recomputing the criteria by hand for the second call is how a panel ends
    /// up counting against a different selection than the one on screen.
    public var filtersQuery: TalqynFiltersQuery {
        TalqynFiltersQuery(criteria: criteria)
    }

    /// Returns this request advanced to the next page.
    ///
    /// - Parameter response: The page that just came back.
    /// - Returns: A copy positioned at the next offset, or `nil` when the
    ///   listing is exhausted.
    public func nextPage(after response: TalqynFullSearchResponse) -> TalqynFullSearchQuery? {
        guard let offset = response.nextOffset else { return nil }
        var next = self
        next.offset = offset
        return next
    }
}

extension TalqynFullSearchQuery: Encodable {
    private enum ExtraKeys: String, CodingKey {
        case limit, offset, sort, variant
    }

    /// Encodes the request, omitting unset fields and an empty `filters`.
    ///
    /// - Parameter encoder: The encoder to write into.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TalqynFilterCriteria.CodingKeys.self)
        try criteria.encode(into: &container)
        var extra = encoder.container(keyedBy: ExtraKeys.self)
        try extra.encode(limit, forKey: .limit)
        try extra.encode(offset, forKey: .offset)
        try extra.encode(sort, forKey: .sort)
        try extra.encodeIfPresent(variant, forKey: .variant)
    }
}

/// A request for facet counts (`POST /v1/search/filters`).
///
/// The same body as a listing request, minus paging and ordering: the panel
/// counts across the whole selection, not one page of it.
public struct TalqynFiltersQuery: Sendable, Equatable {
    /// What to count against.
    public var criteria: TalqynFilterCriteria

    /// Creates a facet request from a prepared set of criteria.
    ///
    /// - Parameter criteria: What to count against.
    public init(criteria: TalqynFilterCriteria) {
        self.criteria = criteria
    }

    /// Creates a facet request field by field.
    ///
    /// - Parameters:
    ///   - query: What the shopper typed.
    ///   - locale: The language to count in. `nil` uses the client default.
    ///   - filters: Structural filters already applied, keyed by group slug.
    ///   - categoryID: Restricts counts to one category.
    ///   - brandID: Restricts counts to one brand.
    ///   - priceMin: The lower price bound.
    ///   - priceMax: The upper price bound.
    ///   - inStockOnly: Whether to drop out-of-stock products.
    ///   - hasDiscount: Whether to keep only discounted products.
    ///   - cityID: The shopper's city, in your catalog's numbering.
    ///   - locationID: The shopper's store, in your catalog's numbering.
    public init(
        query: String,
        locale: TalqynLocale? = nil,
        filters: [String: [String]] = [:],
        categoryID: Int? = nil,
        brandID: Int? = nil,
        priceMin: Double? = nil,
        priceMax: Double? = nil,
        inStockOnly: Bool = false,
        hasDiscount: Bool = false,
        cityID: String? = nil,
        locationID: String? = nil
    ) {
        self.init(criteria: TalqynFilterCriteria(
            query: query,
            locale: locale,
            categoryID: categoryID,
            brandID: brandID,
            priceMin: priceMin,
            priceMax: priceMax,
            inStockOnly: inStockOnly,
            hasDiscount: hasDiscount,
            filters: filters,
            cityID: cityID,
            locationID: locationID
        ))
    }
}

extension TalqynFiltersQuery: Encodable {
    /// Encodes the request, omitting unset fields and an empty `filters`.
    ///
    /// - Parameter encoder: The encoder to write into.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TalqynFilterCriteria.CodingKeys.self)
        try criteria.encode(into: &container)
    }
}

/// A question for the consultant (`POST /v1/consultant/ask`).
public struct TalqynConsultantQuery: Sendable, Equatable {
    /// The shopper's question. 1–2000 characters.
    public var question: String

    /// The language to answer in. `nil` uses the client default.
    public var locale: TalqynLocale?

    /// The session of the previous turn, from
    /// ``TalqynConsultantEvent/done(_:)``. Omit it to start a new conversation.
    public var sessionID: String?

    /// The shopper's city.
    ///
    /// - Important: Send it on **every** turn. A session does not remember a
    ///   place, because a shopper may change cities mid-conversation. The SDK
    ///   fills this from the client default when it is `nil`.
    public var cityID: String?

    /// The shopper's store. Sent per turn like ``cityID``, and takes precedence
    /// over it.
    public var locationID: String?

    /// The storefront's A/B bucket.
    public var variant: String?

    /// Creates a consultant request.
    ///
    /// - Parameters:
    ///   - question: The shopper's question, 1–2000 characters.
    ///   - locale: The language to answer in. `nil` uses the client default.
    ///   - sessionID: The session of the previous turn, to continue it.
    ///   - cityID: The shopper's city, in your catalog's numbering.
    ///   - locationID: The shopper's store, in your catalog's numbering.
    ///   - variant: The storefront's A/B bucket.
    public init(
        question: String,
        locale: TalqynLocale? = nil,
        sessionID: String? = nil,
        cityID: String? = nil,
        locationID: String? = nil,
        variant: String? = nil
    ) {
        self.question = question
        self.locale = locale
        self.sessionID = sessionID
        self.cityID = cityID
        self.locationID = locationID
        self.variant = variant
    }
}

extension TalqynConsultantQuery: Encodable {
    private enum CodingKeys: String, CodingKey {
        case question, locale, variant
        case sessionID = "session_id"
        case cityID = "city_id"
        case locationID = "location_id"
    }

    /// Encodes the request, omitting every field left unset.
    ///
    /// - Parameter encoder: The encoder to write into.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(question, forKey: .question)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(cityID, forKey: .cityID)
        try container.encodeIfPresent(locationID, forKey: .locationID)
        try container.encodeIfPresent(variant, forKey: .variant)
    }
}
