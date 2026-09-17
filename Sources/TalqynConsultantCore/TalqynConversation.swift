import Combine
import Foundation
import TalqynSDK

/// The consultant conversation: turns, streaming, clarifications, ratings,
/// history.
///
/// This is the logic of the consultant screen with no view attached. It backs
/// `TalqynConsultantViewController`, and it is public so a storefront that
/// draws its own screen gets the same behavior — delta batching, retry, clarify
/// answers, ratings, restoring a chat, click events — by observing this object
/// instead of reimplementing it over ``TalqynConsultantAPI``.
///
/// ```swift
/// @StateObject var conversation = TalqynConversation(talqyn: talqyn)
///
/// ForEach(conversation.turns) { turn in ... }
/// conversation.send("need a laptop for school")
/// ```
///
/// Main-actor bound: every property is meant for a view.
@MainActor
public final class TalqynConversation: ObservableObject {
    /// The turns in order. The last assistant turn changes while
    /// ``isStreaming`` is `true`.
    @Published public private(set) var turns: [TalqynTurn] = []

    /// Whether an answer is being streamed right now.
    @Published public private(set) var isStreaming = false

    /// Whether a chat from history is being loaded.
    @Published public private(set) var isRestoring = false

    /// The conversation id, once the first turn is done.
    @Published public private(set) var sessionID: String?

    /// The composer text. Set it to prefill a question.
    @Published public var draft = ""

    /// In-progress clarify answers by turn id, so a draft survives a re-render.
    @Published public var clarifyDrafts: [UUID: TalqynClarifyDraft] = [:]

    /// Every product seen in this conversation, by Talqyn id: what `[p:ID]`
    /// markers and comparison tables resolve against.
    @Published public private(set) var productsByID: [Int: TalqynProduct] = [:]

    /// The last failure to load a chat from history, for an alert. Cleared by
    /// the next attempt.
    @Published public var restoreFailure: TalqynError?

    /// The last rating Talqyn did not save. The turn's rating is already put
    /// back to what Talqyn holds; this is for a screen that also wants to say
    /// so. Cleared by the next rating.
    @Published public var feedbackFailure: TalqynError?

    /// The client the conversation talks through.
    public let talqyn: Talqyn

    private var streamTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var pendingDelta = ""
    private var flushTask: Task<Void, Never>?
    private var identitySnapshot: TalqynDeviceIdentity?

    /// A rating as Talqyn holds it.
    private struct FeedbackState: Equatable {
        var rating: TalqynAnswerRating?
        var reasons: [TalqynFeedbackReason]

        static let unrated = FeedbackState(rating: nil, reasons: [])
    }

    /// What Talqyn last confirmed for each turn: what a failed update falls
    /// back to, and what the next one is compared against.
    private var confirmedFeedback: [UUID: FeedbackState] = [:]

    /// One sync per turn. Taps arriving while one runs are not queued: the
    /// sync sends the latest state when its request returns, so three quick
    /// taps cost two requests, not three, and the last one always wins.
    private var feedbackTasks: [UUID: Task<Void, Never>] = [:]

    /// How long deltas are batched before they reach the view. Rendering on
    /// every token is wasted work: text arrives faster than it is read.
    private let deltaFlushInterval: UInt64 = 80_000_000

    /// How many follow-up prompts the screen offers under an answer.
    ///
    /// How many questions to put in front of the shopper is the storefront's
    /// call, not the SDK's; the server may send more than are worth showing.
    public let maxFollowUps: Int

    /// Creates a conversation.
    ///
    /// - Parameters:
    ///   - talqyn: The client to talk through.
    ///   - maxFollowUps: How many follow-up prompts to keep from a turn.
    ///     Defaults to ``TalqynConversationLimits/maxFollowUps``; `0` shows
    ///     none.
    public init(talqyn: Talqyn, maxFollowUps: Int = TalqynConversationLimits.maxFollowUps) {
        self.talqyn = talqyn
        self.maxFollowUps = max(0, maxFollowUps)
    }

    // MARK: - Derived state

    /// Whether the screen has nothing to show yet.
    public var isEmpty: Bool { turns.isEmpty }

    /// The prompts to offer under the transcript: the last turn's follow-ups,
    /// or — after the very first answer — the example questions not yet asked.
    ///
    /// A turn the consultant gave up on offers none: whatever stopped it — a
    /// spent budget, a timeout — would stop the next question too, so inviting
    /// one would only walk the shopper into the same wall.
    ///
    /// - Parameter examples: The example questions, from ``TalqynUIStrings``.
    public func suggestedQuestions(examples: [String]) -> [String] {
        guard !isStreaming, case let .assistant(last)? = turns.last else { return [] }
        guard last.fallbackReason == nil else { return [] }
        if !last.followUps.isEmpty { return last.followUps }
        guard last.isAnswer, assistantTurnCount == 1 else { return [] }
        let asked = Set(turns.compactMap { $0.assistant?.question.normalized })
        return examples.filter { !asked.contains($0.normalized) }
    }

    /// Whether the clarify card of a turn takes input: only the latest turn,
    /// and only when nothing is streaming.
    public func isClarifyInteractive(_ turn: TalqynAssistantTurn) -> Bool {
        !isStreaming && turns.last?.id == turn.id
    }

    /// Whether a turn is the latest one, which is where a retry makes sense.
    public func isLast(_ turn: TalqynAssistantTurn) -> Bool {
        turns.last?.id == turn.id
    }

    private var assistantTurnCount: Int {
        turns.reduce(0) { $0 + ($1.assistant == nil ? 0 : 1) }
    }

    // MARK: - Sending

    /// Sends a question. Empty text, a stream in progress, or a restore in
    /// progress make this a no-op.
    ///
    /// - Parameter text: What the shopper typed or tapped.
    public func send(_ text: String) {
        send(text, showsBubble: true, replacingFrom: nil)
    }

    /// Stops the current answer. What arrived stays; the turn is marked as
    /// stopped and can be retried.
    ///
    /// Call it when the screen goes away for good: every turn is an LLM call,
    /// and one nobody will read is still being paid for.
    /// `TalqynConsultantViewController` does this itself.
    public func stop() {
        streamTask?.cancel()
    }

    /// Starts over: a new session with an empty transcript. Ignored while an
    /// answer is streaming.
    public func reset() {
        guard !isStreaming else { return }
        restoreTask?.cancel()
        restoreTask = nil
        isRestoring = false
        turns = []
        productsByID = [:]
        clarifyDrafts = [:]
        confirmedFeedback = [:]
        sessionID = nil
        cancelPendingDelta()
    }

    /// Asks the same question again, dropping that turn and everything after
    /// it.
    ///
    /// - Parameter turnID: The assistant turn to redo.
    public func retry(turnID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              let turn = turns[index].assistant else { return }
        send(turn.question, showsBubble: false, replacingFrom: index)
    }

    /// Answers a clarifying question. The answer is recorded on that turn and
    /// sent as the next question in the same session.
    ///
    /// - Parameters:
    ///   - turnID: The turn that asked.
    ///   - answer: The composed answer; see ``TalqynClarifyDraft/answer(for:)``.
    public func submitClarify(turnID: UUID, answer: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              var turn = turns[index].assistant else { return }
        turn.clarifyAnswer = answer
        turns[index] = .assistant(turn)
        clarifyDrafts[turnID] = nil
        send(answer, showsBubble: false, replacingFrom: nil)
    }

    private func send(_ raw: String, showsBubble: Bool, replacingFrom replaceIndex: Int?) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming, !isRestoring else { return }
        draft = ""
        isStreaming = true

        if let replaceIndex {
            let dropped = turns[replaceIndex...].map(\.id)
            turns = Array(turns[..<replaceIndex])
            dropped.forEach {
                clarifyDrafts[$0] = nil
                confirmedFeedback[$0] = nil
            }
            rebuildProductIndex()
        }
        if showsBubble {
            turns.append(.user(TalqynUserTurn(text: question)))
        }
        turns.append(.assistant(TalqynAssistantTurn(question: question)))

        // The turn is asked for through a captured API object rather than
        // through `self`: a `guard let self` here would hold the conversation,
        // and the screen's state with it, for as long as the answer runs — a
        // dismissed screen would keep paying for an answer nobody reads.
        let consultant = talqyn.consultant
        let query = TalqynConsultantQuery(question: question, sessionID: sessionID)

        streamTask = Task { [weak self] in
            do {
                for try await event in consultant.ask(query) {
                    guard let self else { return }
                    self.apply(event)
                }
                // A cancelled task sees the stream end, not throw: the turn
                // was stopped, and must not read as finished.
                if Task.isCancelled {
                    self?.flushPendingDelta()
                    self?.mutateLastAssistant { $0.wasStopped = true }
                }
            } catch {
                let failure = TalqynError.wrap(error)
                self?.flushPendingDelta()
                self?.mutateLastAssistant { turn in
                    if failure.isCancellation {
                        turn.wasStopped = true
                    } else if turn.errorCode == nil {
                        turn.failure = failure
                    }
                }
            }
            self?.flushPendingDelta()
            self?.mutateLastAssistant { $0.stage = nil }
            self?.isStreaming = false
        }
    }

    private func apply(_ event: TalqynConsultantEvent) {
        if case let .delta(text) = event {
            pendingDelta += text
            scheduleDeltaFlush()
            return
        }
        flushPendingDelta()
        switch event {
        case let .status(stage):
            mutateLastAssistant { $0.stage = stage }
        case let .products(payload):
            mutateLastAssistant { turn in
                // One card per product in a turn. A payload may repeat an
                // item — one the turn already has, or one of its own — and a
                // product listed twice is drawn twice: the Android twin keys
                // its carousel by id and crashes on the repeat. The first
                // occurrence stays, in its place.
                var seen = Set(turn.products.map(\.talqynID))
                turn.products.append(contentsOf: payload.items.filter { seen.insert($0.talqynID).inserted })
                if let groups = payload.groups { turn.groups = groups }
                if let searchID = payload.searchID { turn.searchID = searchID }
                // Products are in; the text is what remains to wait for.
                turn.stage = turn.text.isEmpty ? .composing : nil
            }
            for item in payload.items { productsByID[item.talqynID] = item }
        case .delta:
            break
        case let .clarify(payload):
            mutateLastAssistant { $0.clarify = payload; $0.stage = nil }
        case let .redirectToSearch(query):
            mutateLastAssistant { $0.redirectQuery = query; $0.stage = nil }
        case let .fallback(reason):
            mutateLastAssistant { $0.fallbackReason = reason; $0.stage = nil }
        case let .action(action):
            mutateLastAssistant { $0.actions.append(action) }
        case let .followUps(items):
            mutateLastAssistant { [maxFollowUps] in
                $0.followUps = Self.sanitizedFollowUps(items, limit: maxFollowUps)
            }
        case let .error(code):
            mutateLastAssistant { $0.errorCode = code; $0.stage = nil }
        case let .done(done):
            let session = done.sessionID.isEmpty ? nil : done.sessionID
            sessionID = session ?? sessionID
            mutateLastAssistant {
                $0.talqynTurnID = done.turnID
                $0.sessionID = session
                $0.timeToFirstTokenMs = done.timeToFirstTokenMs
                $0.totalMs = done.totalMs
            }
        }
    }

    private func scheduleDeltaFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.deltaFlushInterval ?? 0)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushPendingDelta()
        }
    }

    private func flushPendingDelta() {
        guard !pendingDelta.isEmpty else { return }
        let text = pendingDelta
        pendingDelta = ""
        mutateLastAssistant { $0.text += text; $0.stage = nil }
    }

    private func cancelPendingDelta() {
        flushTask?.cancel()
        flushTask = nil
        pendingDelta = ""
    }

    private func mutateLastAssistant(_ change: (inout TalqynAssistantTurn) -> Void) {
        guard let index = turns.indices.last, var turn = turns[index].assistant else { return }
        change(&turn)
        turns[index] = .assistant(turn)
    }

    private func rebuildProductIndex() {
        productsByID = turns.reduce(into: [:]) { index, turn in
            guard let assistant = turn.assistant else { return }
            for product in assistant.products { index[product.talqynID] = product }
        }
    }

    /// Trimmed, deduplicated case-insensitively, at most `limit` of them.
    package static func sanitizedFollowUps(
        _ items: [String], limit: Int = TalqynConversationLimits.maxFollowUps
    ) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let question = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty, seen.insert(question.lowercased()).inserted else { continue }
            result.append(question)
            if result.count == limit { break }
        }
        return result
    }

    // MARK: - Ratings

    /// Records the shopper's verdict on a turn and saves it with Talqyn.
    ///
    /// The turn shows the new rating at once. Saving follows in the
    /// background; if Talqyn does not take it, the turn goes back to the
    /// rating Talqyn holds and ``feedbackFailure`` says why — a thumb that
    /// looks pressed must be pressed. Taps faster than the network are
    /// coalesced: the last one is what is saved.
    ///
    /// A turn with no ``TalqynAssistantTurn/talqynTurnID`` — one from a server
    /// that predates ratings — keeps its rating on the device.
    ///
    /// - Parameters:
    ///   - turnID: The assistant turn rated.
    ///   - rating: The verdict, or `nil` to take it back.
    ///   - reasons: Why the answer did not help, most important first. Kept
    ///     only with ``TalqynAnswerRating/notHelpful``.
    public func rate(turnID: UUID, _ rating: TalqynAnswerRating?, reasons: [TalqynFeedbackReason] = []) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              var turn = turns[index].assistant else { return }
        var unique: [TalqynFeedbackReason] = []
        if rating == .notHelpful {
            for reason in reasons where !unique.contains(reason) { unique.append(reason) }
        }
        guard turn.rating != rating || turn.feedbackReasons != unique else { return }
        turn.rating = rating
        turn.feedbackReasons = unique
        turns[index] = .assistant(turn)
        feedbackFailure = nil
        guard turn.isRatedRemotely, feedbackTasks[turnID] == nil else { return }
        feedbackTasks[turnID] = Task { [weak self] in
            await self?.syncFeedback(turnID: turnID)
        }
    }

    /// Sends the turn's rating until what Talqyn holds is what the turn
    /// shows, or until Talqyn refuses.
    private func syncFeedback(turnID: UUID) async {
        defer { feedbackTasks[turnID] = nil }
        let consultant = talqyn.consultant
        while let turn = turns.first(where: { $0.id == turnID })?.assistant,
              let talqynTurnID = turn.talqynTurnID,
              let sessionID = turn.sessionID {
            let wanted = FeedbackState(rating: turn.rating, reasons: turn.feedbackReasons)
            let confirmed = confirmedFeedback[turnID] ?? .unrated
            guard wanted != confirmed else { return }
            do {
                if let rating = wanted.rating {
                    try await consultant.submitFeedback(TalqynFeedback(
                        turnID: talqynTurnID, sessionID: sessionID,
                        verdict: rating.verdict, reasons: wanted.reasons
                    ))
                } else {
                    do {
                        try await consultant.withdrawFeedback(turnID: talqynTurnID)
                    } catch TalqynError.notFound {
                        // No rating on Talqyn's side is what taking it back
                        // asked for — a repeat of a withdrawal that did go
                        // through answers exactly this.
                    }
                }
                confirmedFeedback[turnID] = wanted
            } catch {
                let failure = TalqynError.wrap(error)
                // A turn dropped meanwhile — a reset, a retry — has nothing
                // left to put back.
                guard let index = turns.firstIndex(where: { $0.id == turnID }),
                      var current = turns[index].assistant else { return }
                current.rating = confirmed.rating
                current.feedbackReasons = confirmed.reasons
                turns[index] = .assistant(current)
                if !failure.isCancellation { feedbackFailure = failure }
                return
            }
        }
    }

    // MARK: - Events

    /// Reports a tap on a product card of a turn, so the click has a
    /// denominator. Fire and forget.
    ///
    /// - Parameters:
    ///   - product: The card tapped.
    ///   - turn: The turn it was shown in.
    public func trackProductTap(_ product: TalqynProduct, in turn: TalqynAssistantTurn) {
        let position = turn.products.firstIndex { $0.talqynID == product.talqynID } ?? 0
        talqyn.events.track(TalqynProductClickEvent(
            searchID: turn.searchID,
            talqynID: product.talqynID,
            position: position,
            source: .consultant
        ))
    }

    // MARK: - History

    /// Loads a conversation from history in place of the current one.
    ///
    /// Ignored while an answer is streaming. A failure lands in
    /// ``restoreFailure`` — ``TalqynError/notFound(requestID:)`` when the chat
    /// was deleted meanwhile.
    ///
    /// - Parameter sessionID: The conversation to open.
    public func restore(sessionID: String) {
        guard !isStreaming else { return }
        restoreTask?.cancel()
        restoreFailure = nil
        isRestoring = true

        restoreTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.talqyn.consultant.chat(sessionID: sessionID)
                guard !Task.isCancelled else { return }
                self.isRestoring = false
                self.apply(transcript)
            } catch {
                guard !Task.isCancelled else { return }
                self.isRestoring = false
                self.restoreFailure = TalqynError.wrap(error)
            }
        }
    }

    /// Clears the transcript if it is the conversation that was just deleted
    /// from history.
    ///
    /// - Parameter sessionID: The deleted conversation.
    public func discardIfOpen(sessionID: String) {
        guard self.sessionID == sessionID else { return }
        reset()
    }

    private func apply(_ transcript: TalqynChatTranscript) {
        let products = Dictionary(
            transcript.products.map { ($0.talqynID, $0) }, uniquingKeysWith: { first, _ in first }
        )
        turns = Self.turns(from: transcript.messages, products: products, sessionID: transcript.sessionID)
        productsByID = products
        clarifyDrafts = [:]
        // A rating reopened from history is one Talqyn holds: changing it is
        // an update, taking it back a withdrawal. The reasons are not sent
        // back with a transcript, so a reason picked now is new to Talqyn.
        confirmedFeedback = turns.reduce(into: [:]) { confirmed, turn in
            guard let assistant = turn.assistant, let rating = assistant.rating else { return }
            confirmed[assistant.id] = FeedbackState(rating: rating, reasons: [])
        }
        sessionID = transcript.sessionID
        cancelPendingDelta()
    }

    /// Pairs each shopper message with the assistant message that follows it.
    /// An assistant message on its own — the first row of a chat that started
    /// mid-way — becomes a turn with an empty question.
    static func turns(
        from messages: [TalqynChatMessage],
        products: [Int: TalqynProduct],
        sessionID: String? = nil
    ) -> [TalqynTurn] {
        var turns: [TalqynTurn] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            index += 1
            guard message.role == .user else {
                turns.append(.assistant(restoredTurn(
                    question: nil, answer: message, products: products, sessionID: sessionID
                )))
                continue
            }
            turns.append(.user(TalqynUserTurn(text: message.text)))
            var answer: TalqynChatMessage?
            if index < messages.count, messages[index].role == .assistant {
                answer = messages[index]
                index += 1
            }
            turns.append(.assistant(restoredTurn(
                question: message, answer: answer, products: products, sessionID: sessionID
            )))
        }
        return turns
    }

    private static func restoredTurn(
        question: TalqynChatMessage?,
        answer: TalqynChatMessage?,
        products: [Int: TalqynProduct],
        sessionID: String?
    ) -> TalqynAssistantTurn {
        var turn = TalqynAssistantTurn(question: question?.text ?? "")
        turn.stage = nil
        if question?.isRedirect == true {
            turn.redirectQuery = answer?.text
        } else {
            turn.text = answer?.text ?? ""
        }
        // Each product once, where it was first shown: an id repeated in the
        // row would draw its card twice.
        var seen = Set<Int>()
        turn.products = (answer?.talqynIDs ?? []).filter { seen.insert($0).inserted }.compactMap { products[$0] }
        // Both rows of a turn carry its id and its rating; either will do
        // when the other is missing.
        turn.talqynTurnID = answer?.turnID ?? question?.turnID
        turn.sessionID = turn.talqynTurnID == nil ? nil : sessionID
        turn.rating = (answer?.feedback ?? question?.feedback).map(TalqynAnswerRating.init(verdict:))
        return turn
    }

    // MARK: - Identity

    /// Drops the transcript if the shopper changed since the screen last
    /// appeared: their conversation must not continue under someone else's
    /// history. Call it when the screen appears.
    ///
    /// Compares the identity as the app set it, not the shopper id: the id
    /// reads as a local UUID before the first token and as the server's form
    /// after it, and a screen coming back from a modal must not mistake that
    /// for a different shopper.
    public func refreshIdentity() async {
        let current = await talqyn.currentIdentity()
        guard let previous = identitySnapshot else {
            identitySnapshot = current
            return
        }
        guard previous != current, !isStreaming else { return }
        identitySnapshot = current
        reset()
    }
}

private extension String {
    var normalized: String { lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
}
