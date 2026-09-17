import Foundation

/// Whether a failed request may be sent again.
///
/// The retry policy decides how often; this decides whether at all, from what
/// a repeat would cost if the first attempt had in fact gone through.
enum TalqynRetrySafety: Sendable {
    /// Repeating is harmless: a read, or a write that overwrites itself.
    case idempotent

    /// The server starts the work only once it has accepted the request.
    ///
    /// A refusal that came back as a status — a `429`, a `5xx` from before the
    /// stream opened — means nothing was done, and is repeated. A connection
    /// that dropped is not: the work may already be running on the other end.
    /// A consultant turn is an LLM call, and running it twice is paying twice
    /// and recording the turn twice.
    case untilAccepted

    /// Repeated only after a `429`: an exhausted bucket is the one refusal
    /// that says the request was certainly not carried out. A `5xx` or a lost
    /// connection may have come after the work was done.
    case onlyIfRejected
}

/// The SDK's transport core: authorization, retries, error mapping, SSE.
///
/// The API surfaces describe a path and a body and see none of this, so search,
/// the consultant, and events cannot drift apart in how they behave.
struct TalqynAPIClient: Sendable {
    let builder: TalqynRequestBuilder
    let transport: TalqynHTTPTransport
    let authorizer: TalqynDeviceTokenAuthorizer
    let retryPolicy: TalqynRetryPolicy
    let streamTimeout: TimeInterval
    let logHandler: (@Sendable (TalqynLogEvent) -> Void)?

    // MARK: - Unary requests

    /// - Parameters:
    ///   - safety: Whether a failed attempt may be repeated.
    ///   - timeout: Overrides the configured request timeout — for a request
    ///     that sends nothing back until a long piece of work is done.
    func send<Response: Decodable>(
        method: String = "POST",
        path: String,
        query: [URLQueryItem] = [],
        body: Encodable? = nil,
        safety: TalqynRetrySafety = .idempotent,
        timeout: TimeInterval? = nil,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let (data, requestID) = try await perform(
            method: method, path: path, query: query, body: body, safety: safety, timeout: timeout
        )
        do {
            return try TalqynCoding.decoder.decode(Response.self, from: data)
        } catch {
            logHandler?(TalqynLogEvent(
                level: .error, message: "could not decode the response from \(path)", requestID: requestID
            ))
            throw TalqynError.decoding(underlying: error, requestID: requestID)
        }
    }

    /// For endpoints with no response body (`204`).
    ///
    /// - Parameter safety: Whether a failed attempt may be repeated —
    ///   ``TalqynRetrySafety/onlyIfRejected`` for an event.
    func send(
        method: String = "POST",
        path: String,
        query: [URLQueryItem] = [],
        body: Encodable? = nil,
        safety: TalqynRetrySafety = .idempotent
    ) async throws {
        _ = try await perform(
            method: method, path: path, query: query, body: body, safety: safety, timeout: nil
        )
    }

    private func perform(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Encodable?,
        safety: TalqynRetrySafety,
        timeout: TimeInterval?
    ) async throws -> (Data, String) {
        let payload: Data?
        do {
            payload = try body.map { try TalqynCoding.encoder.encode($0) }
        } catch {
            // Outside the retry loop, so it is wrapped by hand: every failure
            // an SDK call surfaces is a ``TalqynError``.
            throw TalqynError.wrap(error)
        }
        var attempt = 0
        var didRefreshAuthorization = false

        while true {
            let requestID = UUID().uuidString
            // Everything before the transport is local — the token included —
            // and a failure there sent nothing that could be carried out twice.
            var didSend = false
            do {
                var headers = try await authorizer.headers()
                headers["X-Request-ID"] = requestID
                let request = try builder.request(
                    method: method, path: path, query: query, body: payload, headers: headers, timeout: timeout
                )
                didSend = true
                let (data, response) = try await transport.send(request)

                if response.isSuccess {
                    return (data, requestID)
                }
                // A device token expiring is routine, and reissuing is the only
                // cure. One attempt, not a loop: a second 401 means the cause is
                // not expiry.
                if response.statusCode == 401, !didRefreshAuthorization {
                    didRefreshAuthorization = true
                    await authorizer.invalidate(authorization: headers["Authorization"])
                    continue
                }
                throw TalqynError.from(response: response, data: data, requestID: requestID)
            } catch {
                let talqyn = TalqynError.wrap(error)
                guard Self.canRetry(talqyn, safety: safety, didSend: didSend),
                      attempt < retryPolicy.maxRetries,
                      let delay = retryPolicy.delay(forAttempt: attempt, retryAfter: talqyn.retryAfter)
                else { throw talqyn }
                try await wait(delay)
                attempt += 1
            }
        }
    }

    /// Whether a failure may be answered by repeating the request.
    ///
    /// - Parameter didSend: Whether the request reached the transport. A
    ///   failure before it — a token that could not be minted — is repeated
    ///   under any safety: nothing was sent to be carried out twice.
    static func canRetry(_ error: TalqynError, safety: TalqynRetrySafety, didSend: Bool) -> Bool {
        guard error.isRetryable else { return false }
        guard didSend else { return true }
        switch safety {
        case .idempotent:
            return true
        case .untilAccepted:
            // A status is an answer, and an answer before the work started
            // means the work did not start. A transport failure has none.
            return error.statusCode != nil
        case .onlyIfRejected:
            return error.statusCode == 429
        }
    }

    // MARK: - Server-sent events

    /// A `text/event-stream` of events.
    ///
    /// Response headers are read **before** the first line: a failing status is
    /// an error in full and must be parsed as an ordinary body, not as a stream.
    ///
    /// The body is a concrete `Sendable` type rather than `any Encodable`: the
    /// stream closure outlives the call, and an existential would travel into it
    /// as shared state.
    func stream<Body: Encodable & Sendable>(
        path: String,
        query: [URLQueryItem] = [],
        body: Body
    ) -> AsyncThrowingStream<TalqynSSEMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let payload = try TalqynCoding.encoder.encode(body)
                    let lines = try await openStream(path: path, query: query, body: payload)
                    var decoder = TalqynSSEDecoder()
                    for try await line in lines {
                        try Task.checkCancellation()
                        if let message = decoder.consume(line: line) {
                            continuation.yield(message)
                        }
                    }
                    if let tail = decoder.finish() {
                        continuation.yield(tail)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: TalqynError.wrap(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens the stream. Repeated under ``TalqynRetrySafety/untilAccepted``:
    /// the turn behind a stream starts once the server answers `200`, so a
    /// refusal before it is safe to repeat and a dropped connection is not.
    private func openStream(
        path: String,
        query: [URLQueryItem],
        body: Data?
    ) async throws -> TalqynLineStream {
        var didRefreshAuthorization = false
        var attempt = 0

        while true {
            let requestID = UUID().uuidString
            var didSend = false
            do {
                var headers = try await authorizer.headers()
                headers["X-Request-ID"] = requestID
                let request = try builder.request(
                    method: "POST",
                    path: path,
                    query: query,
                    body: body,
                    headers: headers,
                    accept: "text/event-stream",
                    timeout: streamTimeout
                )
                didSend = true
                let (lines, response) = try await transport.stream(request)

                if response.isSuccess {
                    return lines
                }
                let data = await Self.collectErrorBody(lines)
                if response.statusCode == 401, !didRefreshAuthorization {
                    didRefreshAuthorization = true
                    await authorizer.invalidate(authorization: headers["Authorization"])
                    continue
                }
                throw TalqynError.from(response: response, data: data, requestID: requestID)
            } catch {
                let talqyn = TalqynError.wrap(error)
                guard Self.canRetry(talqyn, safety: .untilAccepted, didSend: didSend),
                      attempt < retryPolicy.maxRetries,
                      let delay = retryPolicy.delay(forAttempt: attempt, retryAfter: talqyn.retryAfter)
                else { throw talqyn }
                try await wait(delay)
                attempt += 1
            }
        }
    }

    /// A failing streamed request delivers its error body as the same lines.
    /// Read a bounded amount: this is a small envelope, not a stream.
    private static func collectErrorBody(_ lines: TalqynLineStream) async -> Data {
        var text = ""
        var iterator = lines.makeAsyncIterator()
        // `try?` collapses end-of-stream and a read failure into nil; both mean
        // there is no more body to read.
        while text.utf8.count < 8 * 1024, let line = try? await iterator.next() {
            text += line
        }
        return Data(text.utf8)
    }

    /// Sleeps out a backoff. Runs inside a `catch`, so a cancellation here
    /// would leave `perform` as a bare `CancellationError` — it is wrapped
    /// like every other failure, so a caller catching ``TalqynError`` sees it.
    private func wait(_ delay: TimeInterval) async throws {
        guard delay > 0 else { return }
        do {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } catch {
            throw TalqynError.wrap(error)
        }
    }
}
