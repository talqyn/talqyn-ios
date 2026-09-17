import Foundation

/// Mints, caches, and reissues the device token.
///
/// A token lives for minutes. Reissuing is scheduled from
/// ``TalqynDeviceToken/expiresIn`` and runs **in the background** while the
/// current token is still good: no request waits for a reissue, and a reissue
/// that fails is a log line rather than a failed search — the current token
/// keeps working until it actually expires. Timed from the **local** clock at
/// the moment of the response: `expires_at` runs on the server's clock, and
/// device clocks drift.
///
/// An actor because screens race for the token: search and the consultant open
/// at once, and that has to mint once, not twice.
actor TalqynDeviceTokenAuthorizer {
    private struct Issued {
        var token: TalqynDeviceToken
        /// When to start fetching the next token, ahead of expiry.
        var refreshAt: Date
        /// When this token stops working, by the local clock.
        var expiresAt: Date

        /// The refresh lead is a fifth of the lifetime, floored at 15 s and
        /// capped at two minutes: a bare percentage would reissue on every
        /// request for a short token, and hold a long one far past its use.
        init(token: TalqynDeviceToken, issuedAt: Date) {
            let life = max(token.expiresIn, 1)
            let lead = min(max(life * 0.2, 15), 120)
            self.token = token
            refreshAt = issuedAt.addingTimeInterval(max(life - lead, 1))
            expiresAt = issuedAt.addingTimeInterval(life)
        }
    }

    private let credentials: TalqynDeviceTokenCredentials
    private let store: TalqynUserIDStore
    private let minter: TalqynDeviceTokenMinter
    private let logHandler: (@Sendable (TalqynLogEvent) -> Void)?
    /// The clock. Injected so the lifecycle can be tested without waiting it out.
    private let now: @Sendable () -> Date

    /// Pause after an unrecoverable refusal (403 "not enabled", 501 "not
    /// configured"). Without it every screen would hammer the endpoint for the
    /// same answer.
    private let failureCooldown: TimeInterval = 60

    /// Pause between **background** reissue attempts after a transient failure.
    /// Without it a 503 on the mint endpoint would cost one mint per request —
    /// one per keystroke, for a search field — for as long as the refresh
    /// window lasts. A request whose token has actually expired is not held
    /// back by this: it needs a token and waits for the mint.
    private let reissueRetryDelay: TimeInterval = 5

    private var identity: TalqynDeviceIdentity
    private var issued: Issued?
    private var inFlight: Task<TalqynDeviceTokenMinter.Minted, Error>?
    private var blockedUntil: (until: Date, error: TalqynError)?
    private var nextBackgroundReissueAt: Date?
    /// Bumped on every identity change. A mint that started under a previous
    /// value belongs to a previous shopper, however it ends.
    private var generation = 0
    /// Server clock minus device clock, learned from a rejected mint and kept in
    /// the store, so the next mint — in this launch or the next — signs with
    /// the right time from its first attempt.
    private var clockOffset: TimeInterval

    init(
        credentials: TalqynDeviceTokenCredentials,
        store: TalqynUserIDStore,
        minter: TalqynDeviceTokenMinter,
        logHandler: (@Sendable (TalqynLogEvent) -> Void)?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.store = store
        self.minter = minter
        self.logHandler = logHandler
        self.now = now
        identity = credentials.identity
        clockOffset = store.loadClockOffset() ?? 0
    }

    /// The `Authorization` header for the next request, minting or reissuing
    /// the token on the way when needed.
    func headers() async throws -> [String: String] {
        let token = try await token()
        return ["Authorization": Self.authorization(for: token)]
    }

    /// The server rejected the token (401): drops it, but only if it is the one
    /// that was rejected. Two requests racing past expiry both see a 401; by the
    /// time the second one reports it, the first has already minted a
    /// replacement that must survive.
    ///
    /// - Parameter authorization: The `Authorization` header value the rejected
    ///   request carried.
    func invalidate(authorization: String?) {
        guard let issued else { return }
        if let authorization, authorization != Self.authorization(for: issued.token) { return }
        self.issued = nil
    }

    /// The server's canonical form is lowercase; the local fallback is
    /// lowercased too so the value does not change casing once a token exists.
    func currentUserID() -> String? {
        issued?.token.userID ?? resolveUserID()?.uuidString.lowercased()
    }

    /// Who the SDK acts as, as the app set it.
    func currentIdentity() -> TalqynDeviceIdentity {
        identity
    }

    /// Changes the shopper. The issued token is discarded: it names the previous
    /// one, and turns under it would land in their history.
    func setIdentity(_ identity: TalqynDeviceIdentity) {
        guard identity != self.identity else { return }
        self.identity = identity
        generation += 1
        issued = nil
        blockedUntil = nil
        nextBackgroundReissueAt = nil
        inFlight?.cancel()
        inFlight = nil
    }

    @discardableResult
    func prepare() async throws -> TalqynDeviceToken {
        try await token()
    }

    private func token() async throws -> TalqynDeviceToken {
        let now = now()
        if let issued, now < issued.expiresAt {
            // Past the refresh mark but still good: fetch the next one in the
            // background and serve this one. Nobody waits, and a reissue that
            // fails costs nothing until this token runs out.
            if now >= issued.refreshAt, inFlight == nil, !isBlocked(at: now), !isBackingOff(at: now) {
                let generation = self.generation
                let task = startMint()
                Task { _ = try? await self.settle(task, generation: generation) }
            }
            return issued.token
        }
        if let blocked = blockedUntil {
            if now < blocked.until { throw blocked.error }
            blockedUntil = nil
        }
        let generation = self.generation
        let task = inFlight ?? startMint()
        return try await settle(task, generation: generation)
    }

    private func startMint() -> Task<TalqynDeviceTokenMinter.Minted, Error> {
        let userID = resolveUserID()
        let task = Task { [minter, credentials, clockOffset] () throws -> TalqynDeviceTokenMinter.Minted in
            try await minter.mint(
                storefront: credentials.storefront,
                clientKeyID: credentials.clientKeyID,
                clientSecret: credentials.clientSecret,
                userID: userID,
                clockOffset: clockOffset
            )
        }
        inFlight = task
        return task
    }

    /// Waits for a mint and installs its outcome. Every waiter — a request,
    /// `prepare()`, the background reissue — comes through here; the first to
    /// resume does the bookkeeping, and the rest find `inFlight` already
    /// cleared.
    private func settle(
        _ task: Task<TalqynDeviceTokenMinter.Minted, Error>,
        generation: Int
    ) async throws -> TalqynDeviceToken {
        do {
            let minted = try await task.value
            // The shopper may have changed while the mint was in flight —
            // cancellation is cooperative, and a response already received
            // still completes. That token names the previous shopper: it must
            // not be installed, or the next turn would land in their history.
            guard generation == self.generation else { throw TalqynError.cancelled }
            if inFlight == task {
                inFlight = nil
                nextBackgroundReissueAt = nil
                if minted.clockOffset != clockOffset {
                    clockOffset = minted.clockOffset
                    store.saveClockOffset(clockOffset == 0 ? nil : clockOffset)
                }
                issued = Issued(token: minted.token, issuedAt: now())
                logHandler?(TalqynLogEvent(
                    level: .debug,
                    message: "device token issued for \(Int(minted.token.expiresIn))s, guest=\(minted.token.userID == nil)"
                ))
            }
            return minted.token
        } catch {
            let talqyn = TalqynError.wrap(error)
            guard generation == self.generation else { throw TalqynError.cancelled }
            if inFlight == task {
                inFlight = nil
                let now = now()
                // Cancellation is not a refusal: a dismissed screen must not
                // lock the consultant out for the next caller.
                if talqyn.isCancellation {
                    // Nothing to remember.
                } else if talqyn.isRetryable {
                    nextBackgroundReissueAt = now.addingTimeInterval(reissueRetryDelay)
                } else {
                    blockedUntil = (now.addingTimeInterval(failureCooldown), talqyn)
                }
                if let issued {
                    let left = issued.expiresAt.timeIntervalSince(now)
                    if left > 0 {
                        logHandler?(TalqynLogEvent(
                            level: .warning,
                            message: "device token reissue failed (\(talqyn.localizedDescription)); "
                                + "the current token is good for another \(Int(left))s",
                            requestID: talqyn.requestID
                        ))
                    }
                }
            }
            throw talqyn
        }
    }

    private func isBlocked(at now: Date) -> Bool {
        guard let blocked = blockedUntil else { return false }
        return now < blocked.until
    }

    private func isBackingOff(at now: Date) -> Bool {
        guard let next = nextBackgroundReissueAt else { return false }
        return now < next
    }

    private static func authorization(for token: TalqynDeviceToken) -> String {
        "Bearer \(token.token)"
    }

    /// `persistentAnonymous` generates the UUID on first use and stores it:
    /// without an id that survives a restart there is no chat history.
    private func resolveUserID() -> UUID? {
        switch identity {
        case .guest:
            return nil
        case let .user(id):
            return id
        case .persistentAnonymous:
            if let stored = store.loadUserID() { return stored }
            let generated = UUID()
            store.saveUserID(generated)
            return generated
        }
    }
}
