import Foundation

/// A query completion offered under the search field.
public struct TalqynSuggestion: Sendable, Equatable, Hashable {
    /// The suggested query text.
    public var text: String

    /// How heavily the suggestion is weighted in the corpus. Ordering is already
    /// applied by the server.
    public var weight: Int

    /// The character offset at which the suggestion diverges from what the
    /// shopper typed: everything before it is their input, everything after is
    /// the completion.
    public var highlightFrom: Int
}

extension TalqynSuggestion: Decodable {
    private enum CodingKeys: String, CodingKey {
        case text, weight
        case highlightFrom = "highlight_from"
    }

    /// Decodes a suggestion, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = container.value(.text, default: "")
        weight = container.value(.weight, default: 0)
        highlightFrom = container.value(.highlightFrom, default: 0)
    }
}

/// A facet chip offered under the search field.
public struct TalqynChip: Sendable, Equatable, Hashable {
    /// The chip label, also the text to search for when it is tapped.
    public var text: String

    /// How heavily the chip is weighted. Ordering is already applied by the
    /// server.
    public var weight: Int
}

extension TalqynChip: Decodable {
    private enum CodingKeys: String, CodingKey { case text, weight }

    /// Decodes a chip, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = container.value(.text, default: "")
        weight = container.value(.weight, default: 0)
    }
}

/// A category in the navigation block of a search response.
public struct TalqynCategory: Sendable, Equatable, Hashable, Identifiable {
    /// The category id, as accepted by the `categoryID` request parameter.
    public var id: Int

    /// The category name in the requested locale.
    public var name: String

    /// The category slug, when the catalog carries one.
    public var slug: String?

    /// The materialized tree path, for example `"1.42"`.
    public var path: String?

    /// The parent category's name, for disambiguating same-named leaves.
    public var parentName: String?
}

extension TalqynCategory: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, slug, path
        case parentName = "parent_name"
    }

    /// Decodes a category, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.value(.id, default: 0)
        name = container.value(.name, default: "")
        slug = container.optional(.slug)
        path = container.optional(.path)
        parentName = container.optional(.parentName)
    }
}

/// A brand in the navigation block of a search response.
public struct TalqynBrand: Sendable, Equatable, Hashable, Identifiable {
    /// The brand id, as accepted by the `brandID` request parameter.
    public var id: Int

    /// The brand's display name.
    public var name: String

    /// The brand slug, as accepted by `filters["brand"]` on a listing request.
    public var slug: String?

    /// The brand logo, or `nil` when the brand has none.
    public var logoURL: URL?
}

extension TalqynBrand: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, slug
        case logoURL = "logo_url"
    }

    /// Decodes a brand, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.value(.id, default: 0)
        name = container.value(.name, default: "")
        slug = container.optional(.slug)
        logoURL = TalqynProduct.url(container.optional(.logoURL))
    }
}

/// The result of `POST /v1/search/` — instant search for a search field with a
/// dropdown.
public struct TalqynSearchResponse: Sendable, Equatable {
    /// The impression id for this response.
    ///
    /// Send it back in ``TalqynProductClickEvent/searchID``: without it a click
    /// has no denominator and search click-through cannot be computed.
    public var searchID: String

    /// The query the results were produced for. Differs from what was sent when
    /// ``correctedFrom`` is set.
    public var query: String

    /// The locale the results were produced in, as its wire value.
    public var locale: String

    /// How many products matched in total, beyond the ones returned.
    public var total: Int

    /// The top matches, already ranked.
    public var results: [TalqynProduct]

    /// Query completions for the search field.
    public var suggestions: [TalqynSuggestion]

    /// Facet chips for the search field.
    public var chips: [TalqynChip]

    /// Editorial queries shown for an empty search field.
    ///
    /// - Important: These are **suggestions**, not products.
    public var showcase: [TalqynSuggestion]

    /// Categories worth navigating to for this query.
    public var categories: [TalqynCategory]

    /// Brands worth navigating to for this query.
    public var brands: [TalqynBrand]

    /// This shopper's earlier queries.
    ///
    /// Empty until the token names a shopper — not under
    /// ``TalqynDeviceIdentity/guest`` — and the storefront reports submitted
    /// queries through ``TalqynEventsAPI/searchSubmit(_:)``: the block is
    /// assembled from those very events.
    public var history: [String]

    /// The original text, when the server quietly searched for the top
    /// suggestion instead — a short or misspelled query.
    ///
    /// ``results`` already reflect the corrected text; show this to offer
    /// "search for … instead".
    public var correctedFrom: String?
}

extension TalqynSearchResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case searchID = "search_id"
        case query, locale, total, results, suggestions, chips, showcase, categories, brands, history
        case correctedFrom = "corrected_from"
    }

    /// Decodes an instant-search response, tolerating absent fields. A card
    /// that does not decode is dropped on its own; the rest of the list stays.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searchID = container.value(.searchID, default: "")
        query = container.value(.query, default: "")
        locale = container.value(.locale, default: TalqynLocale.en.rawValue)
        total = container.value(.total, default: 0)
        results = container.array(.results)
        suggestions = container.array(.suggestions)
        chips = container.array(.chips)
        showcase = container.array(.showcase)
        categories = container.array(.categories)
        brands = container.array(.brands)
        history = container.array(.history)
        correctedFrom = container.optional(.correctedFrom)
    }
}

/// The result of `POST /v1/search/start` — what to show under an **empty**
/// search field.
///
/// Four independent blocks; any of them can come back empty. Only ``products``
/// is ranked at all, and by popularity rather than relevance, which is why its
/// cards carry no ``TalqynProduct/score``.
public struct TalqynStartResponse: Sendable, Equatable {
    /// The impression id for this screen.
    ///
    /// Send it back in ``TalqynProductClickEvent/searchID`` with
    /// ``TalqynEventSource/start``: without it a card tap has no denominator and
    /// the screen's click-through cannot be computed.
    public var searchID: String

    /// The locale the screen was built in, as its wire value.
    public var locale: String

    /// This shopper's recent queries, most recently used first.
    ///
    /// Empty until the token names a shopper — not under
    /// ``TalqynDeviceIdentity/guest`` — and the storefront reports submitted
    /// queries through ``TalqynEventsAPI/searchSubmit(_:)``: the block is
    /// assembled from those very events.
    public var history: [String]

    /// What this storefront searches for, over the last 30 days.
    ///
    /// A freshly connected storefront has no traffic yet, so the block stands on
    /// the curated corpus until it does.
    public var popularQueries: [String]

    /// Root categories carrying live products, the largest first.
    ///
    /// Stock and place are not applied here — the listing behind a tap applies
    /// them itself.
    public var categories: [TalqynCategory]

    /// Popular products, by clicks over the last 30 days; a storefront without
    /// clicks yet falls back to reviews and ratings.
    ///
    /// Only products in stock where the shopper is — the city or store of the
    /// request, anywhere when it named neither.
    public var products: [TalqynProduct]
}

extension TalqynStartResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case searchID = "search_id"
        case locale, history, categories, products
        case popularQueries = "popular_queries"
    }

    /// Decodes a start screen, tolerating absent fields. A card that does not
    /// decode is dropped on its own; the rest of the block stays.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searchID = container.value(.searchID, default: "")
        locale = container.value(.locale, default: TalqynLocale.en.rawValue)
        history = container.array(.history)
        popularQueries = container.array(.popularQueries)
        categories = container.array(.categories)
        products = container.array(.products)
    }
}

/// The result of `POST /v1/search/full` — one page of a listing.
public struct TalqynFullSearchResponse: Sendable, Equatable {
    /// The impression id, present on the **first** page only (`offset == 0`).
    ///
    /// Later pages of the same search continue that impression rather than
    /// starting a new one, so a click from any page reports this same id.
    public var searchID: String?

    /// The query the page was produced for.
    public var query: String

    /// The locale the page was produced in.
    public var locale: String

    /// The offset this page starts at.
    public var offset: Int

    /// The page size that was requested.
    public var limit: Int

    /// The ordering that was applied, as its wire value.
    public var sort: String

    /// How many products match the criteria in total.
    public var total: Int

    /// The products on this page.
    public var results: [TalqynProduct]

    /// Whether another page can be requested.
    ///
    /// An empty page ends the listing even when ``total`` promises more:
    /// otherwise pagination would loop on the same offset forever.
    public var hasMore: Bool { !results.isEmpty && offset + results.count < total }

    /// The offset of the next page, or `nil` when the listing is exhausted.
    public var nextOffset: Int? { hasMore ? offset + results.count : nil }
}

extension TalqynFullSearchResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case searchID = "search_id"
        case query, locale, offset, limit, sort, total, results
    }

    /// Decodes a listing page, tolerating absent fields. A card that does not
    /// decode is dropped on its own; the rest of the page stays.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searchID = container.optional(.searchID)
        query = container.value(.query, default: "")
        locale = container.value(.locale, default: TalqynLocale.en.rawValue)
        offset = container.value(.offset, default: 0)
        limit = container.value(.limit, default: 0)
        sort = container.value(.sort, default: TalqynSort.relevance.rawValue)
        total = container.value(.total, default: 0)
        results = container.array(.results)
    }
}
