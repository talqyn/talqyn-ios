import Foundation

/// What the consultant is doing at this point in a turn.
///
/// Extensible: a turn has more than one shape, and a new stage must not break
/// stream parsing in a shipped app.
public struct TalqynConsultantStage: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    /// The wire value.
    public let rawValue: String

    /// Wraps a stage value, known or not.
    ///
    /// - Parameter rawValue: The wire value.
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The turn has opened; the model is working out what was asked.
    public static let thinking = TalqynConsultantStage(rawValue: "thinking")

    /// The catalog is being searched.
    public static let searching = TalqynConsultantStage(rawValue: "searching")
}

/// Why a turn produced no text.
///
/// The set is **open**: treat an unknown value as "no text, products are still
/// there" rather than as an error.
public struct TalqynFallbackReason: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    /// The wire value.
    public let rawValue: String

    /// Wraps a reason value, known or not.
    ///
    /// - Parameter rawValue: The wire value.
    public init(rawValue: String) { self.rawValue = rawValue }

    /// This shopper — or this device, or this network address — has spent their
    /// consultant budget for the next few hours.
    ///
    /// Under a device token this also covers the per-address ceiling shared by
    /// everyone behind one NAT, so a shopper can hit it without a single extra
    /// turn of their own. Tell them the consultant will be back later and show
    /// what was found; search keeps working normally.
    public static let userBudgetExceeded = TalqynFallbackReason(rawValue: "user_budget_exceeded")

    /// The account's monthly budget is spent. The ceiling is raised on Talqyn's
    /// side.
    public static let budgetExceeded = TalqynFallbackReason(rawValue: "budget_exceeded")

    /// The token budget for this single turn ran out.
    public static let turnBudget = TalqynFallbackReason(rawValue: "turn_budget")

    /// The model did not answer in time.
    public static let timeout = TalqynFallbackReason(rawValue: "timeout")

    /// The model provider is circuit-broken after repeated failures.
    public static let circuitOpen = TalqynFallbackReason(rawValue: "circuit_open")

    /// The model declined to answer.
    public static let refusal = TalqynFallbackReason(rawValue: "refusal")

    /// Whether the reason is an exhausted budget.
    ///
    /// The two budget reasons call for different wording to the shopper — one
    /// clears by itself, the other needs a plan change — but both mean "not
    /// now".
    public var isBudgetExhausted: Bool {
        self == .userBudgetExceeded || self == .budgetExceeded
    }
}

/// The products found during a turn.
public struct TalqynConsultantProducts: Sendable, Equatable {
    /// Every product across all steps of the plan, flattened and deduplicated.
    public var items: [TalqynProduct]

    /// The same products split by role. Present only for a multi-step plan such
    /// as a bundle or a comparison.
    public var groups: [TalqynProductGroup]?

    /// The impression id for this turn.
    ///
    /// Report clicks with ``TalqynEventsAPI/productClick(_:)`` using this id and
    /// ``TalqynEventSource/consultant``. One id per turn, so a click's position
    /// is its index in the flattened ``items``.
    public var searchID: String?
}

extension TalqynConsultantProducts: Decodable {
    private enum CodingKeys: String, CodingKey {
        case items, groups
        case searchID = "search_id"
    }

    /// Decodes a products event, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = container.array(.items)
        groups = container.optionalArray(.groups)
        searchID = container.optional(.searchID)
    }
}

/// One step of a multi-step retrieval plan.
public struct TalqynProductGroup: Sendable, Equatable {
    /// What this group is for, in the requested locale — "sofa", "matching
    /// table".
    public var role: String

    /// The products found for this step.
    public var items: [TalqynProduct]
}

extension TalqynProductGroup: Decodable {
    private enum CodingKeys: String, CodingKey { case role, items }

    /// Decodes a product group, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = container.value(.role, default: "")
        items = container.array(.items)
    }
}

/// A follow-up question asked before searching, when the request lacked context.
///
/// There are no products in such a turn. Send the shopper's answer as an
/// ordinary ``TalqynConsultantQuery/question`` on the next request, carrying the
/// same ``TalqynConsultantQuery/sessionID``.
public struct TalqynClarify: Sendable, Equatable {
    /// The lead-in to show above the questions.
    public var message: String

    /// The questions to render, usually as chips.
    public var questions: [Question]

    /// One clarifying question.
    public struct Question: Sendable, Equatable, Identifiable {
        /// The question id.
        public var id: String

        /// The prompt to display.
        public var label: String

        /// Whether more than one option may be picked.
        public var multi: Bool

        /// The answers to offer.
        public var options: [String]

        /// Creates a question. Questions normally arrive decoded from a turn;
        /// this initializer exists for previews, fixtures, and tests.
        public init(id: String, label: String, multi: Bool = false, options: [String]) {
            self.id = id
            self.label = label
            self.multi = multi
            self.options = options
        }
    }

    /// Creates a clarification. For previews, fixtures, and tests.
    public init(message: String, questions: [Question]) {
        self.message = message
        self.questions = questions
    }
}

extension TalqynClarify: Decodable {
    private enum CodingKeys: String, CodingKey { case message, questions }

    /// Decodes a clarify event, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = container.value(.message, default: "")
        questions = container.array(.questions)
    }
}

extension TalqynClarify.Question: Decodable {
    private enum CodingKeys: String, CodingKey { case id, label, multi, options }

    /// Decodes a clarifying question, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.value(.id, default: "")
        label = container.value(.label, default: "")
        multi = container.value(.multi, default: false)
        options = container.array(.options)
    }
}

/// An interface action the consultant proposes.
public enum TalqynConsultantAction: Sendable, Equatable {
    /// Apply a set of filters. The payload transfers into a listing request
    /// as-is — see ``TalqynActionFilters/criteria(query:locale:cityID:locationID:)``.
    case applyFilters(TalqynActionFilters)

    /// Show a comparison table. It is assembled by the server from catalog
    /// attributes, not invented by the model, so it is safe to render directly.
    case showComparison(TalqynComparisonTable)

    /// An action this version of the SDK does not know.
    ///
    /// - Parameter type: The wire value of the action type.
    case unknown(type: String)
}

extension TalqynConsultantAction: Decodable {
    private enum CodingKeys: String, CodingKey { case type, filters, table }

    /// Decodes an action event, mapping an unrecognized type to ``unknown(type:)``.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type: String = container.value(.type, default: "")
        switch type {
        case "apply_filters":
            self = .applyFilters(container.value(.filters, default: TalqynActionFilters()))
        case "show_comparison":
            self = .showComparison(container.value(.table, default: TalqynComparisonTable()))
        default:
            self = .unknown(type: type)
        }
    }
}

/// The filters carried by an ``TalqynConsultantAction/applyFilters(_:)`` action.
///
/// The fields mirror a listing request, so the payload can be moved into one
/// unchanged once a query string is added.
public struct TalqynActionFilters: Sendable, Equatable {
    /// The category to narrow to.
    public var categoryID: Int?

    /// The brand to narrow to.
    public var brandID: Int?

    /// The lower price bound.
    public var priceMin: Double?

    /// The upper price bound.
    public var priceMax: Double?

    /// Whether to keep only discounted products.
    public var hasDiscount: Bool

    /// Structural filters in the form `POST /v1/search/full` accepts.
    public var filters: [String: [String]]

    /// The same selection in the earlier flat form, one value per slug.
    ///
    /// Kept for compatibility only; a listing request ignores it, and it cannot
    /// express a multi-value selection. Send ``filters``.
    public var attributes: [String: String]

    /// Creates a filter payload.
    ///
    /// Payloads normally arrive decoded from a turn; this initializer exists for
    /// previews, fixtures, and tests.
    ///
    /// - Parameters:
    ///   - categoryID: The category to narrow to.
    ///   - brandID: The brand to narrow to.
    ///   - priceMin: The lower price bound.
    ///   - priceMax: The upper price bound.
    ///   - hasDiscount: Whether to keep only discounted products.
    ///   - filters: Structural filters keyed by group slug.
    ///   - attributes: The legacy flat form of the same selection.
    public init(
        categoryID: Int? = nil,
        brandID: Int? = nil,
        priceMin: Double? = nil,
        priceMax: Double? = nil,
        hasDiscount: Bool = false,
        filters: [String: [String]] = [:],
        attributes: [String: String] = [:]
    ) {
        self.categoryID = categoryID
        self.brandID = brandID
        self.priceMin = priceMin
        self.priceMax = priceMax
        self.hasDiscount = hasDiscount
        self.filters = filters
        self.attributes = attributes
    }

    /// Turns the payload into listing criteria.
    ///
    /// - Parameters:
    ///   - query: The text to search for — usually the question that produced
    ///     the action, or the query the conversation started from.
    ///   - locale: The language to search in. `nil` uses the client default.
    ///   - cityID: The shopper's city, in your catalog's numbering.
    ///   - locationID: The shopper's store, in your catalog's numbering.
    /// - Returns: Criteria ready for ``TalqynSearchAPI/full(_:)`` or
    ///   ``TalqynSearchAPI/filters(_:)``.
    public func criteria(
        query: String,
        locale: TalqynLocale? = nil,
        cityID: String? = nil,
        locationID: String? = nil
    ) -> TalqynFilterCriteria {
        TalqynFilterCriteria(
            query: query,
            locale: locale,
            categoryID: categoryID,
            brandID: brandID,
            priceMin: priceMin,
            priceMax: priceMax,
            hasDiscount: hasDiscount,
            filters: filters,
            cityID: cityID,
            locationID: locationID
        )
    }
}

extension TalqynActionFilters: Decodable {
    private enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case brandID = "brand_id"
        case priceMin = "price_min"
        case priceMax = "price_max"
        case hasDiscount = "has_discount"
        case filters
        case attributes = "attrs"
    }

    /// Decodes a filter payload, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categoryID = container.optional(.categoryID)
        brandID = container.optional(.brandID)
        priceMin = container.optional(.priceMin)
        priceMax = container.optional(.priceMax)
        hasDiscount = container.value(.hasDiscount, default: false)
        filters = container.value(.filters, default: [:])
        attributes = container.value(.attributes, default: [:])
    }
}

/// A product comparison table built by the server from catalog attributes.
public struct TalqynComparisonTable: Sendable, Equatable {
    /// The compared products, as Talqyn's internal ids.
    ///
    /// Resolve them against the turn's products to render cards; act in your own
    /// world through each card's ``TalqynProduct/externalID``.
    public var talqynIDs: [Int]

    /// The column headers, aligned with ``talqynIDs``.
    public var titles: [String]

    /// The comparison rows.
    public var rows: [Row]

    /// One characteristic across every compared product.
    public struct Row: Sendable, Equatable {
        /// The characteristic name.
        public var label: String

        /// One value per column, aligned with
        /// ``TalqynComparisonTable/talqynIDs``. `nil` means the product does not
        /// have this characteristic.
        public var values: [String?]

        /// Creates a comparison row. For previews, fixtures, and tests, like
        /// the table's own initializer.
        ///
        /// - Parameters:
        ///   - label: The characteristic name.
        ///   - values: One value per column; `nil` where a product lacks it.
        public init(label: String, values: [String?]) {
            self.label = label
            self.values = values
        }
    }

    /// Creates a comparison table.
    ///
    /// Tables normally arrive decoded from a turn; this initializer exists for
    /// previews, fixtures, and tests.
    ///
    /// - Parameters:
    ///   - talqynIDs: The compared products.
    ///   - titles: The column headers.
    ///   - rows: The comparison rows.
    public init(talqynIDs: [Int] = [], titles: [String] = [], rows: [Row] = []) {
        self.talqynIDs = talqynIDs
        self.titles = titles
        self.rows = rows
    }
}

extension TalqynComparisonTable: Decodable {
    private enum CodingKeys: String, CodingKey {
        case talqynIDs = "talqyn_ids"
        case titles, rows
    }

    /// Decodes a comparison table, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Ids and titles are aligned by index, so they decode as a unit; a row
        // that does not decode is dropped on its own.
        talqynIDs = container.value(.talqynIDs, default: [])
        titles = container.value(.titles, default: [])
        rows = container.array(.rows)
    }
}

extension TalqynComparisonTable.Row: Decodable {
    private enum CodingKeys: String, CodingKey { case label, values }

    /// Decodes a comparison row, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = container.value(.label, default: "")
        values = container.value(.values, default: [])
    }
}

/// The end of a turn.
public struct TalqynConsultantDone: Sendable, Equatable {
    /// The conversation id. Pass it on the next question to continue the
    /// dialogue.
    public var sessionID: String

    /// This turn's id: the key to rate it with
    /// ``TalqynConsultantAPI/submitFeedback(_:)``.
    ///
    /// Every turn has one — a clarification and a fallback too, which is
    /// exactly where products, and a search id, are missing. `nil` only from a
    /// server that predates ratings.
    public var turnID: String?

    /// Time to the first token of the answer, in milliseconds. `nil` for turns
    /// that produced no streamed text.
    public var timeToFirstTokenMs: Int?

    /// How long the whole turn took, in milliseconds.
    public var totalMs: Int?
}

extension TalqynConsultantDone: Decodable {
    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case turnID = "turn_id"
        case timeToFirstTokenMs = "ttft_ms"
        case totalMs = "total_ms"
    }

    /// Decodes a done event, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = container.value(.sessionID, default: "")
        turnID = container.optional(.turnID)
        timeToFirstTokenMs = container.optional(.timeToFirstTokenMs)
        totalMs = container.optional(.totalMs)
    }
}

/// A whole consultant turn delivered as one object, from
/// ``TalqynConsultantAPI/answer(_:)``.
public struct TalqynConsultantAnswer: Sendable, Equatable {
    /// The answer text, with `[p:ID]` markers left in place — see
    /// ``TalqynAnswerMarkup``. Empty on a clarify, redirect, or fallback turn.
    public var answer: String

    /// The conversation id. Pass it on the next question to continue.
    public var sessionID: String?

    /// The products found, flattened and deduplicated.
    public var products: [TalqynProduct]

    /// The clarifying questions, when the turn asked for context instead of
    /// answering. ``answer`` and ``products`` are then empty.
    public var clarify: TalqynClarify?

    /// The products split by role for a multi-step plan. `nil` for a single
    /// search.
    public var groups: [TalqynProductGroup]?

    /// The query to run through ordinary search, when the consultant decided the
    /// request was a search rather than a consultation.
    public var redirectQuery: String?

    /// Why the turn produced no text, when it produced none.
    public var fallbackReason: TalqynFallbackReason?

    /// The interface actions proposed by the turn.
    public var actions: [TalqynConsultantAction]

    /// Ready-made follow-up prompts, to be sent verbatim as the next question.
    public var followUps: [String]

    /// The impression id for the products of this turn.
    public var searchID: String?

    /// The turn's id, to rate it with
    /// ``TalqynConsultantAPI/submitFeedback(_:)``. The same value as
    /// ``TalqynConsultantDone/turnID`` on a stream.
    public var turnID: String?

    /// The tenant the answer was produced for.
    public var tenantID: String?

    /// Whether the turn degraded: products are present, text is not.
    public var isFallback: Bool { fallbackReason != nil }
}

extension TalqynConsultantAnswer: Decodable {
    private enum CodingKeys: String, CodingKey {
        case answer, products, clarify, groups, actions
        case sessionID = "session_id"
        case redirectQuery = "redirect_query"
        case fallbackReason = "fallback_reason"
        case followUps = "follow_ups"
        case searchID = "search_id"
        case turnID = "turn_id"
        case tenantID = "tenant_id"
    }

    /// Decodes a non-streaming consultant answer, tolerating absent fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        answer = container.value(.answer, default: "")
        sessionID = container.optional(.sessionID)
        products = container.array(.products)
        clarify = container.optional(.clarify)
        groups = container.optionalArray(.groups)
        redirectQuery = container.optional(.redirectQuery)
        fallbackReason = (container.optional(.fallbackReason) as String?)
            .map(TalqynFallbackReason.init(rawValue:))
        actions = container.array(.actions)
        followUps = container.array(.followUps)
        searchID = container.optional(.searchID)
        turnID = container.optional(.turnID)
        tenantID = container.optional(.tenantID)
    }
}
