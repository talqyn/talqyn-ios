import Foundation

/// One selectable value inside a facet group.
public struct TalqynFilterOption: Sendable, Equatable, Hashable {
    /// Whether an option is selected, selectable, or empty at the current
    /// selection.
    ///
    /// An extensible wrapper rather than an enumeration: a value the SDK has not
    /// seen must not break the whole filter panel.
    public struct State: RawRepresentable, Sendable, Equatable, Hashable, Codable {
        /// The wire value.
        public let rawValue: String

        /// Wraps a state value, known or not.
        ///
        /// - Parameter rawValue: The wire value.
        public init(rawValue: String) { self.rawValue = rawValue }

        /// Currently selected.
        public static let active = State(rawValue: "active")

        /// Available to select.
        public static let enabled = State(rawValue: "enabled")

        /// Zero products at the current selection.
        ///
        /// Do not hide it — render it inactive. Options that vanish read as a
        /// filter that disappeared.
        public static let disabled = State(rawValue: "disabled")
    }

    /// The value to send back in `filters[<group slug>]`.
    public var slug: String

    /// The label to display, in the requested locale.
    public var label: String?

    /// How many products carry this value at the current selection.
    public var count: Int

    /// Whether the option is selected, selectable, or empty.
    public var state: State

    /// For the `city` and `location` groups only: the place id **in your
    /// catalog's numbering**.
    ///
    /// This is the value to pass as ``TalqynFilterCriteria/cityID`` (from the
    /// `city` group) or ``TalqynFilterCriteria/locationID`` (from the `location`
    /// group) on the next request. Every other group filters through the
    /// structural ``slug`` and always reports `nil` here.
    ///
    /// A `nil` on a `city` option happens in exactly one case: the currently
    /// selected city disappeared from the directory between requests. The option
    /// stays so the selection remains visible and removable, but there is
    /// nothing left to send it back with — clear the filter.
    public var id: String?

    /// For the `location` group only: the slug of the store's city.
    ///
    /// Use it to group stores underneath the options of the `city` group, which
    /// are keyed by the same slug.
    public var citySlug: String?

    /// Whether the option is currently applied.
    public var isSelected: Bool { state == .active }

    /// Whether the option should be shown but not tappable.
    public var isDisabled: Bool { state == .disabled }
}

extension TalqynFilterOption: Decodable {
    private enum CodingKeys: String, CodingKey {
        case slug, label, count, state, id
        case citySlug = "city_slug"
    }

    /// Decodes a facet option, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = container.value(.slug, default: "")
        label = container.optional(.label)
        count = container.value(.count, default: 0)
        state = State(rawValue: container.value(.state, default: State.enabled.rawValue))
        id = container.optional(.id)
        citySlug = container.optional(.citySlug)
    }
}

/// One group of the filter panel.
public struct TalqynFilterGroup: Sendable, Equatable, Hashable, Identifiable {
    /// How a group is meant to be rendered.
    ///
    /// Extensible for the same reason as ``TalqynFilterOption/State``.
    public struct Kind: RawRepresentable, Sendable, Equatable, Hashable, Codable {
        /// The wire value.
        public let rawValue: String

        /// Wraps a group kind, known or not.
        ///
        /// - Parameter rawValue: The wire value.
        public init(rawValue: String) { self.rawValue = rawValue }

        /// A list of values.
        public static let list = Kind(rawValue: "list")

        /// A numeric range, bounded by ``TalqynFilterGroup/min`` and
        /// ``TalqynFilterGroup/max``.
        public static let range = Kind(rawValue: "range")

        /// A yes/no toggle.
        public static let bool = Kind(rawValue: "bool")
    }

    /// The group key. Also the key to use in `filters` on the next request.
    public var slug: String

    /// The group label to display, in the requested locale.
    public var label: String?

    /// How the group is meant to be rendered.
    public var type: Kind

    /// The values in the group.
    public var options: [TalqynFilterOption]

    /// The lower bound of a ``Kind/range`` group.
    public var min: Double?

    /// The upper bound of a ``Kind/range`` group.
    public var max: Double?

    /// The lower bound currently selected in a ``Kind/range`` group.
    public var selectedMin: Double?

    /// The upper bound currently selected in a ``Kind/range`` group.
    public var selectedMax: Double?

    /// The stable identity of the group: ``slug``.
    public var id: String { slug }

    /// The slugs currently selected — what to send back in `filters`.
    public var selectedSlugs: [String] {
        options.filter(\.isSelected).map(\.slug)
    }

    /// The category group.
    public static let categorySlug = "category"
    /// The brand group.
    public static let brandSlug = "brand"
    /// The price range group.
    public static let priceSlug = "price"
    /// The in-stock group.
    public static let stockSlug = "stock"
    /// The discount group.
    public static let discountSlug = "discount"
    /// The city group. Its options carry ``TalqynFilterOption/id``.
    public static let citySlug = "city"
    /// The store group. Its options carry ``TalqynFilterOption/id``.
    public static let locationSlug = "location"

    /// The former name of the store group.
    ///
    /// Kept so a storefront that lived through the rename does not render stores
    /// twice.
    public static let legacyLocationSlug = "store"

    /// The groups that select a place.
    ///
    /// They do not belong in the general filter panel: a city and a store travel
    /// as the separate `cityID` and `locationID` parameters, not as structural
    /// `filters`.
    public static let placeSlugs: Set<String> = [citySlug, locationSlug, legacyLocationSlug]
}

extension TalqynFilterGroup: Decodable {
    private enum CodingKeys: String, CodingKey {
        case slug, label, type, options, min, max
        case selectedMin = "selected_min"
        case selectedMax = "selected_max"
    }

    /// Decodes a facet group, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = container.value(.slug, default: "")
        label = container.optional(.label)
        type = Kind(rawValue: container.value(.type, default: Kind.list.rawValue))
        options = container.array(.options)
        min = container.optional(.min)
        max = container.optional(.max)
        selectedMin = container.optional(.selectedMin)
        selectedMax = container.optional(.selectedMax)
    }
}

/// The result of `POST /v1/search/filters` — facet counts for the current query
/// and the filters already applied.
public struct TalqynFiltersResponse: Sendable, Equatable {
    /// Every group the server returned, in display order.
    public var groups: [TalqynFilterGroup]

    /// Returns a group by slug.
    ///
    /// - Parameter slug: The group key, for example
    ///   ``TalqynFilterGroup/brandSlug``.
    /// - Returns: The group, or `nil` if the response has none with that slug.
    public func group(_ slug: String) -> TalqynFilterGroup? {
        groups.first { $0.slug == slug }
    }

    /// The groups to render in the filter panel: everything except the city and
    /// store pickers.
    public var panelGroups: [TalqynFilterGroup] {
        groups.filter { !TalqynFilterGroup.placeSlugs.contains($0.slug) }
    }

    /// The city directory. An option's ``TalqynFilterOption/id`` is what goes
    /// into ``TalqynFilterCriteria/cityID``.
    public var cityGroup: TalqynFilterGroup? { group(TalqynFilterGroup.citySlug) }

    /// The store directory, scoped to the selected city when there is one.
    ///
    /// May be absent entirely — for instance when a chain has one store per city
    /// and "pick a store" would duplicate "pick a city". Absence is not an error:
    /// simply do not render the picker.
    public var locationGroup: TalqynFilterGroup? {
        group(TalqynFilterGroup.locationSlug) ?? group(TalqynFilterGroup.legacyLocationSlug)
    }

    /// The price range group.
    public var priceGroup: TalqynFilterGroup? { group(TalqynFilterGroup.priceSlug) }

    /// Everything currently selected, shaped as the `filters` parameter of the
    /// next request.
    public var selectedFilters: [String: [String]] {
        panelGroups.reduce(into: [:]) { result, group in
            let selected = group.selectedSlugs
            if !selected.isEmpty { result[group.slug] = selected }
        }
    }
}

extension TalqynFiltersResponse: Decodable {
    private enum CodingKeys: String, CodingKey { case groups }

    /// Decodes a facet response, tolerating an absent `groups` field.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = container.array(.groups)
    }
}
