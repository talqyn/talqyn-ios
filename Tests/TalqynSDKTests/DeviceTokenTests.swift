import XCTest
import TalqynTestSupport
@testable import TalqynSDK

final class DeviceTokenTests: XCTestCase {
    private let emptySearch = #"{"search_id":"s","query":"x","locale":"ru","total":0,"results":[]}"#

    func testFirstRequestMintsTokenAndUsesIt() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken(token: "tlqd_abc")
        transport.enqueue(json: emptySearch)

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        _ = try await talqyn.search.search("iphone")

        XCTAssertEqual(transport.sent.count, 2)
        let mint = transport.sent[0]
        XCTAssertEqual(mint.path, "/v1/consultant/token")
        XCTAssertEqual(mint.header("X-Client-Key"), "ck_3f9a1c2b7d4e")
        XCTAssertNotNil(mint.header("X-Client-Timestamp"))
        XCTAssertNotNil(mint.header("X-Client-Nonce"))
        XCTAssertEqual(mint.header("X-Client-Sig")?.count, 64)
        // The client secret never travels: only its id and the signature do.
        XCTAssertFalse(mint.bodyText.contains("s3cr3t"))

        let search = transport.sent[1]
        XCTAssertEqual(search.path, "/v1/search/")
        XCTAssertEqual(search.header("Authorization"), "Bearer tlqd_abc")
        // The token names the shopper: no headers needed under it.
        XCTAssertNil(search.header("X-User-ID"))
        XCTAssertNil(search.header("X-User-Sig"))
    }

    /// The signature must cover exactly the bytes that went on the wire.
    func testMintSignatureCoversSentBody() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        transport.enqueue(json: emptySearch)

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        _ = try await talqyn.search.search("iphone")

        let mint = transport.sent[0]
        let expected = TalqynClientSignature.sign(
            secret: "s3cr3t-client-key-value-32-chars-long",
            keyID: try XCTUnwrap(mint.header("X-Client-Key")),
            timestamp: try XCTUnwrap(mint.header("X-Client-Timestamp")),
            nonce: try XCTUnwrap(mint.header("X-Client-Nonce")),
            body: try XCTUnwrap(mint.body)
        )
        XCTAssertEqual(mint.header("X-Client-Sig"), expected)
    }

    func testGuestTokenBodyHasNoUserID() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        transport.enqueue(json: emptySearch)

        let talqyn = TestFixtures.client(
            credentials: TestFixtures.deviceToken(identity: .guest), transport: transport
        )
        _ = try await talqyn.search.search("iphone")

        XCTAssertEqual(transport.sent[0].bodyJSON["storefront"] as? String, "myshop")
        XCTAssertNil(transport.sent[0].bodyJSON["user_id"])
    }

    func testNamedIdentitySendsUserID() async throws {
        let transport = StubTransport()
        let identifier = UUID()
        transport.enqueueDeviceToken(userID: identifier.uuidString.lowercased())
        transport.enqueue(json: emptySearch)

        let talqyn = TestFixtures.client(
            credentials: TestFixtures.deviceToken(identity: .user(identifier)), transport: transport
        )
        _ = try await talqyn.search.search("iphone")

        XCTAssertEqual(
            transport.sent[0].bodyJSON["user_id"] as? String,
            identifier.uuidString.lowercased()
        )
        let reported = await talqyn.currentUserID()
        XCTAssertEqual(reported, identifier.uuidString.lowercased())
    }

    /// The persistent anonymous id must survive a restart: chat history hangs
    /// on it.
    func testPersistentAnonymousIdentityIsStoredAndReused() async throws {
        let store = TalqynInMemoryUserIDStore()
        let first = StubTransport()
        first.enqueueDeviceToken()
        first.enqueue(json: emptySearch)

        let talqyn = TestFixtures.client(
            credentials: TestFixtures.deviceToken(identity: .persistentAnonymous),
            transport: first,
            userIDStore: store
        )
        _ = try await talqyn.search.search("iphone")
        let generated = try XCTUnwrap(first.sent[0].bodyJSON["user_id"] as? String)
        XCTAssertNotNil(store.loadUserID())

        // A fresh SDK instance, the same shopper.
        let second = StubTransport()
        second.enqueueDeviceToken()
        second.enqueue(json: emptySearch)
        let restarted = TestFixtures.client(
            credentials: TestFixtures.deviceToken(identity: .persistentAnonymous),
            transport: second,
            userIDStore: store
        )
        _ = try await restarted.search.search("iphone")
        XCTAssertEqual(second.sent[0].bodyJSON["user_id"] as? String, generated)
    }

    func testTokenIsReusedAcrossRequests() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        transport.enqueue(json: emptySearch)
        transport.enqueue(json: emptySearch)

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        _ = try await talqyn.search.search("iphone")
        _ = try await talqyn.search.search("samsung")

        XCTAssertEqual(transport.sent.filter { $0.path.hasSuffix("/consultant/token") }.count, 1)
    }

    /// Concurrent screens must not mint two tokens.
    func testConcurrentRequestsMintOnce() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        for _ in 0..<4 { transport.enqueue(json: emptySearch) }

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = try await talqyn.search.search("iphone") }
            }
            try? await group.waitForAll()
        }

        XCTAssertEqual(transport.sent.filter { $0.path.hasSuffix("/consultant/token") }.count, 1)
    }

    func test401TriggersOneReissueAndRetry() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken(token: "tlqd_old")
        transport.enqueue(json: #"{"detail":"Invalid device token"}"#, status: 401)
        transport.enqueueDeviceToken(token: "tlqd_new")
        transport.enqueue(json: emptySearch)

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        _ = try await talqyn.search.search("iphone")

        XCTAssertEqual(transport.sent.count, 4)
        XCTAssertEqual(transport.sent[1].header("Authorization"), "Bearer tlqd_old")
        XCTAssertEqual(transport.sent[3].header("Authorization"), "Bearer tlqd_new")
    }

    /// A second 401 in a row means expiry is not the cause: reissuing in a loop
    /// would never end.
    func testRepeated401SurfacesError() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()
        transport.enqueue(json: #"{"detail":"Invalid device token"}"#, status: 401)
        transport.enqueueDeviceToken()
        transport.enqueue(json: #"{"detail":"Invalid device token"}"#, status: 401)

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        do {
            _ = try await talqyn.search.search("iphone")
            XCTFail("expected an authorization failure")
        } catch let error as TalqynError {
            guard case let .unauthorized(detail, _) = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
            XCTAssertEqual(detail, "Invalid device token")
        }
    }

    func testMintDisabledSurfacesForbiddenAndIsNotRetriedImmediately() async throws {
        let transport = StubTransport()
        transport.enqueue(
            json: #"{"detail":"Device token issuance is not enabled for this storefront"}"#,
            status: 403
        )

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        do {
            _ = try await talqyn.search.search("iphone")
            XCTFail("expected the mint to be refused")
        } catch let error as TalqynError {
            guard case .forbidden = error else { return XCTFail("expected forbidden, got \(error)") }
        }

        // Cooldown after an unrecoverable refusal: no hammering the endpoint.
        do {
            _ = try await talqyn.search.search("iphone")
            XCTFail("expected the same refusal")
        } catch let error as TalqynError {
            guard case .forbidden = error else { return XCTFail("expected forbidden, got \(error)") }
        }
        XCTAssertEqual(transport.sent.count, 1, "the second mint must not reach the network")
    }

    func testNotConfiguredInstallationHasItsOwnError() async throws {
        let transport = StubTransport()
        transport.enqueue(json: #"{"detail":"Device tokens are not configured"}"#, status: 501)

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        do {
            _ = try await talqyn.search.search("iphone")
            XCTFail("expected an installation configuration failure")
        } catch let error as TalqynError {
            guard case .deviceTokensNotConfigured = error else {
                return XCTFail("expected deviceTokensNotConfigured, got \(error)")
            }
            XCTAssertFalse(error.isRetryable)
        }
    }

    func testNoAnchorKeyIsRetryable() async throws {
        let transport = StubTransport()
        transport.enqueue(json: #"{"detail":"No active API key"}"#, status: 503)

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        do {
            _ = try await talqyn.search.search("iphone")
            XCTFail("expected minting to be unavailable")
        } catch let error as TalqynError {
            guard case .deviceTokensUnavailable = error else {
                return XCTFail("expected deviceTokensUnavailable, got \(error)")
            }
            XCTAssertTrue(error.isRetryable)
        }
    }

    /// "No anchor key" is a support conversation. A platform 503 — or a bare
    /// one from a proxy — is not, and must not be reported as one.
    func testPlatform503OnMintIsAnOrdinaryServerError() async throws {
        for body in [#"{"error":"overloaded","request_id":"r1"}"#, ""] {
            let transport = StubTransport()
            transport.enqueue(json: body, status: 503)

            let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
            do {
                _ = try await talqyn.search.search("iphone")
                XCTFail("expected a server failure")
            } catch let error as TalqynError {
                guard case let .server(status, _, _, _, _) = error else {
                    return XCTFail("expected server, got \(error) for body \(body)")
                }
                XCTAssertEqual(status, 503)
                XCTAssertTrue(error.isRetryable)
            }
        }
    }

    /// Changing the shopper must discard the token, or the new shopper's turns
    /// land in the previous one's history.
    func testIdentityChangeReissuesToken() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken(token: "tlqd_guest")
        transport.enqueue(json: emptySearch)
        transport.enqueueDeviceToken(token: "tlqd_named")
        transport.enqueue(json: emptySearch)

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        _ = try await talqyn.search.search("iphone")
        await talqyn.setIdentity(.user(UUID()))
        _ = try await talqyn.search.search("iphone")

        XCTAssertEqual(transport.sent.count, 4)
        XCTAssertEqual(transport.sent[3].header("Authorization"), "Bearer tlqd_named")
    }

    func testCurrentIdentityFollowsWhatTheAppSet() async throws {
        let transport = StubTransport()
        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(identity: .guest), transport: transport)
        var identity = await talqyn.currentIdentity()
        XCTAssertEqual(identity, .guest)

        let shopper = UUID()
        await talqyn.setIdentity(.user(shopper))
        identity = await talqyn.currentIdentity()
        XCTAssertEqual(identity, .user(shopper))
        XCTAssertTrue(transport.sent.isEmpty, "reading the identity mints nothing")
    }

    func testPrepareMintsAhead() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken()

        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(), transport: transport)
        try await talqyn.prepare()

        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0].path, "/v1/consultant/token")
    }


    // MARK: - Lifecycle, driven by a fake clock

    /// Past the refresh mark the token is still good: it is served at once and
    /// the next one is fetched behind the request's back.
    func testStaleTokenIsServedWhileReissuingInBackground() async throws {
        let clock = FakeClock()
        let transport = StubTransport()
        transport.enqueueDeviceToken(token: "tlqd_first", expiresIn: 900)
        let authorizer = TestFixtures.authorizer(transport: transport, clock: clock)

        try await authorizer.prepare()
        clock.advance(by: 800) // refresh at 780 s, expiry at 900 s
        transport.enqueueDeviceToken(token: "tlqd_second", expiresIn: 900)

        try await assertBearer(authorizer, "Bearer tlqd_first", "no request waits for a reissue")
        let installed = await Self.waitUntil { try await authorizer.headers()["Authorization"] == "Bearer tlqd_second" }
        XCTAssertTrue(installed, "the background reissue must install its token")
        XCTAssertEqual(transport.sent.count, 2, "one reissue, not one per request")
    }

    /// A reissue that fails costs nothing while the current token lasts.
    func testReissueFailureKeepsTheLiveToken() async throws {
        let clock = FakeClock()
        let transport = StubTransport()
        transport.enqueueDeviceToken(token: "tlqd_live", expiresIn: 900)
        let logs = LogCollector()
        let authorizer = TestFixtures.authorizer(transport: transport, clock: clock, logHandler: logs.append)

        try await authorizer.prepare()
        clock.advance(by: 800)
        transport.enqueue(json: #"{"error":"overloaded"}"#, status: 503)

        try await assertBearer(authorizer, "Bearer tlqd_live")
        let warned = await Self.waitUntil { logs.all.contains { $0.level == .warning && $0.message.contains("reissue failed") } }
        XCTAssertTrue(warned, "a failed reissue is a log line, not a failed request")

        clock.advance(by: 99) // 899 s: still inside the lifetime
        try await assertBearer(authorizer, "Bearer tlqd_live")
    }

    /// A transient failure must not turn every request into a mint attempt
    /// for the rest of the refresh window: the background reissue pauses,
    /// while a request whose token has expired still gets its mint.
    func testTransientReissueFailurePausesBackgroundAttempts() async throws {
        let clock = FakeClock()
        let transport = StubTransport()
        transport.enqueueDeviceToken(token: "tlqd_live", expiresIn: 900)
        let authorizer = TestFixtures.authorizer(transport: transport, clock: clock)

        try await authorizer.prepare()
        clock.advance(by: 800)
        transport.enqueue(json: #"{"error":"overloaded"}"#, status: 503)
        try await assertBearer(authorizer, "Bearer tlqd_live")
        _ = await Self.waitUntil { transport.sent.count == 2 }

        clock.advance(by: 2)
        for _ in 0..<5 { try await assertBearer(authorizer, "Bearer tlqd_live") }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sent.count, 2, "five requests inside the pause must not mint five times")

        clock.advance(by: 5)
        transport.enqueueDeviceToken(token: "tlqd_next", expiresIn: 900)
        try await assertBearer(authorizer, "Bearer tlqd_live", "still served while the retry runs")
        let installed = await Self.waitUntil { try await authorizer.headers()["Authorization"] == "Bearer tlqd_next" }
        XCTAssertTrue(installed, "after the pause the reissue is tried again")
    }

    /// Once the token has actually expired, the request waits for the mint.
    func testExpiredTokenWaitsForAFreshOne() async throws {
        let clock = FakeClock()
        let transport = StubTransport()
        transport.enqueueDeviceToken(token: "tlqd_old", expiresIn: 900)
        transport.enqueueDeviceToken(token: "tlqd_new", expiresIn: 900)
        let authorizer = TestFixtures.authorizer(transport: transport, clock: clock)

        try await authorizer.prepare()
        clock.advance(by: 901)

        try await assertBearer(authorizer, "Bearer tlqd_new")
        XCTAssertEqual(transport.sent.count, 2)
    }

    /// A refusal during a background reissue must not lock out the token that
    /// still works — only the next mint after expiry sees the cooldown.
    func testRefusedReissueDoesNotBlockTheLiveToken() async throws {
        let clock = FakeClock()
        let transport = StubTransport()
        transport.enqueueDeviceToken(token: "tlqd_live", expiresIn: 900)
        let authorizer = TestFixtures.authorizer(transport: transport, clock: clock)

        try await authorizer.prepare()
        clock.advance(by: 800)
        transport.enqueue(json: #"{"detail":"Device token issuance is not enabled"}"#, status: 403)
        try await assertBearer(authorizer, "Bearer tlqd_live")
        _ = await Self.waitUntil { transport.sent.count == 2 }

        clock.advance(by: 50) // 850 s: live, and inside the 60 s cooldown
        try await assertBearer(authorizer, "Bearer tlqd_live")
        XCTAssertEqual(transport.sent.count, 2, "no second attempt during the cooldown")

        clock.advance(by: 60) // 910 s: expired, cooldown over
        transport.enqueueDeviceToken(token: "tlqd_after", expiresIn: 900)
        try await assertBearer(authorizer, "Bearer tlqd_after")
    }

    /// Two requests race past expiry and both see a 401. The second report
    /// arrives after the first has already minted a replacement: that
    /// replacement must survive.
    func testStale401DoesNotDropTheFreshToken() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken(token: "tlqd_old")
        transport.enqueueDeviceToken(token: "tlqd_new")
        let authorizer = TestFixtures.authorizer(transport: transport, clock: FakeClock())

        try await authorizer.prepare()
        await authorizer.invalidate(authorization: "Bearer tlqd_old")
        try await assertBearer(authorizer, "Bearer tlqd_new")

        await authorizer.invalidate(authorization: "Bearer tlqd_old") // late report
        try await assertBearer(authorizer, "Bearer tlqd_new")
        XCTAssertEqual(transport.sent.count, 2, "the fresh token must not be minted again")
    }

    // MARK: - Device clock

    /// A phone with "set automatically" switched off signs with the wrong time
    /// and gets 401 forever. The response's own Date header says what time it
    /// is: the mint is signed once more with that, and the correction sticks.
    func testSkewedClockIsCorrectedFromTheServersDate() async throws {
        let transport = StubTransport()
        let serverTime = Date().addingTimeInterval(600)
        transport.enqueue(
            json: #"{"detail":"timestamp outside the acceptance window"}"#,
            status: 401,
            headers: ["Date": Self.httpDate(serverTime)]
        )
        transport.enqueueDeviceToken(token: "tlqd_corrected")
        let logs = LogCollector()
        let authorizer = TestFixtures.authorizer(transport: transport, clock: FakeClock(), logHandler: logs.append)

        try await assertBearer(authorizer, "Bearer tlqd_corrected")
        XCTAssertEqual(transport.sent.count, 2)

        let first = try XCTUnwrap(transport.sent[0].header("X-Client-Timestamp").flatMap(Int.init))
        let second = try XCTUnwrap(transport.sent[1].header("X-Client-Timestamp").flatMap(Int.init))
        XCTAssertEqual(Double(second - first), 600, accuracy: 3, "the retry is stamped with the server's time")
        XCTAssertNotEqual(transport.sent[0].header("X-Client-Nonce"), transport.sent[1].header("X-Client-Nonce"))
        XCTAssertTrue(logs.all.contains { $0.level == .info && $0.message.contains("clock") })

        // The next mint signs with the corrected time from its first attempt.
        transport.enqueueDeviceToken(token: "tlqd_next")
        await authorizer.setIdentity(.user(UUID()))
        try await assertBearer(authorizer, "Bearer tlqd_next")
        let third = try XCTUnwrap(transport.sent[2].header("X-Client-Timestamp").flatMap(Int.init))
        XCTAssertEqual(Double(third - first), 600, accuracy: 3)
    }

    /// The correction outlives the process: the next launch signs correctly
    /// from its first attempt instead of paying a rejected mint to learn it.
    func testClockCorrectionIsPersisted() async throws {
        let store = TalqynInMemoryUserIDStore()
        let transport = StubTransport()
        transport.enqueue(
            json: #"{"detail":"timestamp outside the acceptance window"}"#,
            status: 401,
            headers: ["Date": Self.httpDate(Date().addingTimeInterval(-900))]
        )
        transport.enqueueDeviceToken(token: "tlqd_first")
        let first = TestFixtures.authorizer(transport: transport, clock: FakeClock(), store: store)
        try await assertBearer(first, "Bearer tlqd_first")
        XCTAssertEqual(try XCTUnwrap(store.loadClockOffset()), -900, accuracy: 3)

        // "Next launch": a fresh authorizer over the same store.
        let relaunch = StubTransport()
        relaunch.enqueueDeviceToken(token: "tlqd_relaunch")
        let second = TestFixtures.authorizer(transport: relaunch, clock: FakeClock(), store: store)
        try await assertBearer(second, "Bearer tlqd_relaunch")
        XCTAssertEqual(relaunch.sent.count, 1, "no rejected mint to learn the skew again")
        let stamp = try XCTUnwrap(relaunch.sent[0].header("X-Client-Timestamp").flatMap(Double.init))
        XCTAssertEqual(stamp, Date().timeIntervalSince1970 - 900, accuracy: 3)
    }

    /// A clock that was fixed since the last launch: the stale correction
    /// earns one 401, the skew is measured again, and the store is cleared.
    func testFixedClockClearsTheStoredCorrection() async throws {
        let store = TalqynInMemoryUserIDStore()
        store.saveClockOffset(600)
        let transport = StubTransport()
        transport.enqueue(
            json: #"{"detail":"timestamp outside the acceptance window"}"#,
            status: 401,
            headers: ["Date": Self.httpDate(Date())]
        )
        transport.enqueueDeviceToken(token: "tlqd_fixed")
        let authorizer = TestFixtures.authorizer(transport: transport, clock: FakeClock(), store: store)

        try await assertBearer(authorizer, "Bearer tlqd_fixed")
        XCTAssertEqual(transport.sent.count, 2)
        XCTAssertNil(store.loadClockOffset(), "an offset of zero is forgotten, not stored")
    }

    /// A 401 with the clocks in agreement is about the key, not the time.
    func testUnauthorizedWithAgreeingClocksIsNotRetried() async throws {
        let transport = StubTransport()
        transport.enqueue(
            json: #"{"detail":"Invalid client key"}"#,
            status: 401,
            headers: ["Date": Self.httpDate(Date())]
        )
        let authorizer = TestFixtures.authorizer(transport: transport, clock: FakeClock())

        do {
            _ = try await authorizer.headers()
            XCTFail("expected an authorization failure")
        } catch let error as TalqynError {
            guard case .unauthorized = error else { return XCTFail("expected unauthorized, got \(error)") }
        }
        XCTAssertEqual(transport.sent.count, 1)
    }

    // MARK: - What prints

    /// Whatever prints a value — interpolation, `String(reflecting:)`, `dump`,
    /// the default printing of a struct that holds it — must leave out the
    /// client secret, the token, and the shopper's UUID: printed values end up
    /// in logs, crash reports, and bug trackers.
    func testCredentialsAndTokenPrintWithoutTheirSecrets() throws {
        let shopper = UUID()
        let credentials = TestFixtures.deviceToken(identity: .user(shopper))
        let token = try TalqynCoding.decoder.decode(TalqynDeviceToken.self, from: Data("""
        {"token":"tlqd_eyJsecret","expires_at":"2026-08-26T12:15:00Z","expires_in":900,\
        "user_id":"\(shopper.uuidString.lowercased())"}
        """.utf8))
        let configuration = TalqynConfiguration(
            baseURL: TestFixtures.baseURL, credentials: credentials, userIDStore: TalqynInMemoryUserIDStore()
        )

        XCTAssertEqual(
            "\(credentials)",
            "TalqynDeviceTokenCredentials(storefront: myshop, clientKeyID: ck_3f9a1c2b7d4e, clientSecret: ***, identity: user(***))"
        )
        XCTAssertEqual("\(token)", "TalqynDeviceToken(expiresAt: 2026-08-26 12:15:00 +0000, expiresIn: 900.0, guest: false)")
        XCTAssertEqual(
            [TalqynDeviceIdentity.guest, .persistentAnonymous].map { "\($0)" }, ["guest", "persistentAnonymous"]
        )

        let secrets = [credentials.clientSecret, token.token, shopper.uuidString, shopper.uuidString.lowercased()]
        let subjects: [(name: String, value: Any)] = [
            ("credentials", credentials), ("identity", credentials.identity),
            ("token", token), ("configuration", configuration),
        ]
        for subject in subjects {
            var dumped = ""
            dump(subject.value, to: &dumped)
            let renderings = [
                "\(subject.value)", String(describing: subject.value), String(reflecting: subject.value), dumped,
            ]
            for rendering in renderings {
                for secret in secrets where rendering.contains(secret) {
                    XCTFail("\(subject.name) prints a secret: \(rendering)")
                }
            }
        }
    }

    // MARK: - Helpers

    /// `XCTAssertEqual` takes autoclosures, which cannot await.
    private func assertBearer(
        _ authorizer: TalqynDeviceTokenAuthorizer,
        _ expected: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let actual = try await authorizer.headers()["Authorization"]
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    /// Polls a condition for up to a second: background work has no handle to
    /// await.
    private static func waitUntil(_ condition: @Sendable () async throws -> Bool) async -> Bool {
        for _ in 0..<100 {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
