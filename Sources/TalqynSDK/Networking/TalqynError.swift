import Foundation

/// A failure returned by Talqyn or by the SDK on its way there.
///
/// Every SDK call throws this type. It decodes both envelopes the contract
/// defines — `{"detail": …}` for authentication and rate limiting,
/// `{"error": …, "request_id": …}` for everything else — so a caller can branch
/// on the case rather than on a status code.
///
/// Use ``isRetryable`` to tell a transient failure from a permanent one, and
/// ``requestID`` to quote a request when contacting Talqyn support.
///
/// - Important: The cases follow the contract, and a minor release may add
///   one when the contract does. Switch over this type with an
///   `@unknown default` branch — or branch on ``isRetryable`` and
///   ``statusCode`` — so that a new case is a warning in your build, not an
///   error.
public enum TalqynError: Error, Sendable {
    /// The credentials were rejected (`401`).
    ///
    /// The SDK already reissued the device token and retried once before
    /// surfacing this, so reaching it means reissuing did not help either:
    /// the client key itself is invalid or revoked, or the mint was refused.
    ///
    /// - Parameters:
    ///   - detail: The server's explanation, when it sent one.
    ///   - requestID: The `X-Request-ID` of the rejected request.
    case unauthorized(detail: String?, requestID: String?)

    /// The credentials are valid but not sufficient (`403`).
    ///
    /// Raised when device-token issuance is not enabled for the storefront, or
    /// when `/v1/consultant/chats` is read under a guest token, which names no
    /// shopper.
    ///
    /// - Parameters:
    ///   - detail: The server's explanation, when it sent one.
    ///   - requestID: The `X-Request-ID` of the rejected request.
    case forbidden(detail: String?, requestID: String?)

    /// Nothing was found at that address (`404`).
    ///
    /// For a chat this also means "not yours": an unknown session id and
    /// somebody else's answer identically, on purpose — a `403` would confirm
    /// that the conversation exists.
    ///
    /// - Parameter requestID: The `X-Request-ID` of the request.
    case notFound(requestID: String?)

    /// The request body failed validation (`422`).
    ///
    /// - Parameters:
    ///   - fields: Dotted paths of the offending fields, for example
    ///     `["body.filters.0"]`. The server never echoes the raw values.
    ///   - detail: The first validation message, when the server sent one.
    ///   - requestID: The `X-Request-ID` of the request.
    case validation(fields: [String], detail: String?, requestID: String?)

    /// A rate-limit bucket is exhausted (`429`).
    ///
    /// - Parameters:
    ///   - retryAfter: The `Retry-After` value in seconds, when the server sent
    ///     one.
    ///   - detail: The server's explanation, when it sent one.
    ///   - requestID: The `X-Request-ID` of the request.
    case rateLimited(retryAfter: TimeInterval?, detail: String?, requestID: String?)

    /// The server failed, or answered in a way the SDK maps to no other case.
    ///
    /// A `5xx` is the server's own failure and is retried; any other status
    /// that lands here — a `400`, a `405`, a redirect that was not followed —
    /// is a fixed answer to a fixed request and is not.
    ///
    /// - Parameters:
    ///   - status: The HTTP status code.
    ///   - code: The `error` field of the envelope — `upstream_unavailable`,
    ///     `database_unavailable`, `overloaded`, or `internal_error`.
    ///   - detail: The server's explanation, when it sent one.
    ///   - retryAfter: The `Retry-After` value in seconds, when the server sent
    ///     one — a `503` during a deploy often names its own wait.
    ///   - requestID: The `X-Request-ID` to quote to support.
    case server(status: Int, code: String?, detail: String?, retryAfter: TimeInterval?, requestID: String?)

    /// Device tokens are not configured on this Talqyn installation (`501`).
    ///
    /// Not a "try again later": this is a support conversation.
    ///
    /// - Parameter requestID: The `X-Request-ID` of the mint request.
    case deviceTokensNotConfigured(requestID: String?)

    /// The storefront has no live anchor key to issue device tokens against
    /// (`503`).
    ///
    /// Also a support conversation, though the SDK will keep retrying since the
    /// condition can clear on its own.
    ///
    /// - Parameter requestID: The `X-Request-ID` of the mint request.
    case deviceTokensUnavailable(requestID: String?)

    /// The request never completed: a dropped connection, a timeout, or no
    /// network at all.
    ///
    /// - Parameter urlError: The underlying `URLError`.
    case transport(URLError)

    /// The response could not be decoded into the expected model.
    ///
    /// - Parameters:
    ///   - underlying: The decoding failure.
    ///   - requestID: The `X-Request-ID` of the request.
    case decoding(underlying: Error, requestID: String?)

    /// The request body could not be encoded — a non-finite number in a price
    /// bound, for instance. Nothing was sent: this is a programming error on
    /// the calling side, not an answer from the server.
    ///
    /// - Parameter underlying: The encoding failure.
    case encoding(underlying: Error)

    /// The SDK was configured in a way that cannot produce a request — an empty
    /// key, or a base URL that does not parse.
    ///
    /// - Parameter reason: What is wrong with the configuration.
    case invalidConfiguration(String)

    /// The task performing the request was cancelled.
    case cancelled
}

public extension TalqynError {
    /// Whether repeating the request could plausibly succeed.
    ///
    /// `true` for rate limiting, `5xx` server failures, transport failures, and
    /// a storefront temporarily without an anchor key; `false` for client
    /// errors, which would produce the same answer again.
    ///
    /// The SDK already applies this through ``TalqynRetryPolicy``; the property
    /// is public so callers can decide whether to offer a "try again" affordance.
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .transport, .deviceTokensUnavailable:
            return true
        case let .server(status, _, _, _, _):
            return status >= 500
        case .unauthorized, .forbidden, .notFound, .validation, .decoding, .encoding,
             .invalidConfiguration, .deviceTokensNotConfigured, .cancelled:
            return false
        }
    }

    /// The `X-Request-ID` of the failed request, when the failure carries one.
    ///
    /// This is the value Talqyn support needs to find the request in their logs.
    var requestID: String? {
        switch self {
        case let .unauthorized(_, id), let .forbidden(_, id), let .notFound(id),
             let .validation(_, _, id), let .rateLimited(_, _, id),
             let .server(_, _, _, _, id), let .deviceTokensNotConfigured(id),
             let .deviceTokensUnavailable(id), let .decoding(_, id):
            return id
        case .transport, .encoding, .invalidConfiguration, .cancelled:
            return nil
        }
    }

    /// The HTTP status code behind the failure, or `nil` if it never reached the
    /// server.
    var statusCode: Int? {
        switch self {
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .validation: return 422
        case .rateLimited: return 429
        case .deviceTokensNotConfigured: return 501
        case .deviceTokensUnavailable: return 503
        case let .server(status, _, _, _, _): return status
        case .transport, .decoding, .encoding, .invalidConfiguration, .cancelled: return nil
        }
    }

    /// How long to wait before repeating, in seconds, as instructed by the
    /// server. `nil` unless the failure is
    /// ``rateLimited(retryAfter:detail:requestID:)`` or
    /// ``server(status:code:detail:retryAfter:requestID:)`` with a
    /// `Retry-After` header.
    var retryAfter: TimeInterval? {
        switch self {
        case let .rateLimited(retryAfter, _, _), let .server(_, _, _, retryAfter, _):
            return retryAfter
        default:
            return nil
        }
    }
}

extension TalqynError: LocalizedError {
    /// A message suitable for logs and diagnostics.
    ///
    /// Server-supplied text is passed through where there is any; the rest is
    /// generic wording. It is not written for shoppers — phrase user-facing
    /// copy from the case itself.
    public var errorDescription: String? {
        switch self {
        case let .unauthorized(detail, _):
            return detail ?? "Talqyn: request is not authorized"
        case let .forbidden(detail, _):
            return detail ?? "Talqyn: access denied"
        case .notFound:
            return "Talqyn: not found"
        case let .validation(fields, detail, _):
            let where_ = fields.isEmpty ? "" : " (\(fields.joined(separator: ", ")))"
            return (detail ?? "Talqyn: request failed validation") + where_
        case .rateLimited:
            return "Talqyn: rate limit exceeded"
        case let .server(status, code, detail, _, _):
            return detail ?? "Talqyn: server error \(status)\(code.map { " (\($0))" } ?? "")"
        case .deviceTokensNotConfigured:
            return "Talqyn: device token issuance is not configured"
        case .deviceTokensUnavailable:
            return "Talqyn: device token issuance is temporarily unavailable"
        case let .transport(error):
            // A failure that was not a URLError to begin with rides inside one:
            // the code is `unknown`, which says nothing, so say what it was.
            if error.code == .unknown, let underlying = error.userInfo[NSUnderlyingErrorKey] {
                return "Talqyn: request failed (\(underlying))"
            }
            return error.localizedDescription
        case let .decoding(error, _):
            return "Talqyn: could not decode the response (\(error))"
        case let .encoding(error):
            return "Talqyn: could not encode the request (\(error))"
        case let .invalidConfiguration(message):
            return "Talqyn: invalid configuration — \(message)"
        case .cancelled:
            return "Talqyn: request was cancelled"
        }
    }
}

// MARK: - Error envelope

/// An error body in both shapes the contract defines. Everything is optional: a
/// 502 or 503 from a proxy may carry no body at all.
struct TalqynErrorEnvelope: Decodable {
    var error: String?
    var detail: String?
    var fields: [String] = []
    var requestID: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case detail
        case requestID = "request_id"
    }

    /// `detail` is a string for auth and rate limits and a list of objects for
    /// 422 — one field, two shapes, decided at parse time.
    private struct ValidationDetail: Decodable {
        var loc: [String]?
        var msg: String?
        var type: String?

        private enum CodingKeys: String, CodingKey { case loc, msg, type }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // `loc` mixes strings and indices: ["body", "filters", 0].
            var path: [String] = []
            if var list = try? container.nestedUnkeyedContainer(forKey: .loc) {
                while !list.isAtEnd {
                    if let text = try? list.decode(String.self) {
                        path.append(text)
                    } else if let index = try? list.decode(Int.self) {
                        path.append(String(index))
                    } else {
                        _ = try? list.decode(TalqynSkippedValue.self)
                    }
                }
            }
            loc = path.isEmpty ? nil : path
            msg = try? container.decodeIfPresent(String.self, forKey: .msg)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        requestID = try? container.decodeIfPresent(String.self, forKey: .requestID)

        if let text = try? container.decodeIfPresent(String.self, forKey: .detail) {
            detail = text
        } else if let items = try? container.decodeIfPresent([ValidationDetail].self, forKey: .detail) {
            fields = items.compactMap { $0.loc?.joined(separator: ".") }
            detail = items.compactMap { $0.msg ?? $0.type }.first
        }
    }

    static func parse(_ data: Data) -> TalqynErrorEnvelope? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(TalqynErrorEnvelope.self, from: data)
    }
}

extension TalqynError {
    /// Maps a server response onto an error. One mapping for every endpoint:
    /// they share status codes and envelopes and must not diverge. The mint
    /// endpoint's own codes (`501`, `503`) are handled by
    /// ``TalqynDeviceTokenMinter`` before falling back to this.
    static func from(
        response: TalqynHTTPResponse,
        data: Data,
        requestID: String?
    ) -> TalqynError {
        let envelope = TalqynErrorEnvelope.parse(data)
        let id = envelope?.requestID ?? response.value(for: "X-Request-ID") ?? requestID
        let detail = envelope?.detail
        let retryAfter = response.retryAfter()

        switch response.statusCode {
        case 401:
            return .unauthorized(detail: detail, requestID: id)
        case 403:
            return .forbidden(detail: detail, requestID: id)
        case 404:
            return .notFound(requestID: id)
        case 422:
            return .validation(fields: envelope?.fields ?? [], detail: detail, requestID: id)
        case 429:
            return .rateLimited(retryAfter: retryAfter, detail: detail, requestID: id)
        default:
            return .server(
                status: response.statusCode,
                code: envelope?.error,
                detail: detail,
                retryAfter: retryAfter,
                requestID: id
            )
        }
    }

    /// Normalizes any caught error into a ``TalqynError``.
    ///
    /// Every SDK call throws this type already, so a `catch` around one does not
    /// need this. A `catch` around a **task** does: a `CancellationError` from
    /// the surrounding `Task` arrives as itself, and so does a `URLError` from a
    /// transport of your own. Public so a storefront drawing its own screen does
    /// not write this mapping a second time.
    ///
    /// `URLError.cancelled` is separated deliberately: a dismissed screen is not
    /// a failure and has nothing to show a shopper — see ``isCancellation``.
    ///
    /// - Parameter error: Any error.
    /// - Returns: `error` itself when it already is a ``TalqynError``,
    ///   ``cancelled`` for a cancellation, ``encoding(underlying:)`` for an
    ///   `EncodingError`, and ``transport(_:)`` for anything else. A failure
    ///   that is not a `URLError` — a pinning check of your own transport,
    ///   say — keeps the original under `NSUnderlyingErrorKey` of the
    ///   `URLError.unknown` it arrives in: without it such a failure could not
    ///   be told from any other.
    public static func wrap(_ error: Error) -> TalqynError {
        if let talqyn = error as? TalqynError { return talqyn }
        if error is CancellationError { return .cancelled }
        if error is EncodingError { return .encoding(underlying: error) }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .cancelled : .transport(urlError)
        }
        return .transport(URLError(.unknown, userInfo: [NSUnderlyingErrorKey: error as NSError]))
    }
}

extension TalqynError: Equatable {
    /// Two failures are equal when they are the same case with the same
    /// values. An underlying decoding or encoding error has no equality of its
    /// own and is compared by its description — which is what a screen that
    /// re-renders on a change needs: the same failure twice is no change.
    public static func == (lhs: TalqynError, rhs: TalqynError) -> Bool {
        // Switched over the left side with no `default`: a new case has to
        // decide here how it compares, rather than silently comparing unequal.
        switch lhs {
        case let .unauthorized(detail, id):
            guard case let .unauthorized(otherDetail, otherID) = rhs else { return false }
            return detail == otherDetail && id == otherID
        case let .forbidden(detail, id):
            guard case let .forbidden(otherDetail, otherID) = rhs else { return false }
            return detail == otherDetail && id == otherID
        case let .notFound(id):
            guard case let .notFound(otherID) = rhs else { return false }
            return id == otherID
        case let .validation(fields, detail, id):
            guard case let .validation(otherFields, otherDetail, otherID) = rhs else { return false }
            return fields == otherFields && detail == otherDetail && id == otherID
        case let .rateLimited(retryAfter, detail, id):
            guard case let .rateLimited(otherRetryAfter, otherDetail, otherID) = rhs else { return false }
            return retryAfter == otherRetryAfter && detail == otherDetail && id == otherID
        case let .server(status, code, detail, retryAfter, id):
            guard case let .server(otherStatus, otherCode, otherDetail, otherRetryAfter, otherID) = rhs else {
                return false
            }
            return status == otherStatus && code == otherCode && detail == otherDetail
                && retryAfter == otherRetryAfter && id == otherID
        case let .deviceTokensNotConfigured(id):
            guard case let .deviceTokensNotConfigured(otherID) = rhs else { return false }
            return id == otherID
        case let .deviceTokensUnavailable(id):
            guard case let .deviceTokensUnavailable(otherID) = rhs else { return false }
            return id == otherID
        case let .transport(error):
            guard case let .transport(other) = rhs else { return false }
            return error.code == other.code
                && String(describing: error.userInfo[NSUnderlyingErrorKey])
                    == String(describing: other.userInfo[NSUnderlyingErrorKey])
        case let .decoding(error, id):
            guard case let .decoding(other, otherID) = rhs else { return false }
            return id == otherID && String(describing: error) == String(describing: other)
        case let .encoding(error):
            guard case let .encoding(other) = rhs else { return false }
            return String(describing: error) == String(describing: other)
        case let .invalidConfiguration(reason):
            guard case let .invalidConfiguration(otherReason) = rhs else { return false }
            return reason == otherReason
        case .cancelled:
            guard case .cancelled = rhs else { return false }
            return true
        }
    }
}

public extension TalqynError {
    /// Whether the failure is ``cancelled`` — the request was superseded or
    /// its screen dismissed. Nothing to show a shopper.
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
