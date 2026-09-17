import Foundation

/// Storefront events: clicks and submitted queries.
///
/// Requires the `events` scope. Reached through ``Talqyn/events``.
///
/// Not analytics for its own sake: the `history` block of an instant-search
/// response and the denominator of click-through are both assembled from these
/// rows. The storefront has to report them itself — by definition there is no
/// backend of yours in the chain to do it. An event is attributed to the
/// shopper the device token names.
public final class TalqynEventsAPI: Sendable {
    private let client: TalqynAPIClient
    private let defaults: TalqynDefaultsBox
    private let logHandler: (@Sendable (TalqynLogEvent) -> Void)?

    init(
        client: TalqynAPIClient,
        defaults: TalqynDefaultsBox,
        logHandler: (@Sendable (TalqynLogEvent) -> Void)?
    ) {
        self.client = client
        self.defaults = defaults
        self.logHandler = logHandler
    }

    /// Reports a product-card tap: `POST /v1/events/product-click`.
    ///
    /// - Parameter event: Which product was tapped, where, and in which
    ///   impression.
    /// - Throws: ``TalqynError``. Use `track(_:)` to fire and forget.
    public func productClick(_ event: TalqynProductClickEvent) async throws {
        var event = event
        defaults.apply(to: &event)
        try await client.send(path: "events/product-click", body: event, safety: .onlyIfRejected)
    }

    /// Reports a submitted search query: `POST /v1/events/search`.
    ///
    /// - Parameter event: The query, where it was submitted from, and how many
    ///   results it produced.
    /// - Throws: ``TalqynError``. Use `track(_:)` to fire and forget.
    public func searchSubmit(_ event: TalqynSearchSubmitEvent) async throws {
        var event = event
        defaults.apply(to: &event)
        try await client.send(path: "events/search", body: event, safety: .onlyIfRejected)
    }

    /// Reports a category tap in the navigation block:
    /// `POST /v1/events/category-click`.
    ///
    /// - Parameter event: Which category was tapped and from which query.
    /// - Throws: ``TalqynError``. Use `track(_:)` to fire and forget.
    public func categoryClick(_ event: TalqynCategoryClickEvent) async throws {
        var event = event
        defaults.apply(to: &event)
        try await client.send(path: "events/category-click", body: event, safety: .onlyIfRejected)
    }

    // MARK: - Fire and forget

    /// Reports a product-card tap without waiting for the result.
    ///
    /// Failures are swallowed into ``TalqynConfiguration/logHandler``: analytics
    /// must not be able to break the screen a shopper just tapped. A transient
    /// failure is logged at `debug`; a permanent refusal — a key without the
    /// `events` scope, a body the server rejects — at `warning`, because it
    /// means the `history` block and click-through are silently not being
    /// built.
    ///
    /// - Parameter event: Which product was tapped, where, and in which
    ///   impression.
    public func track(_ event: TalqynProductClickEvent) {
        fireAndForget("product-click") { try await self.productClick(event) }
    }

    /// Reports a submitted search query without waiting for the result.
    ///
    /// Failures are swallowed into ``TalqynConfiguration/logHandler``.
    ///
    /// - Parameter event: The query, where it was submitted from, and how many
    ///   results it produced.
    public func track(_ event: TalqynSearchSubmitEvent) {
        fireAndForget("search") { try await self.searchSubmit(event) }
    }

    /// Reports a category tap without waiting for the result.
    ///
    /// Failures are swallowed into ``TalqynConfiguration/logHandler``.
    ///
    /// - Parameter event: Which category was tapped and from which query.
    public func track(_ event: TalqynCategoryClickEvent) {
        fireAndForget("category-click") { try await self.categoryClick(event) }
    }

    private func fireAndForget(
        _ name: String,
        _ send: @escaping @Sendable () async throws -> Void
    ) {
        Task { [logHandler] in
            do {
                try await send()
            } catch {
                let talqyn = TalqynError.wrap(error)
                guard !talqyn.isCancellation else { return }
                logHandler?(TalqynLogEvent(
                    level: talqyn.isRetryable ? .debug : .warning,
                    message: "event \(name) was not delivered: \(talqyn.localizedDescription)",
                    requestID: talqyn.requestID
                ))
            }
        }
    }
}
