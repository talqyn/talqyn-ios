import Foundation

/// One event from the consultant's SSE stream.
///
/// A turn **always** opens with ``status(_:)`` carrying
/// ``TalqynConsultantStage/thinking`` and **always** closes with ``done(_:)`` —
/// a reliable end-of-stream signal whatever the turn turned out to be. In
/// between comes one of these shapes:
///
/// - **ordinary search**: `status` → `status(searching)` → `products` →
///   `delta`×N → `action`×0…2 → `followUps`? → `done`;
/// - **clarification**: `status` → `clarify` → `done` — no products yet;
/// - **redirect**: `status` → `redirectToSearch` → `done` — the request was a
///   search query, so run it through ``TalqynSearchAPI/search(_:)``;
/// - **store question** (delivery, payment, returns, warranty): `status` →
///   `delta` → `done` — short text, no products;
/// - **degradation**: `status` → `products` → `fallback` → `done` — products
///   are there, text is not;
/// - **retrieval failure**: `status(searching)` → `error` → `done`.
///
/// Multi-step plans may interleave several `status`, `products`, and `action`
/// events before the closing `delta` and `done`.
///
/// - Important: An event the server adds is skipped by a shipped build, but
///   the SDK release that learns it adds a case here. Switch with an
///   `@unknown default` branch so that update is a warning in your build, not
///   an error.
public enum TalqynConsultantEvent: Sendable, Equatable {
    /// What the consultant is doing right now.
    case status(TalqynConsultantStage)

    /// The products found for this turn. May arrive without any text at all —
    /// render results independently of ``delta(text:)``.
    case products(TalqynConsultantProducts)

    /// An increment of the answer text.
    ///
    /// May contain `[p:ID]` product markers; see ``TalqynAnswerMarkup``.
    case delta(text: String)

    /// The turn needs more context before it can search.
    case clarify(TalqynClarify)

    /// The request was an ordinary search query, not a consultation.
    ///
    /// - Parameter query: The text to run through ``TalqynSearchAPI/search(_:)``.
    case redirectToSearch(query: String)

    /// The turn will produce no text. Products, if any, have already arrived.
    case fallback(reason: TalqynFallbackReason)

    /// An interface action the consultant proposes.
    case action(TalqynConsultantAction)

    /// Two or three ready-made follow-up prompts.
    ///
    /// Exactly one such event per turn, after the text and the actions. Render
    /// them as chips and send a tap verbatim as
    /// ``TalqynConsultantQuery/question`` with the same session id.
    case followUps(items: [String])

    /// The turn failed on Talqyn's side.
    ///
    /// - Parameter code: The failure code, such as `retrieval_failed` or
    ///   `internal_error`.
    case error(code: String)

    /// The turn is over.
    case done(TalqynConsultantDone)
}

public extension TalqynConsultantEvent {
    /// Parses one stream event.
    ///
    /// ``TalqynConsultantAPI/ask(_:)`` applies this to every message and skips
    /// what it cannot parse, so a new event type on the server does not break a
    /// shipped app.
    ///
    /// - Parameter message: The raw SSE event.
    /// - Returns: The parsed event, or `nil` when the event name is unknown to
    ///   this version of the SDK or its payload does not decode.
    init?(message: TalqynSSEMessage) {
        func decode<T: Decodable>(_ type: T.Type) -> T? {
            try? TalqynCoding.decoder.decode(type, from: message.data)
        }

        switch message.name {
        case "status":
            guard let payload = decode(StatusPayload.self) else { return nil }
            self = .status(payload.stage)
        case "products":
            guard let payload = decode(TalqynConsultantProducts.self) else { return nil }
            self = .products(payload)
        case "delta":
            guard let payload = decode(DeltaPayload.self) else { return nil }
            self = .delta(text: payload.text)
        case "clarify":
            guard let payload = decode(TalqynClarify.self) else { return nil }
            self = .clarify(payload)
        // `redirect` is the former name of the same event: a storefront that
        // lived through the rename must not lose redirects.
        case "redirect_to_search", "redirect":
            guard let payload = decode(RedirectPayload.self) else { return nil }
            self = .redirectToSearch(query: payload.query)
        case "fallback":
            guard let payload = decode(FallbackPayload.self) else { return nil }
            self = .fallback(reason: payload.reason)
        case "action":
            guard let payload = decode(TalqynConsultantAction.self) else { return nil }
            self = .action(payload)
        case "follow_ups":
            guard let payload = decode(FollowUpsPayload.self) else { return nil }
            self = .followUps(items: payload.items)
        case "error":
            guard let payload = decode(ErrorPayload.self) else { return nil }
            self = .error(code: payload.code)
        case "done":
            guard let payload = decode(TalqynConsultantDone.self) else { return nil }
            self = .done(payload)
        default:
            return nil
        }
    }

    /// Whether this is ``done(_:)``, after which the stream yields nothing more.
    var isTerminal: Bool {
        if case .done = self { return true }
        return false
    }
}

private struct StatusPayload: Decodable {
    let stage: TalqynConsultantStage

    private enum CodingKeys: String, CodingKey { case stage }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stage = TalqynConsultantStage(rawValue: container.value(.stage, default: ""))
    }
}

private struct DeltaPayload: Decodable {
    let text: String

    private enum CodingKeys: String, CodingKey { case text }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = container.value(.text, default: "")
    }
}

private struct RedirectPayload: Decodable {
    let query: String

    private enum CodingKeys: String, CodingKey { case query }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = container.value(.query, default: "")
    }
}

private struct FallbackPayload: Decodable {
    let reason: TalqynFallbackReason

    private enum CodingKeys: String, CodingKey { case reason }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = TalqynFallbackReason(rawValue: container.value(.reason, default: ""))
    }
}

private struct FollowUpsPayload: Decodable {
    let items: [String]

    private enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = container.array(.items)
    }
}

private struct ErrorPayload: Decodable {
    let code: String

    private enum CodingKeys: String, CodingKey { case code }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = container.value(.code, default: "")
    }
}
