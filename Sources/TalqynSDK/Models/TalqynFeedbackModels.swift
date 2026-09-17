import Foundation

/// A shopper's verdict on one consultant turn.
///
/// Closed on purpose: the contract has exactly two values, and a third would
/// not be a new verdict but a different feature.
public enum TalqynFeedbackVerdict: String, Sendable, Codable, CaseIterable {
    /// The answer helped.
    case up
    /// The answer did not.
    case down
}

/// Why a turn did not help.
///
/// A dislike without a reason says only "bad". The reasons exist to say
/// **what** to fix, and each points at a different part of the consultant — a
/// reason is worth more than the thumb it comes with.
///
/// Extensible rather than an enumeration, like the other wire values the
/// contract may grow; the server rejects a value it does not know with `422`,
/// so send the ones declared here.
public struct TalqynFeedbackReason: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    /// The wire value.
    public let rawValue: String

    /// Wraps a reason value, known or not.
    ///
    /// - Parameter rawValue: The wire value.
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The products are not what was asked for.
    public static let notRelevant = TalqynFeedbackReason(rawValue: "not_relevant")

    /// The answer states something that is not true.
    public static let wrongInfo = TalqynFeedbackReason(rawValue: "wrong_info")

    /// The consultant asked too many clarifying questions.
    public static let tooManyQuestions = TalqynFeedbackReason(rawValue: "too_many_questions")

    /// There was no answer — the turn fell back or failed.
    public static let noAnswer = TalqynFeedbackReason(rawValue: "no_answer")

    /// A price or the availability is wrong.
    public static let priceStock = TalqynFeedbackReason(rawValue: "price_stock")

    /// Something else; say what in ``TalqynFeedback/comment``.
    public static let other = TalqynFeedbackReason(rawValue: "other")
}

/// A shopper's rating of one consultant turn: `POST /v1/consultant/feedback`.
///
/// A turn is named by ``turnID``, which arrives in
/// ``TalqynConsultantDone/turnID`` — or ``TalqynConsultantAnswer/turnID``, or
/// ``TalqynChatMessage/turnID`` for a turn reopened from history. Knowing the id
/// is what entitles a storefront to rate the turn: it was shown to this client
/// and no other.
///
/// Rating the same turn again replaces the previous rating — the shopper
/// changed their mind, they did not rate twice.
public struct TalqynFeedback: Sendable, Equatable {
    /// The turn, from its `done` event.
    public var turnID: String

    /// The conversation the turn belongs to — the session id from the same
    /// `done` event. A turn from another conversation is `404`.
    public var sessionID: String

    /// Up or down.
    public var verdict: TalqynFeedbackVerdict

    /// Why the turn did not help, most important first. Down only: the server
    /// drops reasons sent with ``TalqynFeedbackVerdict/up``. Up to six.
    public var reasons: [TalqynFeedbackReason]

    /// The shopper's own words. Down only, up to 500 characters.
    public var comment: String?

    /// The cards the shopper called out as wrong — ``TalqynProduct/talqynID``.
    /// Down only, up to 20.
    public var talqynIDs: [Int]

    /// The storefront's A/B bucket. Filled from the client default when `nil`.
    public var variant: String?

    /// Creates a rating.
    ///
    /// - Parameters:
    ///   - turnID: The turn, from its `done` event.
    ///   - sessionID: The conversation the turn belongs to.
    ///   - verdict: Up or down.
    ///   - reasons: Why the turn did not help. Down only.
    ///   - comment: The shopper's own words. Down only.
    ///   - talqynIDs: The cards called out as wrong. Down only.
    ///   - variant: The storefront's A/B bucket.
    public init(
        turnID: String,
        sessionID: String,
        verdict: TalqynFeedbackVerdict,
        reasons: [TalqynFeedbackReason] = [],
        comment: String? = nil,
        talqynIDs: [Int] = [],
        variant: String? = nil
    ) {
        self.turnID = turnID
        self.sessionID = sessionID
        self.verdict = verdict
        self.reasons = reasons
        self.comment = comment
        self.talqynIDs = talqynIDs
        self.variant = variant
    }
}

extension TalqynFeedback: Encodable {
    private enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case sessionID = "session_id"
        case verdict, reasons, comment
        case talqynIDs = "talqyn_ids"
        case variant
    }

    /// Encodes the rating. The down-only fields are left out of an up rating
    /// rather than sent for the server to drop.
    ///
    /// - Parameter encoder: The encoder to write into.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(turnID, forKey: .turnID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(verdict, forKey: .verdict)
        if verdict == .down {
            if !reasons.isEmpty { try container.encode(reasons, forKey: .reasons) }
            try container.encodeIfPresent(comment, forKey: .comment)
            if !talqynIDs.isEmpty { try container.encode(talqynIDs, forKey: .talqynIDs) }
        }
        try container.encodeIfPresent(variant, forKey: .variant)
    }
}
