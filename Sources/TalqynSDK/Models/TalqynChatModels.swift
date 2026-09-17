import Foundation

/// One row in the shopper's list of conversations.
public struct TalqynChatSummary: Sendable, Equatable, Identifiable {
    /// The conversation id. Pass it to ``TalqynConsultantAPI/chat(sessionID:locale:)``
    /// to read the transcript, or to ``TalqynConsultantQuery/sessionID`` to
    /// continue the dialogue.
    public var sessionID: String

    /// The shopper's first message, truncated. `nil` for conversations started
    /// before history existed.
    public var title: String?

    /// The transcript length in **messages**, not turns: one turn writes two
    /// rows.
    public var messageCount: Int

    /// When the conversation started.
    public var createdAt: Date?

    /// When the last message was written. This is what the list is sorted by,
    /// newest first.
    public var lastMessageAt: Date?

    /// The stable identity of the row: ``sessionID``.
    public var id: String { sessionID }
}

extension TalqynChatSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case title
        case messageCount = "message_count"
        case createdAt = "created_at"
        case lastMessageAt = "last_message_at"
    }

    /// Decodes a conversation summary, tolerating absent fields and both
    /// ISO-8601 timestamp forms.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = container.value(.sessionID, default: "")
        title = container.optional(.title)
        messageCount = container.value(.messageCount, default: 0)
        createdAt = container.date(.createdAt)
        lastMessageAt = container.date(.lastMessageAt)
    }
}

/// One message in a transcript.
public struct TalqynChatMessage: Sendable, Equatable {
    /// Who wrote the message.
    ///
    /// Extensible for the same reason as ``Route``: a role this version of the
    /// SDK has not seen must not cost the app the message, let alone the
    /// transcript.
    public struct Role: RawRepresentable, Sendable, Equatable, Hashable, Codable {
        /// The wire value.
        public let rawValue: String

        /// Wraps a role value, known or not.
        ///
        /// - Parameter rawValue: The wire value.
        public init(rawValue: String) { self.rawValue = rawValue }

        /// The shopper.
        public static let user = Role(rawValue: "user")

        /// The consultant.
        public static let assistant = Role(rawValue: "assistant")
    }

    /// Which way a turn was routed.
    ///
    /// Extensible. A storefront needs this for one reason: so that a redirect
    /// turn is not rendered as a consultant reply — its text is the search query
    /// the shopper was sent to, not prose written for them.
    public struct Route: RawRepresentable, Sendable, Equatable, Hashable, Codable {
        /// The wire value.
        public let rawValue: String

        /// Wraps a route value, known or not.
        ///
        /// - Parameter rawValue: The wire value.
        public init(rawValue: String) { self.rawValue = rawValue }

        /// The turn was answered by the consultant.
        public static let consult = Route(rawValue: "consult")

        /// The turn asked a clarifying question.
        public static let clarify = Route(rawValue: "clarify")

        /// The turn redirected to ordinary search.
        public static let redirect = Route(rawValue: "redirect")
    }

    /// Who wrote the message.
    public var role: Role

    /// The message text.
    public var text: String

    /// The products shown in this turn, as Talqyn's internal ids.
    ///
    /// The cards themselves live in ``TalqynChatTranscript/products`` as one
    /// list for the whole transcript; resolve them with
    /// ``TalqynChatTranscript/products(for:)``.
    public var talqynIDs: [Int]

    /// How the turn was routed. `nil` for assistant messages and for rows
    /// written before routing was recorded.
    public var route: Route?

    /// The id of the turn this message belongs to — the same on the shopper's
    /// message and on the answer. The key to rate the turn with
    /// ``TalqynConsultantAPI/submitFeedback(_:)``. `nil` for turns written
    /// before ratings existed.
    public var turnID: String?

    /// The rating the shopper already gave the turn, so a reopened chat shows
    /// the thumb that is down instead of inviting a second tap.
    public var feedback: TalqynFeedbackVerdict?

    /// When the message was written.
    public var createdAt: Date?

    /// Whether the turn redirected to ordinary search, making ``text`` a search
    /// query rather than a reply.
    public var isRedirect: Bool { route == .redirect }
}

extension TalqynChatMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case role, text, route, feedback
        case talqynIDs = "talqyn_ids"
        case turnID = "turn_id"
        case createdAt = "created_at"
    }

    /// Decodes a transcript message.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError.dataCorrupted` when the role is missing — a
    ///   message nobody wrote cannot be rendered. The transcript drops that
    ///   one message and keeps the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw: String = container.optional(.role), !raw.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .role, in: container, debugDescription: "message has no role"
            )
        }
        role = Role(rawValue: raw)
        text = container.value(.text, default: "")
        talqynIDs = container.array(.talqynIDs)
        route = (container.optional(.route) as String?).map(Route.init(rawValue:))
        turnID = container.optional(.turnID)
        feedback = container.optional(.feedback)
        createdAt = container.date(.createdAt)
    }
}

/// A full conversation transcript.
public struct TalqynChatTranscript: Sendable, Equatable, Identifiable {
    /// The conversation id.
    public var sessionID: String

    /// The shopper's first message, truncated.
    public var title: String?

    /// Every message, oldest first.
    public var messages: [TalqynChatMessage]

    /// Every product mentioned anywhere in the transcript, deduplicated.
    ///
    /// Prices and availability are **current**, not what they were during the
    /// conversation: showing last year's price as if it still stood is worse
    /// than showing one that changed. Products deleted from the catalog since
    /// the conversation are simply absent — the id remains in
    /// ``TalqynChatMessage/talqynIDs`` with no card behind it.
    public var products: [TalqynProduct]

    /// The stable identity of the transcript: ``sessionID``.
    public var id: String { sessionID }

    /// Resolves the products shown in one message, in the order they were shown.
    ///
    /// - Parameter message: A message from this transcript.
    /// - Returns: The matching cards from ``products``. Ids with no card behind
    ///   them are skipped.
    public func products(for message: TalqynChatMessage) -> [TalqynProduct] {
        let index = Dictionary(products.map { ($0.talqynID, $0) }, uniquingKeysWith: { first, _ in first })
        return message.talqynIDs.compactMap { index[$0] }
    }
}

extension TalqynChatTranscript: Decodable {
    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case title, messages, products
    }

    /// Decodes a transcript, tolerating absent fields. A message or a card
    /// that does not decode is dropped on its own; the rest stays.
    ///
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = container.value(.sessionID, default: "")
        title = container.optional(.title)
        messages = container.array(.messages)
        products = container.array(.products)
    }
}
