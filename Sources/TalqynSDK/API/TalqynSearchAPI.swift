import Foundation

/// Instant search, the start screen, listings, and the filter panel.
///
/// Requires the `search` scope, which every device token carries. Reached
/// through ``Talqyn/search``.
///
/// Every request inherits the client's defaults — locale, place, A/B bucket —
/// for the fields it leaves unset.
public final class TalqynSearchAPI: Sendable {
    private let client: TalqynAPIClient
    private let defaults: TalqynDefaultsBox

    init(client: TalqynAPIClient, defaults: TalqynDefaultsBox) {
        self.client = client
        self.defaults = defaults
    }

    /// Runs instant search: `POST /v1/search/`.
    ///
    /// Returns the top matches together with completions, facet chips, brands,
    /// and categories — everything a search field with a dropdown needs from one
    /// round trip.
    ///
    /// Report the submitted query through ``TalqynEventsAPI/searchSubmit(_:)``:
    /// the `history` block of later responses is assembled from those events.
    ///
    /// - Parameter query: What to search for and how to narrow it.
    /// - Returns: Ranked results plus the auxiliary blocks of the dropdown.
    /// - Throws: ``TalqynError`` — commonly
    ///   ``TalqynError/validation(fields:detail:requestID:)`` for an empty query
    ///   or an out-of-range limit, and
    ///   ``TalqynError/rateLimited(retryAfter:detail:requestID:)`` when the
    ///   search bucket is exhausted.
    public func search(_ query: TalqynSearchQuery) async throws -> TalqynSearchResponse {
        var query = query
        defaults.apply(to: &query)
        // The trailing slash is part of the endpoint address, not a typo.
        return try await client.send(path: "search/", body: query)
    }

    /// Runs instant search for a plain query string.
    ///
    /// - Parameters:
    ///   - text: What the shopper typed. 1–500 characters.
    ///   - limit: How many products to return. 1–50.
    /// - Returns: Ranked results plus the auxiliary blocks of the dropdown.
    /// - Throws: ``TalqynError``.
    public func search(_ text: String, limit: Int = 20) async throws -> TalqynSearchResponse {
        try await search(TalqynSearchQuery(query: text, limit: limit))
    }

    /// Fetches the start screen of an empty search field:
    /// `POST /v1/search/start`.
    ///
    /// What to show when the shopper focuses the field and has typed nothing:
    /// their recent queries, what the storefront searches for, the catalog's root
    /// categories, and popular products. This is not `search("")` — an empty
    /// query has no vector and no prefix, so ranking, completions, and correction
    /// are all off, and the answer carries popularity instead of relevance.
    ///
    /// Report card taps through ``TalqynEventsAPI/productClick(_:)`` with
    /// ``TalqynEventSource/start`` and the response's
    /// ``TalqynStartResponse/searchID``, the way you would for search results.
    ///
    /// - Important: Each call is billed as a search, so call it when the field
    ///   takes focus rather than on every redraw.
    ///
    /// - Parameter query: How many products to return and where the shopper is.
    ///   Everything is optional.
    /// - Returns: The screen's four blocks and the impression id for its cards.
    /// - Throws: ``TalqynError`` — commonly
    ///   ``TalqynError/rateLimited(retryAfter:detail:requestID:)`` when the
    ///   search bucket is exhausted.
    public func start(_ query: TalqynStartQuery = TalqynStartQuery()) async throws -> TalqynStartResponse {
        var query = query
        defaults.apply(to: &query)
        return try await client.send(path: "search/start", body: query)
    }

    /// Fetches one page of a listing: `POST /v1/search/full`.
    ///
    /// Advance through pages with
    /// ``TalqynFullSearchQuery/nextPage(after:)``, which returns `nil` once the
    /// listing is exhausted.
    ///
    /// - Parameter query: What to select, how to order it, and which page to
    ///   return.
    /// - Returns: One page of results and the total count behind it.
    /// - Throws: ``TalqynError``.
    public func full(_ query: TalqynFullSearchQuery) async throws -> TalqynFullSearchResponse {
        var query = query
        defaults.apply(to: &query)
        return try await client.send(path: "search/full", body: query)
    }

    /// Fetches facet counts: `POST /v1/search/filters`.
    ///
    /// Counts are computed against the current query **and** the filters already
    /// applied, which is what makes an option's count the number of products the
    /// shopper would get by tapping it.
    ///
    /// - Parameter query: The selection to count against.
    /// - Returns: The facet groups to render, including the city and store
    ///   directories.
    /// - Throws: ``TalqynError``.
    public func filters(_ query: TalqynFiltersQuery) async throws -> TalqynFiltersResponse {
        var query = query
        defaults.apply(to: &query)
        return try await client.send(path: "search/filters", body: query)
    }

    /// Fetches a listing page and its filter panel concurrently.
    ///
    /// Both endpoints take the same selection, and computing it twice by hand is
    /// how a panel ends up counting against something other than what is on
    /// screen. For the same reason the client's defaults are read once for the
    /// two: a place or a locale changed while they are on their way reaches both
    /// requests or neither.
    ///
    /// The two requests run in parallel. The first to fail cancels the other
    /// and is thrown at once, without waiting for a page nobody will show.
    ///
    /// - Parameter query: What to select, how to order it, and which page to
    ///   return. The panel is derived from it through
    ///   ``TalqynFullSearchQuery/filtersQuery``.
    /// - Returns: The page and the facet groups counted against the same
    ///   selection.
    /// - Throws: ``TalqynError`` from whichever request failed first.
    public func listingWithFilters(
        _ query: TalqynFullSearchQuery
    ) async throws -> (listing: TalqynFullSearchResponse, filters: TalqynFiltersResponse) {
        // One snapshot for the pair, applied here rather than by `full` and
        // `filters`: each of those reads the defaults afresh, and a change
        // between the two reads would split the pair.
        let defaults = self.defaults.current
        var listing = query
        defaults.apply(to: &listing)
        var panel = query.filtersQuery
        defaults.apply(to: &panel)
        // The task closures may capture immutable values only: a `var` would
        // be captured by box, which is shared mutable state.
        let listingQuery = listing
        let filtersQuery = panel
        let client = self.client

        // A task group rather than `async let`: `async let` results are
        // awaited in the order they are written, so a failed panel would be
        // reported only once the listing had come back. The group hands over
        // whichever finishes first, and leaving it with an error cancels the
        // request still running.
        return try await withThrowingTaskGroup(of: ListingPart.self) { group in
            group.addTask { .listing(try await client.send(path: "search/full", body: listingQuery)) }
            group.addTask { .filters(try await client.send(path: "search/filters", body: filtersQuery)) }
            var page: TalqynFullSearchResponse?
            var groups: TalqynFiltersResponse?
            for try await part in group {
                switch part {
                case let .listing(response): page = response
                case let .filters(response): groups = response
                }
            }
            // Both tasks returned, or the loop would have thrown.
            guard let page, let groups else { throw TalqynError.cancelled }
            return (page, groups)
        }
    }

    /// What one half of ``listingWithFilters(_:)`` brings back.
    private enum ListingPart: Sendable {
        case listing(TalqynFullSearchResponse)
        case filters(TalqynFiltersResponse)
    }
}
