import Foundation

/// The CIP consultant: a conversation turn and the shopper's chat history.
///
/// Requires the `consultant` scope. Reached through ``Talqyn/consultant``.
///
/// This is the one part of the API with direct money behind it — every turn is
/// an LLM call — so it has its own rate-limit bucket, separate from search.
public final class TalqynConsultantAPI: Sendable {
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

    // MARK: - Conversation turn

    /// Asks the consultant and streams the turn: `POST /v1/consultant/ask`.
    ///
    /// The stream always ends with ``TalqynConsultantEvent/done(_:)``; carry its
    /// session id into the next question to continue the conversation. Nothing
    /// is read after it: iteration ends at `done` and the request is closed,
    /// even if the server or a proxy would keep the connection open. Events
    /// this version of the SDK does not recognize are skipped rather than
    /// surfaced, so a new event type on the server cannot break a shipped app.
    ///
    /// The request begins as soon as this method returns, not on first
    /// iteration. It is cancelled when the consuming task is cancelled or the
    /// stream is dropped, so a turn nobody reads does not keep running.
    ///
    /// ```swift
    /// for try await event in talqyn.consultant.ask(query) {
    ///     switch event {
    ///     case .delta(let text): transcript.append(text)
    ///     case .done(let done): session = done.sessionID
    ///     default: break
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter query: The question, the session to continue, and the place
    ///   to answer for.
    /// - Returns: The turn's events, in the order the server produced them.
    /// - Throws: Iterating the stream throws ``TalqynError`` — commonly
    ///   ``TalqynError/rateLimited(retryAfter:detail:requestID:)`` when the
    ///   consultant bucket is exhausted, or ``TalqynError/transport(_:)`` if the
    ///   connection drops mid-turn. A stream that ends **before** `done` was
    ///   cut short somewhere between Talqyn and the device and throws
    ///   ``TalqynError/transport(_:)`` with `URLError.networkConnectionLost`,
    ///   after the events that did arrive. A turn that degrades on Talqyn's
    ///   side does **not** throw: it arrives as
    ///   ``TalqynConsultantEvent/fallback(reason:)`` with the products intact.
    public func ask(_ query: TalqynConsultantQuery) -> AsyncThrowingStream<TalqynConsultantEvent, Error> {
        var prepared = query
        defaults.apply(to: &prepared)
        // The stream closure may capture immutable values only: a `var` would
        // be captured by box, which is shared mutable state.
        let query = prepared
        let client = self.client
        let logHandler = self.logHandler

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var isComplete = false
                    for try await message in client.stream(path: "consultant/ask", body: query) {
                        guard let event = TalqynConsultantEvent(message: message) else {
                            // Skipped by design, but silently is how a renamed
                            // event goes unnoticed until a shopper complains.
                            logHandler?(TalqynLogEvent(
                                level: .debug,
                                message: "consultant event '\(message.name)' skipped: unknown or undecodable"
                            ))
                            continue
                        }
                        continuation.yield(event)
                        // `done` closes the turn, whatever the connection does
                        // next. Reading on would wait for the server — or a
                        // proxy holding an idle connection open — to end the
                        // body, and fail a finished turn with a transport error
                        // when it gives up. Leaving the loop drops the stream,
                        // and that cancels the request behind it.
                        if event.isTerminal {
                            isComplete = true
                            break
                        }
                    }
                    // A consumer that stopped listening — a dismissed screen —
                    // is not a cut stream. Checked first: on cancellation the
                    // inner stream ends quietly rather than throwing.
                    try Task.checkCancellation()
                    // The contract closes every turn with `done`. Without it
                    // the stream was cut short — a proxy, an idle timeout, a
                    // dropped connection — and the app must not take a turn
                    // that merely stopped for one that finished.
                    guard isComplete else {
                        logHandler?(TalqynLogEvent(
                            level: .warning,
                            message: "consultant stream ended without a done event"
                        ))
                        throw TalqynError.transport(URLError(.networkConnectionLost))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: TalqynError.wrap(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Asks the consultant a plain question.
    ///
    /// - Parameters:
    ///   - question: The shopper's question. 1–2000 characters.
    ///   - sessionID: The session of the previous turn, when continuing a
    ///     conversation.
    /// - Returns: The turn's events, in the order the server produced them.
    public func ask(
        _ question: String,
        sessionID: String? = nil
    ) -> AsyncThrowingStream<TalqynConsultantEvent, Error> {
        ask(TalqynConsultantQuery(question: question, sessionID: sessionID))
    }

    /// Asks the consultant and waits for the whole turn:
    /// `POST /v1/consultant/ask?stream=false`.
    ///
    /// The answer arrives complete, and therefore later: the shopper waits in
    /// silence instead of reading the text as it is generated. Use ``ask(_:)``
    /// for a conversation screen; this is for places with no room for a stream —
    /// a widget, or an answer prepared in the background.
    ///
    /// The request waits as long as a stream waits for its first byte
    /// (``TalqynConfiguration/streamTimeout``): nothing comes back until the
    /// whole turn is written, and the ordinary timeout would cut a long one.
    /// A failure is repeated only after a `429`: a turn is an LLM call that
    /// may have run before its answer was lost, and a repeat would pay for it
    /// twice and write it into the history twice.
    ///
    /// - Parameter query: The question, the session to continue, and the place
    ///   to answer for.
    /// - Returns: The whole turn: text, products, actions, follow-ups, and
    ///   whichever of clarify, redirect, or fallback applies.
    /// - Throws: ``TalqynError``.
    public func answer(_ query: TalqynConsultantQuery) async throws -> TalqynConsultantAnswer {
        var query = query
        defaults.apply(to: &query)
        return try await client.send(
            path: "consultant/ask",
            query: [URLQueryItem(name: "stream", value: "false")],
            body: query,
            safety: .onlyIfRejected,
            timeout: client.streamTimeout
        )
    }

    // MARK: - Rating a turn

    /// Rates a turn: `POST /v1/consultant/feedback`.
    ///
    /// Rating a turn again replaces its rating. Any turn can be rated — a
    /// clarification or a fallback as well as an answer — as long as it has a
    /// ``TalqynConsultantDone/turnID``.
    ///
    /// ```swift
    /// try await talqyn.consultant.submitFeedback(TalqynFeedback(
    ///     turnID: done.turnID!, sessionID: done.sessionID,
    ///     verdict: .down, reasons: [.notRelevant]
    /// ))
    /// ```
    ///
    /// Unlike events, a rating is written before the call returns: the thumb
    /// has a visible state, and the answer says whether it holds. A failure
    /// is repeated like a read — a repeat of the same rating replaces it with
    /// itself.
    ///
    /// - Parameter feedback: The turn, the verdict, and why.
    /// - Throws: ``TalqynError`` — ``TalqynError/notFound(requestID:)`` when
    ///   there is no such turn in that conversation, and
    ///   ``TalqynError/validation(fields:detail:requestID:)`` for a turn id
    ///   that is not a UUID or a reason the server does not know.
    public func submitFeedback(_ feedback: TalqynFeedback) async throws {
        var feedback = feedback
        defaults.apply(to: &feedback)
        try await client.send(path: "consultant/feedback", body: feedback, safety: .idempotent)
    }

    /// Takes a rating back: `DELETE /v1/consultant/feedback/{turn_id}`.
    ///
    /// - Parameter turnID: The turn whose rating to remove.
    /// - Throws: ``TalqynError`` — ``TalqynError/notFound(requestID:)`` when
    ///   the turn had no rating. That is also what a repeat of a deletion that
    ///   did go through answers, so a caller that only wants the rating gone
    ///   may treat it as done.
    public func withdrawFeedback(turnID: String) async throws {
        try await client.send(
            method: "DELETE",
            path: "consultant/feedback/\(TalqynRequestBuilder.segment(turnID))",
            safety: .idempotent
        )
    }

    // MARK: - Chat history

    /// Lists the shopper's conversations, newest first:
    /// `GET /v1/consultant/chats`.
    ///
    /// The token must name the shopper — any identity but
    /// ``TalqynDeviceIdentity/guest``. Under a guest token the server answers
    /// `403` rather than an empty list — deliberately, so that a storefront
    /// that forgot to name its shopper cannot ship a silently empty screen.
    ///
    /// - Parameters:
    ///   - limit: How many rows to return.
    ///   - offset: How many rows to skip.
    /// - Returns: One page of conversation summaries.
    /// - Throws: ``TalqynError`` — notably
    ///   ``TalqynError/forbidden(detail:requestID:)`` under a guest token.
    public func chats(limit: Int = 20, offset: Int = 0) async throws -> [TalqynChatSummary] {
        try await client.send(
            method: "GET",
            path: "consultant/chats",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
        )
    }

    /// Reads one conversation: `GET /v1/consultant/chats/{session_id}`.
    ///
    /// The transcript arrives with the product cards hydrated, so a conversation
    /// can be redrawn with its results rather than as bare text.
    ///
    /// - Parameters:
    ///   - sessionID: The conversation to read.
    ///   - locale: The language to hydrate product cards in. `nil` uses the
    ///     client default.
    /// - Returns: The messages in chronological order and the products they
    ///   referenced.
    /// - Throws: ``TalqynError`` — ``TalqynError/notFound(requestID:)`` both for
    ///   a conversation that does not exist and for one belonging to somebody
    ///   else; the two are indistinguishable on purpose.
    public func chat(
        sessionID: String,
        locale: TalqynLocale? = nil
    ) async throws -> TalqynChatTranscript {
        try await client.send(
            method: "GET",
            path: "consultant/chats/\(TalqynRequestBuilder.segment(sessionID))",
            query: [
                URLQueryItem(
                    name: "locale",
                    value: (locale ?? defaults.current.locale).rawValue
                ),
            ]
        )
    }

    /// Deletes one of the shopper's conversations:
    /// `DELETE /v1/consultant/chats/{session_id}`.
    ///
    /// Removes both the journal rows and the working memory of the session. This
    /// is the shopper clearing one conversation from their own storefront, not
    /// an operator erasing a data subject.
    ///
    /// - Parameter sessionID: The conversation to delete.
    /// - Throws: ``TalqynError`` — ``TalqynError/notFound(requestID:)`` when the
    ///   conversation does not exist or is not this shopper's.
    public func deleteChat(sessionID: String) async throws {
        try await client.send(
            method: "DELETE", path: "consultant/chats/\(TalqynRequestBuilder.segment(sessionID))"
        )
    }
}
