import Foundation
import TalqynSDK

/// One entry of a conversation: what the shopper said, or what the consultant
/// answered.
public enum TalqynTurn: Identifiable, Equatable, Sendable {
    case user(TalqynUserTurn)
    case assistant(TalqynAssistantTurn)

    /// The stable identity of the turn, kept across every update to it.
    public var id: UUID {
        switch self {
        case let .user(turn): return turn.id
        case let .assistant(turn): return turn.id
        }
    }

    /// The assistant turn, or `nil` for the shopper's.
    public var assistant: TalqynAssistantTurn? {
        if case let .assistant(turn) = self { return turn }
        return nil
    }
}

/// What the shopper sent.
public struct TalqynUserTurn: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// The shopper's verdict on an answer.
public enum TalqynAnswerRating: String, Sendable, Equatable, CaseIterable {
    case helpful
    case notHelpful = "not_helpful"

    /// The verdict the API takes for this rating.
    public var verdict: TalqynFeedbackVerdict {
        self == .helpful ? .up : .down
    }

    /// The rating a verdict stands for — for a turn reopened from history.
    public init(verdict: TalqynFeedbackVerdict) {
        self = verdict == .up ? .helpful : .notHelpful
    }
}

/// The consultant's answer to one question, filled in as the stream arrives.
///
/// Read it as a snapshot: while ``TalqynConversation/isStreaming`` is `true`
/// the last assistant turn keeps changing.
///
/// Equality is synthesized, and a screen re-renders a turn on inequality: a
/// property added here is part of what redraws the turn without anyone having
/// to remember to add it to a comparison.
public struct TalqynAssistantTurn: Identifiable, Equatable, Sendable {
    public let id: UUID

    /// The question this turn answers — the shopper's text, or a clarify
    /// answer, or the question repeated on retry.
    public let question: String

    /// The answer text so far, markers included; see ``TalqynAnswerRenderer``.
    public var text: String = ""

    /// Every product the turn found, deduplicated, in order of arrival.
    public var products: [TalqynProduct] = []

    /// The products split by role, for a multi-step plan.
    public var groups: [TalqynProductGroup]?

    /// The impression id of the turn's products, for click events.
    public var searchID: String?

    /// What the consultant is doing right now; `nil` once the turn settled.
    public var stage: TalqynConsultantStage? = .thinking

    /// The actions proposed so far.
    public var actions: [TalqynConsultantAction] = []

    /// Follow-up prompts, sanitized: trimmed, deduplicated, and no more than
    /// the conversation's ``TalqynConversation/maxFollowUps``.
    public var followUps: [String] = []

    /// The clarifying questions, when the turn asked instead of answering.
    public var clarify: TalqynClarify?

    /// What the shopper answered to ``clarify``, once they did.
    public var clarifyAnswer: String?

    /// The search query, when the request turned out to be a search.
    public var redirectQuery: String?

    /// Why the turn produced no text, when it produced none.
    public var fallbackReason: TalqynFallbackReason?

    /// The server's failure code, from an `error` event.
    public var errorCode: String?

    /// The client-side failure that ended the stream, if one did.
    public var failure: TalqynError?

    /// Whether the shopper stopped the answer.
    public var wasStopped = false

    /// The turn's id on Talqyn's side, from its `done` event: what a rating
    /// is saved under. `nil` until the turn is done, and for a turn from a
    /// server that predates ratings — such a turn is rated on the device only.
    public var talqynTurnID: String?

    /// The conversation the turn was taken in, from its `done` event.
    public var sessionID: String?

    /// How the shopper rated the answer, once they did.
    public var rating: TalqynAnswerRating?

    /// Why the shopper found the answer unhelpful, most important first.
    /// Empty unless ``rating`` is ``TalqynAnswerRating/notHelpful``.
    public var feedbackReasons: [TalqynFeedbackReason] = []

    /// Time to the first token of the answer, in milliseconds, as Talqyn
    /// measured it — from the turn's `done` event. `nil` until the turn is
    /// done, for a turn that streamed no text, and for a turn reopened from
    /// history.
    public var timeToFirstTokenMs: Int?

    /// How long the whole turn took, in milliseconds, as Talqyn measured it —
    /// from the turn's `done` event. `nil` until the turn is done, and for a
    /// turn reopened from history.
    public var totalMs: Int?

    public init(id: UUID = UUID(), question: String) {
        self.id = id
        self.question = question
    }

    /// Whether the turn ended in a failure of any kind: a server error, a
    /// dropped stream, or the shopper stopping it.
    public var didFail: Bool {
        errorCode != nil || failure != nil || wasStopped
    }

    /// Whether the turn answered with products or text, rather than a
    /// question, a redirect, or a failure.
    public var isAnswer: Bool {
        clarify == nil && redirectQuery == nil && !didFail
    }

    /// Whether a rating of the turn reaches Talqyn, rather than staying on
    /// the device.
    public var isRatedRemotely: Bool {
        talqynTurnID != nil && sessionID != nil
    }
}

/// The shopper's in-progress answer to a clarifying question.
public struct TalqynClarifyDraft: Equatable, Sendable {
    /// Selected options by question id.
    public var selected: [String: [String]] = [:]

    /// Free text typed instead of, or in addition to, the options.
    public var custom: String = ""

    public init(selected: [String: [String]] = [:], custom: String = "") {
        self.selected = selected
        self.custom = custom
    }

    /// Whether anything has been chosen or typed.
    public var isEmpty: Bool {
        selected.values.allSatisfy(\.isEmpty) && custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Toggles an option. A single-choice question replaces its selection; a
    /// multiple-choice one adds and removes.
    public mutating func toggle(_ option: String, in question: TalqynClarify.Question) {
        var current = selected[question.id] ?? []
        if question.multi {
            if let index = current.firstIndex(of: option) {
                current.remove(at: index)
            } else {
                current.append(option)
            }
        } else {
            current = current == [option] ? [] : [option]
        }
        selected[question.id] = current.isEmpty ? nil : current
    }

    /// Whether an option is selected.
    public func isSelected(_ option: String, in question: TalqynClarify.Question) -> Bool {
        selected[question.id]?.contains(option) == true
    }

    /// The answer to send: `Budget: up to 300k. Screen: 15". <free text>`,
    /// with the labels and options as the questions carried them.
    ///
    /// The label loses its question mark: it is restated, not asked back.
    public func answer(for questions: [TalqynClarify.Question]) -> String {
        let parts: [String] = questions.compactMap { question in
            guard let values = selected[question.id], !values.isEmpty else { return nil }
            let label = question.label.trimmingCharacters(in: CharacterSet(charactersIn: "? \t"))
            return "\(label): \(values.joined(separator: ", "))"
        }
        let base = parts.isEmpty ? "" : parts.joined(separator: ". ") + "."
        let extra = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if extra.isEmpty { return base }
        return base.isEmpty ? extra : "\(base) \(extra)"
    }
}

/// The contract's input limits.
public enum TalqynConversationLimits {
    /// The longest question the API accepts.
    public static let maxInputLength = 2000
    /// The longest free-text clarify answer.
    public static let maxClarifyCustomLength = 500
    /// How many follow-up prompts to show, unless a conversation is built
    /// with its own ``TalqynConversation/maxFollowUps``.
    public static let maxFollowUps = 3
}
