import Foundation

/// Request defaults: locale, the shopper's place, the A/B bucket.
///
/// They change at runtime, so they live in one guarded place instead of being
/// copied into every API surface.
final class TalqynDefaultsBox: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var locale: TalqynLocale
        var cityID: String?
        var locationID: String?
        var variant: String?
    }

    private let lock = NSLock()
    private var snapshot: Snapshot

    init(configuration: TalqynConfiguration) {
        snapshot = Snapshot(
            locale: configuration.defaultLocale,
            cityID: configuration.defaultCityID,
            locationID: configuration.defaultLocationID,
            variant: configuration.variant
        )
    }

    var current: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func update(_ change: (inout Snapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&snapshot)
    }

    // MARK: - Applying

    func apply(to query: inout TalqynSearchQuery) {
        let defaults = current
        query.locale = query.locale ?? defaults.locale
        query.variant = query.variant ?? defaults.variant
        // Place is applied as a unit or not at all. A store beats a city, so
        // adding a default store to an explicitly named city would silently
        // override the caller's choice.
        if query.cityID == nil, query.locationID == nil {
            query.cityID = defaults.cityID
            query.locationID = defaults.locationID
        }
    }

    func apply(to query: inout TalqynStartQuery) {
        let defaults = current
        query.locale = query.locale ?? defaults.locale
        query.variant = query.variant ?? defaults.variant
        if query.cityID == nil, query.locationID == nil {
            query.cityID = defaults.cityID
            query.locationID = defaults.locationID
        }
    }

    func apply(to query: inout TalqynFullSearchQuery) {
        current.apply(to: &query)
    }

    func apply(to query: inout TalqynFiltersQuery) {
        current.apply(to: &query)
    }

    func apply(to query: inout TalqynConsultantQuery) {
        let defaults = current
        query.locale = query.locale ?? defaults.locale
        query.variant = query.variant ?? defaults.variant
        if query.cityID == nil, query.locationID == nil {
            query.cityID = defaults.cityID
            query.locationID = defaults.locationID
        }
    }

    func apply(to event: inout TalqynSearchSubmitEvent) {
        let defaults = current
        event.locale = event.locale ?? defaults.locale
        event.variant = event.variant ?? defaults.variant
    }

    func apply(to event: inout TalqynProductClickEvent) {
        event.variant = event.variant ?? current.variant
    }

    func apply(to event: inout TalqynCategoryClickEvent) {
        event.variant = event.variant ?? current.variant
    }

    func apply(to feedback: inout TalqynFeedback) {
        feedback.variant = feedback.variant ?? current.variant
    }
}

/// A snapshot applies itself, so requests sent as one — a listing and its
/// panel — take the defaults from a single read.
extension TalqynDefaultsBox.Snapshot {
    func apply(to criteria: inout TalqynFilterCriteria) {
        criteria.locale = criteria.locale ?? locale
        if criteria.cityID == nil, criteria.locationID == nil {
            criteria.cityID = cityID
            criteria.locationID = locationID
        }
    }

    /// The criteria and the variant from one snapshot: read apart, the
    /// defaults could change in between.
    func apply(to query: inout TalqynFullSearchQuery) {
        apply(to: &query.criteria)
        query.variant = query.variant ?? variant
    }

    func apply(to query: inout TalqynFiltersQuery) {
        apply(to: &query.criteria)
    }
}
