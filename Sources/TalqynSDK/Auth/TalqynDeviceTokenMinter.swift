import Foundation

/// Mints a device token: `POST /v1/consultant/token`.
///
/// The endpoint is guarded by the storefront's client **signature**, not by a
/// tenant key, so this does not go through the shared authorization pipeline —
/// there would be nothing to authorize it with.
struct TalqynDeviceTokenMinter: Sendable {
    let builder: TalqynRequestBuilder
    let transport: TalqynHTTPTransport
    let logHandler: (@Sendable (TalqynLogEvent) -> Void)?

    /// A minted token and the clock correction it was minted with.
    struct Minted: Sendable {
        var token: TalqynDeviceToken
        /// Server clock minus device clock, in seconds. Carried forward so the
        /// next mint signs with the right time from the first attempt.
        var clockOffset: TimeInterval
    }

    /// How far the device clock must be off before a `401` is read as a clock
    /// problem rather than a key problem. The acceptance window is
    /// ``TalqynClientSignature/maxSkew``; a clock inside it does not cause a
    /// `401`, so a small measured skew leaves the refusal as it is.
    static let clockTolerance: TimeInterval = 60

    private struct Body: Encodable {
        let storefront: String
        let userID: String?

        enum CodingKeys: String, CodingKey {
            case storefront
            case userID = "user_id"
        }
    }

    /// Mints a token.
    ///
    /// A `401` is re-examined before it is surfaced: the response's `Date`
    /// header says what time the server thinks it is, and if the device clock
    /// disagrees by more than ``clockTolerance`` the request is signed once more
    /// with the server's time. A phone with "set automatically" switched off is
    /// otherwise locked out of search entirely — under a device token, search
    /// depends on the mint too.
    ///
    /// - Parameter clockOffset: The correction learned by a previous mint.
    func mint(
        storefront: String,
        clientKeyID: String,
        clientSecret: String,
        userID: UUID?,
        clockOffset: TimeInterval = 0
    ) async throws -> Minted {
        guard !clientKeyID.isEmpty, !clientSecret.isEmpty else {
            throw TalqynError.invalidConfiguration("storefront client key is empty")
        }
        guard !storefront.isEmpty else {
            throw TalqynError.invalidConfiguration("storefront slug is empty")
        }

        // Serialized exactly once: the signature must cover the bytes that go
        // on the wire. Re-encoding could reorder keys and break it.
        let body: Data
        do {
            body = try TalqynCoding.encoder.encode(
                Body(storefront: storefront, userID: userID?.uuidString.lowercased())
            )
        } catch {
            throw TalqynError.wrap(error)
        }

        var offset = clockOffset
        var didCorrectClock = false

        while true {
            let requestID = UUID().uuidString
            // A fresh nonce every time: the server rejects a repeat.
            var headers = TalqynClientSignature.headers(
                keyID: clientKeyID,
                secret: clientSecret,
                body: body,
                timestamp: Date().addingTimeInterval(offset)
            )
            headers["X-Request-ID"] = requestID

            let request = try builder.request(
                method: "POST", path: "consultant/token", body: body, headers: headers
            )

            let (data, response): (Data, TalqynHTTPResponse)
            do {
                (data, response) = try await transport.send(request)
            } catch {
                throw TalqynError.wrap(error)
            }
            let received = Date()

            if response.isSuccess {
                do {
                    let token = try TalqynCoding.decoder.decode(TalqynDeviceToken.self, from: data)
                    return Minted(token: token, clockOffset: offset)
                } catch {
                    throw TalqynError.decoding(underlying: error, requestID: requestID)
                }
            }

            if response.statusCode == 401,
               !didCorrectClock,
               let serverTime = response.value(for: "Date").flatMap(TalqynCoding.httpDate) {
                let skew = serverTime.timeIntervalSince(received)
                if abs(skew - offset) > Self.clockTolerance {
                    didCorrectClock = true
                    // A skew inside the tolerance is a clock that is fine —
                    // the previous correction was the problem — and the Date
                    // header's one-second precision is not worth keeping.
                    offset = abs(skew) <= Self.clockTolerance ? 0 : skew
                    logHandler?(TalqynLogEvent(
                        level: .info,
                        message: "device clock is off by \(Int(skew))s; signing the mint with the server's time",
                        requestID: requestID
                    ))
                    continue
                }
            }

            let error = Self.describe(response: response, data: data, requestID: requestID)
            logHandler?(TalqynLogEvent(
                level: .warning,
                message: "device token mint rejected: \(error.localizedDescription)",
                requestID: error.requestID
            ))
            throw error
        }
    }

    /// Minting has its own status codes, and they mean different things: 403 —
    /// not enabled for the storefront, 501 — not configured on the installation,
    /// 503 — no live anchor key. The last two are support conversations rather
    /// than "try later", hence their own error cases.
    ///
    /// The storefront-level refusal arrives in the auth envelope,
    /// `{"detail": …}`. A `503` in the platform envelope — `{"error":
    /// "overloaded", …}` — or a bare `503` from a proxy is an ordinary server
    /// failure and must not read as "call support".
    private static func describe(
        response: TalqynHTTPResponse,
        data: Data,
        requestID: String
    ) -> TalqynError {
        let envelope = TalqynErrorEnvelope.parse(data)
        switch response.statusCode {
        case 501:
            return .deviceTokensNotConfigured(requestID: envelope?.requestID ?? requestID)
        case 503 where envelope?.error == nil && envelope?.detail != nil:
            return .deviceTokensUnavailable(requestID: envelope?.requestID ?? requestID)
        default:
            return .from(response: response, data: data, requestID: requestID)
        }
    }
}
